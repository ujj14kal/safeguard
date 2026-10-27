"""Safeguard backend.

Phase 1: health check. Phase 4: POST /verify (SAM 2 + Muse, with fallback).
Phase 5: POST /verify-speech (Muse judges a text snippet, never audio).
Phase 6: SOS escalation — contacts, incidents, family live viewer. No API
keys in code: all configuration comes from environment variables (see
/.env.example).
"""

import asyncio
import base64
import binascii
import json
import logging
import os
import re
import secrets
import shutil
from collections import Counter
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from pathlib import Path

import httpx
from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect, status
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

from .accounts import (
    AccountsError,
    SupabaseAccounts,
    password_problem,
    valid_email,
    valid_phone,
)
from .config import SETTINGS
from .contacts import ContactLimitError, ContactStore, invite_link, link_from_updates
from .incidents import IncidentStore
from .muse import MuseClient, MuseError
from .notify import (
    TELEGRAM_API,
    DryRunNotifier,
    NotifyConfigError,
    alert_text,
    cab_text,
    end_text,
    make_notifier,
    maps_link,
    test_text,
)
from .ratelimit import RateLimiter
from .sam2_local import Sam2Runner, Sam2Unavailable
from .viewer import render_viewer_page

logger = logging.getLogger("safeguard.verify")


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not SETTINGS.app_token:
        logger.warning(
            "SAFEGUARD_APP_TOKEN is not set: app endpoints are open "
            "(local dev only — set it before exposing this backend)"
        )
    poll_task = None
    if SETTINGS.notify_mode == "telegram" and SETTINGS.telegram_bot_token:
        poll_task = asyncio.create_task(_telegram_poll_loop())
    yield
    if poll_task is not None:
        poll_task.cancel()


app = FastAPI(title="Safeguard backend", lifespan=lifespan)

_muse_limiter = RateLimiter(SETTINGS.muse_calls_per_min)
_speech_limiter = RateLimiter(SETTINGS.speech_calls_per_min)
_muse_client = MuseClient(
    base_url=SETTINGS.meta_model_base_url,
    api_key=SETTINGS.meta_model_api_key,
    model=SETTINGS.muse_model,
    timeout_s=SETTINGS.muse_timeout_s,
)
_muse_client.reasoning_effort = SETTINGS.verify_reasoning_effort
_muse_client.speech_reasoning_effort = SETTINGS.speech_reasoning_effort
_sam2 = Sam2Runner(
    checkpoint_path=SETTINGS.sam2_checkpoint_path,
    model_cfg=SETTINGS.sam2_config,
    max_latency_s=SETTINGS.sam2_max_latency_s,
    retry_after_s=SETTINGS.sam2_retry_after_s,
    corridor_half_width=SETTINGS.verify_corridor_half_width,
)
_daily_counts: Counter[str] = Counter()

# --- Phase 6: app token auth + stores -------------------------------------------
# Every app-to-backend endpoint requires X-Safeguard-Token when
# SAFEGUARD_APP_TOKEN is set; unset means open (local dev), with a startup
# warning. /health and the share-token viewer are always public.


def app_token_ok(provided: str | None) -> bool:
    want = SETTINGS.app_token
    if not want:
        return True
    return bool(provided) and secrets.compare_digest(provided, want)


def require_app_token(provided: str | None) -> None:
    if not app_token_ok(provided):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing or wrong app token",
        )


_contact_store: ContactStore | None = None
_incidents: IncidentStore | None = None
_incident_limiter = RateLimiter(SETTINGS.incident_rate_per_min)


def get_contact_store() -> ContactStore:
    global _contact_store
    if _contact_store is None:
        _contact_store = ContactStore(SETTINGS.contacts_path)
    return _contact_store


def get_incidents() -> IncidentStore:
    global _incidents
    if _incidents is None:
        _incidents = IncidentStore(
            path=SETTINGS.incidents_path,
            ttl_after_end_s=SETTINGS.incident_token_ttl_hours * 3600,
            max_active_s=SETTINGS.incident_max_active_hours * 3600,
        )
    return _incidents


def live_url_for(share_token: str) -> str:
    return f"{SETTINGS.public_base_url.rstrip('/')}/live/{share_token}"


async def _telegram_poll_loop() -> None:
    """No public webhook: poll getUpdates and link /start <code> senders."""
    token = SETTINGS.telegram_bot_token
    offset = None
    async with httpx.AsyncClient(timeout=25) as client:
        while True:
            try:
                response = await client.get(
                    f"{TELEGRAM_API}/bot{token}/getUpdates",
                    params={"offset": offset, "timeout": 20},
                )
                linked, offset = link_from_updates(
                    response.json(), get_contact_store()
                )
                if linked:
                    logger.info("telegram linked %d contact(s)", len(linked))
            except Exception as exc:
                logger.warning("telegram poll failed: %s", exc)
                await asyncio.sleep(5)


class VerifyRequest(BaseModel):
    frames_b64: list[str] = Field(min_length=1, max_length=8)
    on_device_features: dict = Field(default_factory=dict)
    # Person boxes on frame 0 in pixels [x0, y0, x1, y1] (SAM 2 prompts).
    boxes_xyxy: list[list[float]] = Field(default_factory=list)


class VerifyResponse(BaseModel):
    threat_level: str
    behaviours_observed: list[str]
    confidence: float
    reason: str
    path: str
    sam2_latency_ms: float | None
    muse_latency_ms: float


@app.get("/health")
def health(x_safeguard_token: str | None = Header(default=None)) -> dict:
    # Open to anyone, but only a caller with the app token learns whether the
    # Muse key is set. That flag tells the app whether a 5xx means "no API
    # key" (setup problem) rather than a crash. The key itself never leaves.
    if app_token_ok(x_safeguard_token):
        return {"status": "ok", "muse_configured": bool(SETTINGS.meta_model_api_key)}
    return {"status": "ok"}


@app.post("/verify", response_model=VerifyResponse)
def verify(
    request: VerifyRequest,
    x_safeguard_token: str | None = Header(default=None),
) -> VerifyResponse:
    require_app_token(x_safeguard_token)
    for blob in request.frames_b64:
        try:
            base64.b64decode(blob, validate=True)
        except (binascii.Error, ValueError):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail="frames_b64 must be base64-encoded JPEGs",
            )
    if not _muse_limiter.allow():
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Muse rate limit exceeded (20 calls/min)",
        )

    geometry: dict | None = None
    sam2_latency: float | None = None
    mode = SETTINGS.sam2_mode
    if mode == "sam2" or (mode == "auto" and request.boxes_xyxy):
        try:
            geometry, sam2_latency = _sam2.run(request.frames_b64, request.boxes_xyxy)
        except Sam2Unavailable as exc:
            if mode == "sam2":
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail=f"SAM 2 required but unavailable: {exc}",
                )
            logger.warning("SAM 2 fallback to muse-only: %s", exc)
    path = "sam2+muse" if geometry is not None else "muse-only"

    try:
        verdict, muse_latency = _muse_client.verify(
            request.frames_b64, request.on_device_features, geometry
        )
    except MuseError as exc:
        logger.warning("Muse call failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"verification unavailable: {exc}",
        )

    log_call(path, sam2_latency, muse_latency, verdict["threat_level"])
    return VerifyResponse(
        threat_level=verdict["threat_level"],
        behaviours_observed=verdict["behaviours_observed"],
        confidence=verdict["confidence"],
        reason=verdict["reason"],
        path=path,
        sam2_latency_ms=round(sam2_latency * 1000, 1) if sam2_latency is not None else None,
        muse_latency_ms=round(muse_latency * 1000, 1),
    )


class SpeechVerifyRequest(BaseModel):
    # Short TEXT snippet (trigger sentence + a little context). Never audio.
    snippet: str = Field(min_length=1, max_length=2000)
    on_device: dict = Field(default_factory=dict)


class SpeechVerifyResponse(BaseModel):
    severity: str
    categories: list[str]
    directed_at_wearer: bool
    reason: str


@app.post("/verify-speech", response_model=SpeechVerifyResponse)
def verify_speech(
    request: SpeechVerifyRequest,
    x_safeguard_token: str | None = Header(default=None),
) -> SpeechVerifyResponse:
    require_app_token(x_safeguard_token)
    # Its own budget: the app judges the conversation continuously, and a
    # chatty crowd must not starve movement verification (or vice versa).
    if not _speech_limiter.allow():
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Speech rate limit exceeded ({SETTINGS.speech_calls_per_min} calls/min)",
        )
    try:
        verdict, muse_latency = _muse_client.verify_speech(
            request.snippet, request.on_device
        )
    except MuseError as exc:
        logger.warning("Muse speech call failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"verification unavailable: {exc}",
        )
    log_speech_call(muse_latency, verdict)
    return SpeechVerifyResponse(
        severity=verdict["severity"],
        categories=verdict["categories"],
        directed_at_wearer=verdict["directed_at_wearer"],
        reason=verdict["reason"],
    )


def log_speech_call(muse_latency: float, verdict: dict) -> None:
    """Log counts, latency and severity — NEVER the transcript snippet."""
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    _daily_counts[day] += 1
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "day": day,
        "day_count": _daily_counts[day],
        "endpoint": "verify-speech",
        "muse_latency_ms": round(muse_latency * 1000, 1),
        "severity": verdict["severity"],
        "category_count": len(verdict["categories"]),
        "directed_at_wearer": verdict["directed_at_wearer"],
    }
    line = json.dumps(record)
    logger.info(line)
    try:
        os.makedirs(os.path.dirname(SETTINGS.verify_log_path) or ".", exist_ok=True)
        with open(SETTINGS.verify_log_path, "a") as handle:
            handle.write(line + "\n")
    except OSError as exc:
        logger.warning("could not write verify log: %s", exc)


def log_call(
    path: str, sam2_latency: float | None, muse_latency: float, threat_level: str
) -> None:
    """Append one JSON line per call and keep a daily counter."""
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    _daily_counts[day] += 1
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "day": day,
        "day_count": _daily_counts[day],
        "path": path,
        "sam2_latency_ms": round(sam2_latency * 1000, 1) if sam2_latency is not None else None,
        "muse_latency_ms": round(muse_latency * 1000, 1),
        "threat_level": threat_level,
    }
    line = json.dumps(record)
    logger.info(line)
    try:
        os.makedirs(os.path.dirname(SETTINGS.verify_log_path) or ".", exist_ok=True)
        with open(SETTINGS.verify_log_path, "a") as handle:
            handle.write(line + "\n")
    except OSError as exc:
        logger.warning("could not write verify log: %s", exc)


# --- SOS evidence -----------------------------------------------------------

_SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_EVIDENCE_KINDS = {"video": {"mp4"}, "audio": {"m4a"}}


def _evidence_root() -> Path:
    return Path(SETTINGS.evidence_dir)


def _check_evidence_or_app_token(evidence: str | None, app: str | None) -> None:
    # Phase 6: /evidence accepts EITHER the app token or the legacy evidence
    # token (kept so the pinned evidence-token tests keep passing; the app
    # sends the app token everywhere).
    ev_ok = bool(SETTINGS.evidence_token) and evidence == SETTINGS.evidence_token
    app_ok = bool(SETTINGS.app_token) and app_token_ok(app)
    if ev_ok or app_ok:
        return
    if not SETTINGS.evidence_token and not SETTINGS.app_token:
        return
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="bad evidence or app token"
    )


@app.post("/evidence")
async def upload_evidence(
    request: Request,
    session: str,
    kind: str,
    seq: int,
    ext: str,
    x_evidence_token: str | None = Header(default=None),
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    """Store one recording segment (raw bytes in the body) from an SOS.

    The app records video and audio in short segments while an SOS runs and
    uploads each as soon as it is closed, so a phone that is taken or
    smashed has already sent most of the evidence. File names are fixed by
    the server from validated fields; nothing from the client is used as a path.
    """
    _check_evidence_or_app_token(x_evidence_token, x_safeguard_token)
    if not _SESSION_RE.match(session):
        raise HTTPException(status_code=422, detail="bad session id")
    if kind not in _EVIDENCE_KINDS or ext not in _EVIDENCE_KINDS[kind]:
        raise HTTPException(status_code=422, detail="bad kind or extension")
    if not 0 <= seq <= 100_000:
        raise HTTPException(status_code=422, detail="bad sequence number")
    limit = SETTINGS.evidence_max_mb * 1024 * 1024
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > limit:
        raise HTTPException(status_code=413, detail="segment too large")
    body = await request.body()
    if not body:
        raise HTTPException(status_code=422, detail="empty segment")
    if len(body) > limit:
        raise HTTPException(status_code=413, detail="segment too large")
    folder = _evidence_root() / session
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{kind}-{seq:05d}.{ext}").write_bytes(body)
    logger.info("evidence stored kind=%s seq=%d bytes=%d", kind, seq, len(body))
    return {"stored": True, "bytes": len(body)}


@app.get("/evidence/{session}")
def list_evidence(
    session: str,
    x_evidence_token: str | None = Header(default=None),
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    """List the segments stored for one SOS session (names and sizes only)."""
    _check_evidence_or_app_token(x_evidence_token, x_safeguard_token)
    if not _SESSION_RE.match(session):
        raise HTTPException(status_code=422, detail="bad session id")
    folder = _evidence_root() / session
    if not folder.is_dir():
        raise HTTPException(status_code=404, detail="no such session")
    files = [{"name": f.name, "bytes": f.stat().st_size} for f in sorted(folder.iterdir())]
    return {"session": session, "files": files}


@app.delete("/evidence/{session}")
def delete_evidence(
    session: str,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    """Deletes every segment stored for one SOS session. Idempotent: a
    missing session deletes nothing and still returns 200."""
    require_app_token(x_safeguard_token)
    if not _SESSION_RE.match(session):
        raise HTTPException(status_code=422, detail="bad session id")
    folder = _evidence_root() / session
    if not folder.is_dir():
        return {"deleted": False}
    shutil.rmtree(folder)
    logger.info("evidence deleted session=%s", session)
    return {"deleted": True}


# --- App event log (debug) --------------------------------------------------
# Unlike the verify logs, this one DOES hold what the app heard: it exists so
# the developer can see what the app is doing while testing. The app only
# sends it when the "Debug log" setting is on. Switch it off before real use.

_APPLOG_MAX_EVENTS = 200
_APPLOG_MAX_FIELD = 600


def _applog_path() -> Path:
    path = Path(os.environ.get("APPLOG_PATH", "logs/app-events.jsonl"))
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


class AppLogBatch(BaseModel):
    events: list[dict] = Field(max_length=_APPLOG_MAX_EVENTS)


@app.post("/applog")
def post_applog(
    batch: AppLogBatch,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    now = datetime.now(timezone.utc).isoformat()
    lines = []
    for event in batch.events:
        clean = {
            str(key)[:40]: (str(value)[:_APPLOG_MAX_FIELD] if not isinstance(value, (int, float, bool)) else value)
            for key, value in event.items()
        }
        clean["server_ts"] = now
        lines.append(json.dumps(clean, ensure_ascii=False))
    if lines:
        with _applog_path().open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return {"stored": len(lines)}


@app.get("/applog")
def get_applog(
    n: int = 100,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    path = _applog_path()
    if not path.exists():
        return {"events": []}
    tail = path.read_text(encoding="utf-8").splitlines()[-max(1, min(n, 1000)):]
    return {"events": [json.loads(line) for line in tail if line.strip()]}


# --- Realtime speech to text (Muse Voice Transcribe relay) -------------------
# The phone streams 16 kHz mono PCM16 audio here as binary WebSocket frames;
# this relays it to Meta's realtime ASR and sends the JSON events (partial and
# final transcripts) straight back. The API key never leaves this server.

ASR_KEYWORDS = [
    "bachao", "madad", "help me", "save me", "bhosdike", "madarchod", "behenchod",
    "chutiya", "randi", "gandu", "harami", "kamina", "maar dunga", "Safeguard",
    "open calculator", "open app store", "free ho kya", "kitna loge", "chhodo mujhe",
]


def asr_handshake() -> dict:
    return {
        "authorization": {"accessToken": f"Bearer {SETTINGS.meta_model_api_key}"},
        "audioEncoding": "PCM_16KHZ",
        "model": SETTINGS.asr_model,
        "mode": "ENDPOINTING",
        "partialMode": "CUMULATIVE",
        "emitAudioProgress": False,
        "languageBias": ["Hindi", "English"],
        "keywords": ASR_KEYWORDS,
    }


@app.websocket("/asr")
async def asr_relay(client: WebSocket) -> None:
    import asyncio

    import websockets

    # Refuse BEFORE accepting: a wrong or missing token never gets a socket.
    if not app_token_ok(client.headers.get("x-safeguard-token")):
        await client.close(code=1008)
        return
    await client.accept()
    if not SETTINGS.meta_model_api_key:
        await client.send_text(json.dumps({"type": "error", "message": "META_MODEL_API_KEY is not set"}))
        await client.close(code=1011)
        return
    started = datetime.now(timezone.utc)
    audio_bytes = 0
    events = 0
    try:
        async with websockets.connect(SETTINGS.asr_upstream_url, max_size=None) as upstream:
            await upstream.send(json.dumps(asr_handshake()))
            ack = await asyncio.wait_for(upstream.recv(), timeout=15)
            await client.send_text(json.dumps({"type": "ready", "ack": json.loads(ack) if isinstance(ack, str) else {}}))

            async def phone_to_meta() -> None:
                nonlocal audio_bytes
                while True:
                    message = await client.receive()
                    if message.get("type") == "websocket.disconnect":
                        return
                    if message.get("bytes") is not None:
                        audio_bytes += len(message["bytes"])
                        await upstream.send(message["bytes"])
                    elif message.get("text") is not None:
                        await upstream.send(message["text"])  # e.g. {"type": "endStream"}

            async def meta_to_phone() -> None:
                nonlocal events
                async for message in upstream:
                    if isinstance(message, str):
                        events += 1
                        await client.send_text(message)

            tasks = [asyncio.create_task(phone_to_meta()), asyncio.create_task(meta_to_phone())]
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            for task in done:
                task.result()
    except (WebSocketDisconnect, RuntimeError):
        pass
    except Exception as exc:  # noqa: BLE001 - report to the phone, never crash the server
        logger.warning("asr relay ended: %s", exc)
        try:
            await client.send_text(json.dumps({"type": "error", "message": f"relay: {type(exc).__name__}"}))
            await client.close(code=1011)
        except Exception:  # noqa: BLE001
            pass
    finally:
        # Counts only: audio and transcripts are never logged here.
        logger.info(
            "asr session ended seconds=%.1f audio_bytes=%d events=%d",
            (datetime.now(timezone.utc) - started).total_seconds(), audio_bytes, events,
        )


# --- Phase 6: contacts, incidents, live viewer ----------------------------------


class InviteRequest(BaseModel):
    name: str = Field(min_length=1, max_length=60)


@app.post("/contacts/invite")
def invite_contact(
    body: InviteRequest,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    """Adds a contact and returns the Telegram invite link (Start once)."""
    require_app_token(x_safeguard_token)
    try:
        record = get_contact_store().invite(body.name)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except ContactLimitError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    return {
        "name": record["name"],
        "code": record["code"],
        "link": invite_link(SETTINGS.telegram_bot, record["code"]),
    }


@app.get("/contacts/{code}")
def contact_status(
    code: str,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    record = get_contact_store().get(code)
    if record is None:
        raise HTTPException(status_code=404, detail="no such invite code")
    return {"name": record["name"], "linked": record["chat_id"] is not None}


_CODE_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


@app.delete("/contacts/{code}")
def delete_contact(
    code: str,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    """Deletes one linked contact. Idempotent: an unknown code deletes
    nothing and still returns 200."""
    require_app_token(x_safeguard_token)
    if not _CODE_RE.match(code):
        raise HTTPException(status_code=422, detail="bad invite code")
    return {"deleted": get_contact_store().remove(code)}


class IncidentStartRequest(BaseModel):
    session: str
    wearer_name: str = Field(min_length=1, max_length=60)
    contact_codes: list[str] = Field(default_factory=list)
    dry_run: bool = True
    test: bool = False
    lang: str = Field(default="en", pattern="^(en|hi)$")
    lat: float | None = None
    lon: float | None = None


class LocationPoint(BaseModel):
    lat: float
    lon: float
    accuracy: float | None = None
    ts: float | None = None


class CabRequest(BaseModel):
    driver: str = Field(min_length=1, max_length=60)
    plate: str = Field(min_length=1, max_length=20)
    eta_min: int = Field(ge=0, le=180)


def _check_fix(lat: float | None, lon: float | None, accuracy=None) -> None:
    if (lat is None) != (lon is None):
        raise HTTPException(status_code=422, detail="lat and lon go together")
    if lat is not None and not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise HTTPException(status_code=422, detail="lat/lon out of range")
    if accuracy is not None and accuracy < 0:
        raise HTTPException(status_code=422, detail="accuracy cannot be negative")


def _notifier_for(dry_run: bool):
    if dry_run:
        return DryRunNotifier(SETTINGS.notify_log_path)
    try:
        return make_notifier(SETTINGS)
    except NotifyConfigError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"notifier unavailable: {exc}",
        )


def _send_to_codes(codes, text, dry_run, url_button=None, pin=None) -> list:
    """Sends one message to linked contacts. Returns per-contact delivery."""
    store = get_contact_store()
    notifier = _notifier_for(dry_run)
    delivery = []
    for code in codes:
        record = store.get(code)
        if record is None or record.get("chat_id") is None:
            delivery.append({"code": code, "status": "skipped", "detail": "not linked"})
            continue
        result = notifier.send_text(
            record["chat_id"], text, url_button=url_button
        )
        detail = result.detail
        if result.ok and pin is not None:
            pin_result = notifier.send_location(record["chat_id"], *pin)
            if not pin_result.ok:
                detail = f"text ok, pin failed: {pin_result.detail}"
        delivery.append({
            "code": code,
            "name": record["name"],
            "status": result.status,
            "detail": detail,
        })
    return delivery


@app.post("/incident/start")
def incident_start(
    body: IncidentStartRequest,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    if not _incident_limiter.allow():
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="incident start rate limit exceeded",
        )
    if not _SESSION_RE.match(body.session):
        raise HTTPException(status_code=422, detail="bad session id")
    _check_fix(body.lat, body.lon)
    wearer = " ".join(body.wearer_name.split())
    store = get_incidents()
    incident, fresh = store.start(
        session=body.session,
        wearer_name=wearer,
        contact_codes=body.contact_codes,
        test=body.test,
        dry_run=body.dry_run,
        lang=body.lang,
    )
    live = live_url_for(incident.share_token)
    if not fresh:
        # One alert burst per incident: repeats return the same incident.
        # The preview echoes the would-be text for the request's own flag.
        if body.test:
            preview = test_text(wearer, live, lang=body.lang)
        else:
            preview = alert_text(wearer, live, lang=body.lang)
        return {
            "id": incident.id,
            "share_token": incident.share_token,
            "live_url": live,
            "delivery": [],
            "fresh": False,
            "preview_text": preview,
        }
    pin = None
    if body.lat is not None:
        store.add_point(incident.id, body.lat, body.lon)
        pin = (body.lat, body.lon)
    if body.test:
        text = test_text(wearer, live, lang=body.lang)
    else:
        maps = maps_link(*pin) if pin else None
        text = alert_text(wearer, live, maps_url=maps, lang=body.lang)
    delivery = _send_to_codes(
        incident.contact_codes, text, incident.dry_run,
        url_button=("Open live view", live), pin=pin,
    )
    incident.alerted = True
    store.save()
    sent = sum(1 for item in delivery if item["status"] in ("sent", "dry-run"))
    logger.info(
        "incident started id=%s contacts=%d sent=%d test=%s",
        incident.id, len(delivery), sent, body.test,
    )
    return {
        "id": incident.id,
        "share_token": incident.share_token,
        "live_url": live,
        "delivery": delivery,
        "fresh": True,
        "preview_text": text,
    }


@app.post("/incident/{incident_id}/location")
def incident_location(
    incident_id: str,
    body: LocationPoint,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    incident = get_incidents().get(incident_id)
    if incident is None:
        raise HTTPException(status_code=404, detail="no such incident")
    _check_fix(body.lat, body.lon, body.accuracy)
    get_incidents().add_point(
        incident_id, body.lat, body.lon, accuracy=body.accuracy, ts=body.ts
    )
    return {"stored": len(incident.points)}


@app.post("/incident/{incident_id}/end")
def incident_end(
    incident_id: str,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    store = get_incidents()
    incident = store.get(incident_id)
    if incident is None:
        raise HTTPException(status_code=404, detail="no such incident")
    if incident.status != "active":
        return {"ended": True, "already_ended": True}
    store.end(incident_id)
    delivery = []
    if not incident.end_sent:
        text = end_text(incident.wearer_name, lang=incident.lang)
        if incident.test:
            text = "[TEST] " + text
        delivery = _send_to_codes(incident.contact_codes, text, incident.dry_run)
        incident.end_sent = True
        get_incidents().save()
        logger.info("incident ended id=%s contacts=%d", incident.id, len(delivery))
    return {"ended": True, "already_ended": False, "delivery": delivery}


@app.post("/incident/{incident_id}/cab")
def incident_cab(
    incident_id: str,
    body: CabRequest,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    """Shares DEMO cab details with the incident's contacts (no real cab)."""
    require_app_token(x_safeguard_token)
    incident = get_incidents().get(incident_id)
    if incident is None:
        raise HTTPException(status_code=404, detail="no such incident")
    if incident.status != "active":
        raise HTTPException(status_code=409, detail="incident has ended")
    text = cab_text(
        " ".join(body.driver.split()),
        " ".join(body.plate.split()),
        body.eta_min,
        live_url_for(incident.share_token),
        lang=incident.lang,
    )
    if incident.test:
        text = "[TEST] " + text
    delivery = _send_to_codes(incident.contact_codes, text, incident.dry_run)
    sent = sum(1 for item in delivery if item["status"] in ("sent", "dry-run"))
    logger.info("incident cab shared id=%s contacts=%d sent=%d", incident.id, len(delivery), sent)
    return {"sent": sent, "delivery": delivery}


def _live_incident_or_404(share_token: str):
    incident = get_incidents().get_by_token(share_token)
    if incident is None:
        raise HTTPException(status_code=404, detail="no such live page")
    return incident


_SEGMENT_NAME_RE = re.compile(r"^(video|audio)-(\d{5})\.(mp4|m4a)$")


def _live_segments(incident) -> list:
    folder = _evidence_root() / incident.session
    if not folder.is_dir():
        return []
    found = []
    for path in sorted(folder.iterdir()):
        match = _SEGMENT_NAME_RE.match(path.name)
        if not match:
            continue
        kind, seq, ext = match.groups()
        if ext not in _EVIDENCE_KINDS[kind]:
            continue
        found.append({
            "kind": kind,
            "seq": int(seq),
            "name": path.name,
            "bytes": path.stat().st_size,
            "url": f"segments/{path.name}",
        })
    found.sort(key=lambda item: (item["seq"], item["kind"]))
    return found


@app.get("/live/{share_token}", response_class=HTMLResponse)
def live_page(share_token: str) -> str:
    # Share token only — no app token. A wrong token is a plain 404.
    _live_incident_or_404(share_token)
    return render_viewer_page(share_token)


@app.get("/live/{share_token}/state")
def live_state(share_token: str) -> dict:
    incident = _live_incident_or_404(share_token)
    points = list(incident.points)
    return {
        "status": incident.status,
        "wearer_name": incident.wearer_name,
        "started_at": incident.created_at,
        "ended_at": incident.ended_at or None,
        "latest": points[-1] if points else None,
        "trail": [{"lat": point["lat"], "lon": point["lon"]} for point in points],
        "segments": _live_segments(incident),
        "test": incident.test,
    }


@app.get("/live/{share_token}/segments/{name}")
def live_segment(share_token: str, name: str):
    """Serves one segment file — but only from this token's own session."""
    incident = _live_incident_or_404(share_token)
    match = _SEGMENT_NAME_RE.match(name)
    if not match:
        raise HTTPException(status_code=404, detail="no such segment")
    kind, _, ext = match.groups()
    if ext not in _EVIDENCE_KINDS[kind]:
        raise HTTPException(status_code=404, detail="no such segment")
    path = _evidence_root() / incident.session / name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="no such segment")
    media = "video/mp4" if kind == "video" else "audio/mp4"
    return FileResponse(path, media_type=media, filename=name)



# --- Accounts (Supabase) ---------------------------------------------------------
# Sign-up / sign-in are relayed here so the Supabase keys never reach the
# phone. Passwords go straight to Supabase Auth and are never stored or
# logged; the profile (name, phone, language, consent) is a row in
# `profiles`. Every route also needs the app token.

_auth_limiter = RateLimiter(SETTINGS.auth_rate_per_min)
_accounts_override: SupabaseAccounts | None = None  # tests inject a fake


def get_accounts() -> SupabaseAccounts:
    if _accounts_override is not None:
        return _accounts_override
    return SupabaseAccounts(
        SETTINGS.supabase_url, SETTINGS.supabase_anon_key, SETTINGS.supabase_service_role_key
    )


def _auth_guard(app_token: str | None) -> SupabaseAccounts:
    require_app_token(app_token)
    if not _auth_limiter.allow():
        raise HTTPException(status_code=429, detail="too many attempts, wait a minute")
    try:
        return get_accounts()
    except AccountsError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message) from exc


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="sign in first")
    token = authorization[7:].strip()
    if not token or len(token) > 4096:
        raise HTTPException(status_code=401, detail="sign in first")
    return token


def _profile_out(row: dict, user: dict | None = None) -> dict:
    user = user or {}
    return {
        "id": row.get("id") or user.get("id"),
        "email": row.get("email") or user.get("email"),
        "name": row.get("name") or "",
        "phone": row.get("phone"),
        "language": row.get("language") or "en",
        "created_at": row.get("created_at"),
    }


def _fail(exc: AccountsError):
    return HTTPException(status_code=exc.status_code, detail=exc.message)


class SignupRequest(BaseModel):
    email: str = Field(max_length=320)
    password: str = Field(max_length=200)
    name: str = Field(min_length=1, max_length=60)
    phone: str | None = Field(default=None, max_length=24)
    language: str = Field(default="en", pattern="^(en|hi)$")
    # The wearer agreed to the privacy notice (what is stored and why).
    consent: bool = False


class LoginRequest(BaseModel):
    email: str = Field(max_length=320)
    password: str = Field(max_length=200)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=10, max_length=4096)


class ProfileUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=60)
    phone: str | None = Field(default=None, max_length=24)
    language: str | None = Field(default=None, pattern="^(en|hi)$")


@app.post("/auth/signup")
def auth_signup(
    body: SignupRequest, x_safeguard_token: str | None = Header(default=None)
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    email = body.email.strip().lower()
    if not valid_email(email):
        raise HTTPException(status_code=422, detail="enter a valid email address")
    problem = password_problem(body.password)
    if problem:
        raise HTTPException(status_code=422, detail=problem)
    if body.phone and not valid_phone(body.phone):
        raise HTTPException(status_code=422, detail="enter a valid phone number")
    if not body.consent:
        raise HTTPException(status_code=422, detail="agree to the privacy notice to continue")
    name = " ".join(body.name.split())
    try:
        user, session = accounts.sign_up(
            email, body.password,
            {"name": name, "language": body.language},
        )
        row = accounts.upsert_profile(
            user["id"], email,
            {"name": name, "phone": body.phone, "language": body.language},
            consent_at=datetime.now(timezone.utc).isoformat(),
        )
    except AccountsError as exc:
        raise _fail(exc) from exc
    return {
        "user": _profile_out(row, user),
        "session": session.as_dict() if session else None,
        # Supabase projects with email confirmation on return no session
        # until the link in the email is opened.
        "needs_confirmation": session is None,
    }


@app.post("/auth/login")
def auth_login(
    body: LoginRequest, x_safeguard_token: str | None = Header(default=None)
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    email = body.email.strip().lower()
    try:
        user, session = accounts.sign_in(email, body.password)
        row = accounts.get_profile(user["id"]) if user.get("id") else None
        if row is None and user.get("id"):
            meta = user.get("user_metadata") or {}
            row = accounts.upsert_profile(
                user["id"], email,
                {"name": meta.get("name") or email.split("@")[0], "language": meta.get("language") or "en"},
            )
    except AccountsError as exc:
        raise _fail(exc) from exc
    return {"user": _profile_out(row or {}, user), "session": session.as_dict()}


@app.post("/auth/refresh")
def auth_refresh(
    body: RefreshRequest, x_safeguard_token: str | None = Header(default=None)
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    try:
        session = accounts.refresh(body.refresh_token)
    except AccountsError as exc:
        raise _fail(exc) from exc
    return {"session": session.as_dict()}


@app.post("/auth/logout")
def auth_logout(
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    accounts.sign_out(_bearer(authorization))
    return {"ok": True}


def _current_user(accounts: SupabaseAccounts, authorization: str | None) -> dict:
    try:
        return accounts.user_for(_bearer(authorization))
    except AccountsError as exc:
        raise _fail(exc) from exc


@app.get("/me")
def me_get(
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    user = _current_user(accounts, authorization)
    try:
        row = accounts.get_profile(user["id"]) or {}
    except AccountsError as exc:
        raise _fail(exc) from exc
    return _profile_out(row, user)


@app.put("/me")
def me_put(
    body: ProfileUpdate,
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    user = _current_user(accounts, authorization)
    if body.phone and not valid_phone(body.phone):
        raise HTTPException(status_code=422, detail="enter a valid phone number")
    fields = body.model_dump(exclude_unset=True)
    if "name" in fields and fields["name"]:
        fields["name"] = " ".join(fields["name"].split())
    try:
        row = accounts.update_profile(user["id"], fields)
    except AccountsError as exc:
        raise _fail(exc) from exc
    return _profile_out(row, user)


@app.delete("/me")
def me_delete(
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    user = _current_user(accounts, authorization)
    try:
        accounts.delete_user(user["id"])
    except AccountsError as exc:
        raise _fail(exc) from exc
    return {"deleted": True}
