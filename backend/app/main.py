
import asyncio
import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import shutil
import time
from collections import Counter, deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from pathlib import Path

import httpx
from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect, status
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response
from pydantic import BaseModel, Field, field_validator

from .accounts import (
    AccountsError,
    SupabaseAccounts,
    password_problem,
    valid_email,
    valid_phone,
)
from .config import SETTINGS
from .contacts import (
    ContactLimitError, ContactStore, apply_locations, guardian_invite_link, invite_link,
    link_from_updates,
)
from . import hls
from .incidents import IncidentStore
from .links import ChannelStore, GuardianStore, normalize_code
from .muse import _NAME_RE as _NAME_PATTERN
from .muse import MuseClient, MuseError
from .notify import (
    TELEGRAM_API,
    DryRunNotifier,
    NotifyConfigError,
    alert_text,
    cab_text,
    end_text,
    make_notifier,
    nearest_notes,
    maps_link,
    ride_link,
    test_text,
)
from .ratelimit import RateLimiter
from .sam2_local import Sam2Runner, Sam2Unavailable
from .storage import EvidenceBackend, StorageUnavailable, make_avatars, make_evidence, make_state_file
from .viewer import render_guardian_page, render_viewer_page

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
        if SETTINGS.telegram_webhook:
            await _register_telegram_webhook()
        else:
            poll_task = asyncio.create_task(_telegram_poll_loop())
    yield
    if poll_task is not None:
        poll_task.cancel()


app = FastAPI(title="Safeguard backend", lifespan=lifespan)


@app.exception_handler(StorageUnavailable)
async def _storage_unavailable(_request: Request, exc: StorageUnavailable):
    logger.warning("storage unavailable: %s", exc)
    return JSONResponse(status_code=503, content={"detail": "storage unavailable, try again"})

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


def _device_key() -> bytes:
    return hashlib.sha256(("device-token:" + SETTINGS.app_token).encode()).digest()


def make_device_token() -> str:
    ident = secrets.token_hex(12)
    sig = hmac.new(_device_key(), ident.encode(), hashlib.sha256).hexdigest()[:32]
    return f"d1.{ident}.{sig}"


def device_token_ok(provided: str) -> bool:
    parts = provided.split(".")
    if len(parts) != 3 or parts[0] != "d1" or not parts[1] or not parts[2]:
        return False
    want = hmac.new(_device_key(), parts[1].encode(), hashlib.sha256).hexdigest()[:32]
    return secrets.compare_digest(parts[2], want)


def app_token_ok(provided: str | None) -> bool:
    want = SETTINGS.app_token
    if not want:
        return True
    if not provided:
        return False
    return secrets.compare_digest(provided, want) or device_token_ok(provided)


_device_register_limiter = RateLimiter(120, 3600.0)


@app.post("/device/register")
def device_register() -> dict:
    if not _device_register_limiter.allow():
        raise HTTPException(status_code=429, detail="too many registrations, try again later")
    return {"token": make_device_token()}


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
        _contact_store = ContactStore(
            make_state_file(SETTINGS, "contacts.json", SETTINGS.contacts_path)
        )
    return _contact_store


def get_incidents() -> IncidentStore:
    global _incidents
    if _incidents is None:
        _incidents = IncidentStore(
            path=make_state_file(SETTINGS, "incidents.json", SETTINGS.incidents_path),
            ttl_after_end_s=SETTINGS.incident_token_ttl_hours * 3600,
            max_active_s=SETTINGS.incident_max_active_hours * 3600,
            guardian_ttl_after_end_s=SETTINGS.guardian_retention_days * 86400,
        )
    return _incidents


_guardians: GuardianStore | None = None
_channels: ChannelStore | None = None


def get_guardians() -> GuardianStore:
    global _guardians
    if _guardians is None:
        _guardians = GuardianStore(
            make_state_file(SETTINGS, "guardians.json", SETTINGS.guardians_path)
        )
    return _guardians


def get_channels() -> ChannelStore:
    global _channels
    if _channels is None:
        _channels = ChannelStore(
            make_state_file(SETTINGS, "channels.json", SETTINGS.channels_path)
        )
    return _channels


def live_url_for(share_token: str) -> str:
    return f"{SETTINGS.public_base_url.rstrip('/')}/live/{share_token}"



def _telegram_webhook_secret() -> str:
    return hashlib.sha256(("safeguard-tg:" + SETTINGS.telegram_bot_token).encode()).hexdigest()[:48]


async def _register_telegram_webhook() -> None:
    base = SETTINGS.public_base_url.rstrip("/")
    if not base.startswith("https://"):
        logger.warning("telegram webhook needs an https PUBLIC_BASE_URL (got %r)", base)
        return
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(
                f"{TELEGRAM_API}/bot{SETTINGS.telegram_bot_token}/setWebhook",
                json={
                    "url": f"{base}/telegram/webhook",
                    "secret_token": _telegram_webhook_secret(),
                    "allowed_updates": ["message", "edited_message"],
                },
            )
        logger.info("telegram webhook registered: %s", response.status_code)
    except httpx.HTTPError as exc:
        logger.warning("telegram webhook registration failed: %s", type(exc).__name__)


@app.post("/telegram/webhook")
async def telegram_webhook(
    request: Request, x_telegram_bot_api_secret_token: str | None = Header(default=None)
) -> dict:
    if not SETTINGS.telegram_bot_token or not secrets.compare_digest(
        x_telegram_bot_api_secret_token or "", _telegram_webhook_secret()
    ):
        raise HTTPException(status_code=401, detail="bad webhook secret")
    try:
        update = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="bad body")
    _handle_telegram_updates({"result": [update]})
    return {"ok": True}


_SHARE_PROMPT = {
    "en": "You are now an emergency contact. Tap the button below to share your location once, so Safeguard can tell who is nearest if someone needs help. You can stop sharing any time.",
    "hi": "अब आप आपातकालीन संपर्क हैं। अपनी लोकेशन एक बार साझा करने के लिए नीचे का बटन दबाएँ, ताकि ज़रूरत पड़ने पर Safeguard बता सके कि सबसे नज़दीक कौन है।",
}
_SHARE_BUTTON = "Share my location / लोकेशन साझा करें"
_SHARE_THANKS = "Thanks, your location is saved. / धन्यवाद, आपकी लोकेशन सहेज ली गई।"


def _handle_telegram_updates(payload: dict) -> None:
    store = get_contact_store()
    linked, _ = link_from_updates(payload, store, get_guardians())
    if linked:
        logger.info("telegram linked %d contact(s)", len(linked))
    try:
        notifier = make_notifier(SETTINGS)
    except NotifyConfigError:
        return
    for code in linked:
        record = store.get(code)
        if record and record.get("chat_id") is not None:
            notifier.send_location_request(
                record["chat_id"], _SHARE_PROMPT["en"] + "\n\n" + _SHARE_PROMPT["hi"], _SHARE_BUTTON
            )
    for chat_id, is_edit in apply_locations(payload, store, time.time()):
        if not is_edit:
            notifier.send_text(chat_id, _SHARE_THANKS)


async def _telegram_poll_loop() -> None:
    token = SETTINGS.telegram_bot_token
    offset = None
    async with httpx.AsyncClient(timeout=25) as client:
        try:
            await client.post(f"{TELEGRAM_API}/bot{token}/deleteWebhook")
        except httpx.HTTPError:
            pass
        while True:
            try:
                response = await client.get(
                    f"{TELEGRAM_API}/bot{token}/getUpdates",
                    params={"offset": offset, "timeout": 20},
                )
                body = response.json()
                _handle_telegram_updates(body)
                updates = body.get("result") if isinstance(body, dict) else None
                if isinstance(updates, list) and updates:
                    offset = max(u.get("update_id", 0) for u in updates if isinstance(u, dict)) + 1
            except Exception as exc:
                logger.warning("telegram poll failed: %s", exc)
                await asyncio.sleep(5)


class VerifyRequest(BaseModel):
    frames_b64: list[str] = Field(min_length=1, max_length=8)
    on_device_features: dict = Field(default_factory=dict)
    boxes_xyxy: list[list[float]] = Field(default_factory=list)


class VerifyResponse(BaseModel):
    threat_level: str
    behaviours_observed: list[str]
    object_held: str = ""
    confidence: float
    reason: str
    path: str
    sam2_latency_ms: float | None
    muse_latency_ms: float


@app.get("/health")
def health(x_safeguard_token: str | None = Header(default=None)) -> dict:
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
        object_held=verdict.get("object_held", ""),
        confidence=verdict["confidence"],
        reason=verdict["reason"],
        path=path,
        sam2_latency_ms=round(sam2_latency * 1000, 1) if sam2_latency is not None else None,
        muse_latency_ms=round(muse_latency * 1000, 1),
    )


class SpeechVerifyRequest(BaseModel):
    snippet: str = Field(min_length=1, max_length=2000)
    on_device: dict = Field(default_factory=dict)


class SpeechVerifyResponse(BaseModel):
    severity: str
    categories: list[str]
    directed_at_wearer: bool
    reason: str
    names: list[dict] = []


@app.post("/verify-speech", response_model=SpeechVerifyResponse)
def verify_speech(
    request: SpeechVerifyRequest,
    x_safeguard_token: str | None = Header(default=None),
) -> SpeechVerifyResponse:
    require_app_token(x_safeguard_token)
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
        names=verdict.get("names", []),
    )


def log_speech_call(muse_latency: float, verdict: dict) -> None:
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
    if SETTINGS.storage_backend == "supabase":
        return
    try:
        os.makedirs(os.path.dirname(SETTINGS.verify_log_path) or ".", exist_ok=True)
        with open(SETTINGS.verify_log_path, "a") as handle:
            handle.write(line + "\n")
    except OSError as exc:
        logger.warning("could not write verify log: %s", exc)


def log_call(
    path: str, sam2_latency: float | None, muse_latency: float, threat_level: str
) -> None:
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
    if SETTINGS.storage_backend == "supabase":
        return
    try:
        os.makedirs(os.path.dirname(SETTINGS.verify_log_path) or ".", exist_ok=True)
        with open(SETTINGS.verify_log_path, "a") as handle:
            handle.write(line + "\n")
    except OSError as exc:
        logger.warning("could not write verify log: %s", exc)


_SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_EVIDENCE_KINDS = {"video": {"mp4"}, "audio": {"m4a"}, "init": {"mp4"}, "seg": {"m4s"}, "shot": {"jpg"}}


_evidence_backend: EvidenceBackend | None = None


def get_evidence() -> EvidenceBackend:
    global _evidence_backend
    if SETTINGS.storage_backend != "supabase":
        return make_evidence(SETTINGS)
    if _evidence_backend is None:
        _evidence_backend = make_evidence(SETTINGS)
    return _evidence_backend


def _evidence_root() -> Path:
    return Path(SETTINGS.evidence_dir)


def _check_evidence_or_app_token(evidence: str | None, app: str | None) -> None:
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
    dur: int = 0,
    x_evidence_token: str | None = Header(default=None),
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
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
    get_incidents().touch(session=session)
    body = await request.body()
    if not body:
        raise HTTPException(status_code=422, detail="empty segment")
    if len(body) > limit:
        raise HTTPException(status_code=413, detail="segment too large")
    if kind == "init":
        name = hls.INIT_NAME
    elif kind == "seg":
        if not 100 <= dur <= 20_000:
            raise HTTPException(status_code=422, detail="bad segment duration")
        name = hls.segment_name(seq, dur)
    else:
        name = f"{kind}-{seq:05d}.{ext}"
    get_evidence().put(session, name, body)
    logger.info("evidence stored kind=%s seq=%d bytes=%d", kind, seq, len(body))
    return {"stored": True, "bytes": len(body)}


@app.get("/evidence/{session}")
def list_evidence(
    session: str,
    x_evidence_token: str | None = Header(default=None),
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    _check_evidence_or_app_token(x_evidence_token, x_safeguard_token)
    if not _SESSION_RE.match(session):
        raise HTTPException(status_code=422, detail="bad session id")
    files = get_evidence().segments(session)
    if files is None:
        raise HTTPException(status_code=404, detail="no such session")
    return {"session": session, "files": files}


@app.delete("/evidence/{session}")
def delete_evidence(
    session: str,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    if not _SESSION_RE.match(session):
        raise HTTPException(status_code=422, detail="bad session id")
    if not get_evidence().delete_session(session):
        return {"deleted": False}
    logger.info("evidence deleted session=%s", session)
    return {"deleted": True}


_APPLOG_MAX_EVENTS = 200
_APPLOG_MAX_FIELD = 600


_applog_ring: "deque[str]" = deque(maxlen=2000)


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
    if lines and SETTINGS.storage_backend == "supabase":
        _applog_ring.extend(lines)
    elif lines:
        with _applog_path().open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return {"stored": len(lines)}


@app.get("/applog")
def get_applog(
    n: int = 100,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    count = max(1, min(n, 1000))
    if SETTINGS.storage_backend == "supabase":
        return {"events": [json.loads(line) for line in list(_applog_ring)[-count:]]}
    path = _applog_path()
    if not path.exists():
        return {"events": []}
    tail = path.read_text(encoding="utf-8").splitlines()[-count:]
    return {"events": [json.loads(line) for line in tail if line.strip()]}


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
                        await upstream.send(message["text"])

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
        logger.info(
            "asr session ended seconds=%.1f audio_bytes=%d events=%d",
            (datetime.now(timezone.utc) - started).total_seconds(), audio_bytes, events,
        )


class InviteRequest(BaseModel):
    name: str = Field(min_length=1, max_length=60)


@app.post("/contacts/invite")
def invite_contact(
    body: InviteRequest,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
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
    mode: str = Field(default="sos", pattern="^(sos|live|watch)$")
    channel_token: str | None = Field(default=None, max_length=64)
    guardian_code: str | None = Field(default=None, max_length=24)


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


def _send_to_codes(codes, text, dry_run, url_button=None, pin=None, notes=None) -> list:
    store = get_contact_store()
    notifier = _notifier_for(dry_run)
    delivery = []
    for code in codes:
        record = store.get(code)
        if record is None or record.get("chat_id") is None:
            delivery.append({"code": code, "status": "skipped", "detail": "not linked"})
            continue
        body = text + "\n\n" + notes[code] if notes and code in notes else text
        result = notifier.send_text(
            record["chat_id"], body, url_button=url_button
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


def _alert_guardian(incident, text: str, live: str, pin) -> dict:
    chat = get_guardians().chat_id(incident.guardian_code)
    if chat is None:
        return {"code": "guardian", "name": "Guardian", "status": "skipped", "detail": "not linked"}
    notifier = _notifier_for(incident.dry_run)
    portal = SETTINGS.public_base_url.rstrip("/") + "/"
    result = notifier.send_text(
        chat, text, url_button=[("Open live view", live), ("Open guardian portal", portal)]
    )
    if result.ok and pin is not None:
        notifier.send_location(chat, *pin)
    return {"code": "guardian", "name": "Guardian", "status": result.status, "detail": result.detail}


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
    channel = get_channels().by_token(body.channel_token) if body.channel_token else None
    guardian = normalize_code(body.guardian_code or "")
    incident, fresh = store.start(
        session=body.session,
        wearer_name=wearer,
        contact_codes=body.contact_codes,
        test=body.test,
        dry_run=body.dry_run,
        lang=body.lang,
        share_token=channel["token"] if channel else None,
        mode=body.mode,
        guardian_code=guardian,
    )
    live = live_url_for(incident.share_token)
    if not fresh:
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
    if body.mode in ("live", "watch"):
        store.save()
        return {
            "id": incident.id,
            "share_token": incident.share_token,
            "live_url": live,
            "delivery": [],
            "fresh": True,
            "preview_text": "",
        }
    if body.test:
        text = test_text(wearer, live, lang=body.lang)
    else:
        maps = maps_link(*pin) if pin else None
        ride = ride_link(body.lat, body.lon) if body.lat is not None and body.lon is not None else None
        text = alert_text(wearer, live, maps_url=maps, lang=body.lang, ride_url=ride)
    notes = {}
    if not body.test:
        located = [get_contact_store().get(code) for code in incident.contact_codes]
        notes = nearest_notes([r for r in located if r], pin, lang=body.lang)
    delivery = _send_to_codes(
        incident.contact_codes, text, incident.dry_run,
        url_button=("Open live view", live), pin=pin, notes=notes,
    )
    if incident.guardian_code and not body.test:
        delivery.append(_alert_guardian(incident, text, live, pin))
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


_SHOT_RE = r"^shot-\d{5}\.jpg$"
_PLATE_RE = re.compile(r"^[A-Z0-9][A-Z0-9 ]{4,12}[A-Z0-9]$")


class EvidenceItem(BaseModel):
    type: str = Field(pattern="^(name|plate|gesture)$")
    text: str = Field(min_length=1, max_length=60)
    rating: str = Field(pattern="^(possible|strongly possible)$")
    t: float
    source: str | None = Field(default=None, max_length=160)
    shot: str | None = Field(default=None, pattern=_SHOT_RE)
    count: int = Field(default=1, ge=1, le=50)


class EvidenceItemsBody(BaseModel):
    items: list[EvidenceItem] = Field(max_length=40)


def _clean_item(item: EvidenceItem) -> dict | None:
    text = " ".join("".join(c for c in item.text if c.isprintable()).split())
    if item.type == "plate":
        text = text.upper()
        if not _PLATE_RE.match(text):
            return None
    elif item.type == "name" and not _NAME_PATTERN.match(text):
        return None
    if not text:
        return None
    now = time.time()
    t = item.t if now - 86400 <= item.t <= now + 300 else now
    cleaned = {"type": item.type, "text": text, "rating": item.rating, "t": t, "count": item.count}
    if item.source:
        cleaned["source"] = " ".join(item.source.split())
    if item.shot:
        cleaned["shot"] = item.shot
    return cleaned


@app.post("/incident/{incident_id}/items")
def incident_items(
    incident_id: str,
    body: EvidenceItemsBody,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    cleaned = [c for c in (_clean_item(i) for i in body.items) if c]
    incident = get_incidents().upsert_items(incident_id, cleaned)
    if incident is None:
        raise HTTPException(status_code=404, detail="no such incident")
    return {"stored": len(cleaned), "total": len(incident.items)}


class TranscriptLine(BaseModel):
    t: float
    text: str = Field(min_length=1, max_length=300)


class TranscriptBody(BaseModel):
    lines: list[TranscriptLine] = Field(max_length=40)


@app.post("/incident/{incident_id}/transcript")
def incident_transcript(
    incident_id: str,
    body: TranscriptBody,
    x_safeguard_token: str | None = Header(default=None),
) -> dict:
    require_app_token(x_safeguard_token)
    lines = [
        {"t": line.t, "text": " ".join(line.text.split())}
        for line in body.lines if line.text.strip()
    ]
    incident = get_incidents().add_transcript(incident_id, lines)
    if incident is None:
        raise HTTPException(status_code=404, detail="no such incident")
    return {"stored": len(lines), "total": len(incident.transcript)}


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


def _idle_channel(share_token: str):
    return get_channels().by_token(share_token)


_SEGMENT_NAME_RE = re.compile(r"^(video|audio)-(\d{5})\.(mp4|m4a)$")


def _live_segments(incident, files=None) -> list:
    if files is None:
        files = get_evidence().segments(incident.session)
    if not files:
        return []
    found = []
    for entry in files:
        match = _SEGMENT_NAME_RE.match(entry["name"])
        if not match:
            continue
        kind, seq, ext = match.groups()
        if ext not in _EVIDENCE_KINDS[kind]:
            continue
        found.append({
            "kind": kind,
            "seq": int(seq),
            "name": entry["name"],
            "bytes": entry["bytes"],
            "url": f"segments/{entry['name']}",
        })
    found.sort(key=lambda item: (item["seq"], item["kind"]))
    return found


PLAYLIST_NAME = "stream.m3u8"


def _hls_entries(incident) -> list:
    return get_evidence().segments(incident.session) or []


def _hls_playlist_response(incident, url_for):
    entries = _hls_entries(incident)
    over = hls.is_over(incident.status == "ended", entries, time.time())
    text = hls.build_playlist(entries, url_for, over)
    if text is None:
        raise HTTPException(status_code=404, detail="nothing to play yet")
    return Response(
        text, media_type="application/vnd.apple.mpegurl", headers={"Cache-Control": "no-store"}
    )


def _hls_info(incident, entries=None) -> dict | None:
    if entries is None:
        entries = _hls_entries(incident)
    has_init, segments = hls.collect(entries)
    if not has_init or not segments:
        return None
    return {
        "playlist": PLAYLIST_NAME,
        "segments": len(segments),
        "over": hls.is_over(incident.status == "ended", entries, time.time()),
    }


@app.get("/live/{share_token}/stream.m3u8")
def live_playlist(share_token: str):
    incident = _live_incident_or_404(share_token)
    return _hls_playlist_response(incident, lambda name: f"segments/{name}")


@app.get("/live/{share_token}", response_class=HTMLResponse)
def live_page(share_token: str) -> str:
    if get_incidents().get_by_token(share_token) is None and _idle_channel(share_token) is None:
        raise HTTPException(status_code=404, detail="no such live page")
    return render_viewer_page(share_token)


@app.get("/live/{share_token}/state")
def live_state(share_token: str) -> dict:
    incident = get_incidents().get_by_token(share_token)
    if incident is None:
        owner = _idle_channel(share_token)
        if owner is None:
            raise HTTPException(status_code=404, detail="no such live page")
        return {
            "status": "idle", "mode": "live", "wearer_name": owner.get("wearer_name", ""),
            "started_at": None, "ended_at": None, "latest": None, "trail": [],
            "segments": [], "test": False,
        }
    points = list(incident.points)
    files = _hls_entries(incident)
    return {
        "mode": incident.mode,
        "status": incident.status,
        "wearer_name": incident.wearer_name,
        "started_at": incident.created_at,
        "ended_at": incident.ended_at or None,
        "latest": points[-1] if points else None,
        "trail": [{"lat": point["lat"], "lon": point["lon"]} for point in points],
        "segments": _live_segments(incident, files),
        "hls": _hls_info(incident, files),
        "test": incident.test,
    }


@app.get("/live/{share_token}/segments/{name}")
def live_segment(share_token: str, name: str, request: Request):
    incident = _live_incident_or_404(share_token)
    media = hls.media_type(name)
    if media is None:
        raise HTTPException(status_code=404, detail="no such segment")
    served = get_evidence().response(
        incident.session, name, media, request.headers.get("range")
    ) if get_evidence().exists(incident.session, name) else None
    if served is None:
        raise HTTPException(status_code=404, detail="no such segment")
    return served


_auth_limiter = RateLimiter(SETTINGS.auth_rate_per_min)
_accounts_override: SupabaseAccounts | None = None


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
        "guardian_code": row.get("guardian_code"),
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
    consent: bool = False
    guardian_code: str | None = Field(default=None, max_length=24)


class LoginRequest(BaseModel):
    email: str = Field(max_length=320)
    password: str = Field(max_length=200)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=10, max_length=4096)


class ProfileUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=60)
    phone: str | None = Field(default=None, max_length=24)
    language: str | None = Field(default=None, pattern="^(en|hi)$")
    guardian_code: str | None = Field(default=None, max_length=24)


def _checked_guardian_code(raw: str | None) -> str | None:
    if raw is None or not raw.strip():
        return None
    code = normalize_code(raw)
    if not code:
        raise HTTPException(status_code=422, detail="enter the guardian code as XXXX-XXXX-XXXX")
    if not get_guardians().exists(code):
        raise HTTPException(status_code=422, detail="that guardian code was not found")
    return code


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
    guardian = _checked_guardian_code(body.guardian_code)
    try:
        user, session = accounts.sign_up(
            email, body.password,
            {"name": name, "language": body.language},
        )
        row = accounts.upsert_profile(
            user["id"], email,
            {"name": name, "phone": body.phone, "language": body.language,
             "guardian_code": guardian},
            consent_at=datetime.now(timezone.utc).isoformat(),
        )
    except AccountsError as exc:
        raise _fail(exc) from exc
    return {
        "user": _profile_out(row, user),
        "session": session.as_dict() if session else None,
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
    if "guardian_code" in fields:
        fields["guardian_code"] = _checked_guardian_code(fields["guardian_code"]) or ""
    if "name" in fields and fields["name"]:
        fields["name"] = " ".join(fields["name"].split())
    try:
        row = accounts.update_profile(user["id"], fields)
    except AccountsError as exc:
        raise _fail(exc) from exc
    return _profile_out(row, user)


_AVATAR_MAX_BYTES = 600_000
_avatar_override = None


def _avatars():
    return _avatar_override or make_avatars(SETTINGS)


def _is_jpeg(data: bytes) -> bool:
    return len(data) > 4 and data[:3] == b"\xff\xd8\xff" and data[-2:] == b"\xff\xd9"


@app.put("/me/avatar")
async def me_avatar_put(
    request: Request,
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    user = _current_user(accounts, authorization)
    data = await request.body()
    if not data or len(data) > _AVATAR_MAX_BYTES:
        raise HTTPException(status_code=413, detail="picture is too large")
    if not _is_jpeg(data):
        raise HTTPException(status_code=422, detail="send a JPEG picture")
    try:
        _avatars().put(user["id"], data)
    except StorageUnavailable as exc:
        raise HTTPException(status_code=503, detail="picture storage unavailable") from exc
    return {"ok": True, "bytes": len(data)}


@app.get("/me/avatar")
def me_avatar_get(
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> Response:
    accounts = _auth_guard(x_safeguard_token)
    user = _current_user(accounts, authorization)
    try:
        data = _avatars().get(user["id"])
    except StorageUnavailable as exc:
        raise HTTPException(status_code=503, detail="picture storage unavailable") from exc
    if data is None:
        raise HTTPException(status_code=404, detail="no picture")
    return Response(content=data, media_type="image/jpeg", headers={"Cache-Control": "private, no-cache"})


@app.delete("/me/avatar")
def me_avatar_delete(
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    user = _current_user(accounts, authorization)
    try:
        _avatars().delete(user["id"])
    except StorageUnavailable as exc:
        raise HTTPException(status_code=503, detail="picture storage unavailable") from exc
    return {"ok": True}


@app.delete("/me")
def me_delete(
    x_safeguard_token: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> dict:
    accounts = _auth_guard(x_safeguard_token)
    user = _current_user(accounts, authorization)
    try:
        accounts.delete_user(user["id"])
        try:
            _avatars().delete(user["id"])
        except StorageUnavailable:
            pass
    except AccountsError as exc:
        raise _fail(exc) from exc
    return {"deleted": True}


_guardian_register_limiter = RateLimiter(6, 3600.0)
_guardian_fail_limiters: dict[str, RateLimiter] = {}
_guardian_ok_limiter = RateLimiter(240)
_MEDIA_SECRET = secrets.token_bytes(32)
_MEDIA_TTL_S = 6 * 3600
_DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")


def _client_ip(request: Request) -> str:
    return (
        request.headers.get("cf-connecting-ip")
        or (request.client.host if request.client else "")
        or "?"
    )


class ChannelRequest(BaseModel):
    device_id: str
    wearer_name: str = Field(default="", max_length=60)


@app.post("/live/channel")
def live_channel_create(
    body: ChannelRequest, x_safeguard_token: str | None = Header(default=None)
) -> dict:
    require_app_token(x_safeguard_token)
    if not _DEVICE_ID_RE.match(body.device_id):
        raise HTTPException(status_code=422, detail="bad device id")
    entry = get_channels().get_or_create(body.device_id, " ".join(body.wearer_name.split()))
    return {"token": entry["token"], "live_url": live_url_for(entry["token"])}


@app.delete("/live/channel/{device_id}")
def live_channel_revoke(
    device_id: str, x_safeguard_token: str | None = Header(default=None)
) -> dict:
    require_app_token(x_safeguard_token)
    if not _DEVICE_ID_RE.match(device_id):
        raise HTTPException(status_code=422, detail="bad device id")
    return {"revoked": get_channels().revoke(device_id)}


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
@app.get("/guardian", response_class=HTMLResponse)
def guardian_page() -> str:
    return render_guardian_page()


@app.post("/guardian/register")
def guardian_register(request: Request) -> dict:
    if not _guardian_register_limiter.allow():
        raise HTTPException(status_code=429, detail="too many codes requested")
    return {"code": get_guardians().create()}


@app.get("/guardian/check/{code}")
def guardian_check(code: str, x_safeguard_token: str | None = Header(default=None)) -> dict:
    require_app_token(x_safeguard_token)
    return {"valid": get_guardians().exists(code)}


def _guardian_from_header(request: Request, code: str | None) -> str:
    ip = _client_ip(request)
    limiter = _guardian_fail_limiters.setdefault(ip, RateLimiter(10))
    if not _guardian_ok_limiter.allow():
        raise HTTPException(status_code=429, detail="busy, try again in a minute")
    normalized = normalize_code(code or "")
    if not normalized or not get_guardians().exists(normalized):
        if not limiter.allow():
            raise HTTPException(status_code=429, detail="too many wrong codes, wait a minute")
        raise HTTPException(status_code=403, detail="that code is not valid")
    return normalized


def _media_sig(incident_id: str, name: str, expires: int) -> str:
    message = f"{incident_id}|{name}|{expires}".encode()
    return hmac.new(_MEDIA_SECRET, message, hashlib.sha256).hexdigest()[:40]


def _signed_media_url(incident_id: str, name: str) -> str:
    expires = int(time.time()) + _MEDIA_TTL_S
    sig = _media_sig(incident_id, name, expires)
    return f"/guardian/media/{incident_id}/{name}?exp={expires}&sig={sig}"


def _guardian_summary(incident, files=None) -> dict:
    if files is None:
        files = _hls_entries(incident)
    segments = _live_segments(incident, files)
    latest = incident.latest()
    return {
        "id": incident.id,
        "wearer_name": incident.wearer_name,
        "mode": incident.mode,
        "status": incident.status,
        "test": incident.test,
        "started_at": incident.created_at,
        "ended_at": incident.ended_at or None,
        "latest": latest,
        "videos": sum(1 for item in segments if item["kind"] == "video"),
        "audios": sum(1 for item in segments if item["kind"] == "audio"),
        "bytes": sum(item["bytes"] for item in segments) + sum(
            e["bytes"] for e in files if hls.is_hls_name(e["name"])
        ),
        "continuous": _hls_info(incident, files) is not None,
        "evidence_items": len(incident.items),
    }


@app.get("/guardian/api/alerts")
def guardian_alerts(
    request: Request, x_guardian_code: str | None = Header(default=None)
) -> dict:
    code = _guardian_from_header(request, x_guardian_code)
    bot = SETTINGS.telegram_bot
    enabled = SETTINGS.notify_mode == "telegram" and bool(bot)
    return {
        "available": enabled,
        "linked": get_guardians().chat_id(code) is not None,
        "link": guardian_invite_link(bot, code) if enabled else None,
    }


@app.get("/guardian/api/incidents")
def guardian_incidents(
    request: Request, x_guardian_code: str | None = Header(default=None)
) -> dict:
    code = _guardian_from_header(request, x_guardian_code)
    items = [_guardian_summary(i) for i in get_incidents().for_guardian(code)]
    return {"incidents": items}


@app.get("/guardian/api/incidents/{incident_id}")
def guardian_incident(
    incident_id: str, request: Request, x_guardian_code: str | None = Header(default=None)
) -> dict:
    code = _guardian_from_header(request, x_guardian_code)
    incident = get_incidents().get(incident_id)
    if incident is None or incident.guardian_code != code:
        raise HTTPException(status_code=404, detail="no such incident")
    files = _hls_entries(incident)
    detail = _guardian_summary(incident, files)
    detail["trail"] = [{"lat": p["lat"], "lon": p["lon"], "ts": p.get("ts")} for p in incident.points]
    detail["segments"] = [
        {**item, "url": _signed_media_url(incident.id, item["name"])}
        for item in _live_segments(incident, files)
    ]
    info = _hls_info(incident, files)
    detail["hls"] = info and {**info, "url": _signed_media_url(incident.id, PLAYLIST_NAME)}
    detail["transcript_lines"] = len(incident.transcript)
    present = {entry["name"] for entry in files}
    detail["items"] = [
        {**item, "shot_url": _signed_media_url(incident.id, item["shot"])}
        if item.get("shot") in present else {k: v for k, v in item.items() if k != "shot"}
        for item in incident.items
    ]
    return detail


_ask_limiters: dict[str, RateLimiter] = {}
_ask_global_limiter = RateLimiter(60, 3600.0)


class AskBody(BaseModel):
    shot: str = Field(pattern=_SHOT_RE)
    question: str = Field(min_length=3, max_length=300)


@app.post("/guardian/api/incidents/{incident_id}/ask")
def guardian_ask(
    incident_id: str,
    body: AskBody,
    request: Request,
    x_guardian_code: str | None = Header(default=None),
) -> dict:
    code = _guardian_from_header(request, x_guardian_code)
    incident = get_incidents().get(incident_id)
    if incident is None or incident.guardian_code != code:
        raise HTTPException(status_code=404, detail="no such incident")
    if body.shot not in {item.get("shot") for item in incident.items}:
        raise HTTPException(status_code=404, detail="no such moment")
    per_ip = _ask_limiters.setdefault(_client_ip(request), RateLimiter(6, 60.0))
    if not per_ip.allow() or not _ask_global_limiter.allow():
        raise HTTPException(status_code=429, detail="too many questions, wait a minute")
    data = get_evidence().read(incident.session, body.shot)
    if data is None:
        raise HTTPException(status_code=404, detail="no such moment")
    try:
        answer, latency = _muse_client.ask_about_image(
            base64.b64encode(data).decode(), " ".join(body.question.split())
        )
    except MuseError as exc:
        logger.warning("Muse ask failed: %s", exc)
        raise HTTPException(status_code=503, detail="Muse is unavailable right now")
    logger.info("guardian ask answered ms=%d", int(latency * 1000))
    return {"answer": answer, "latency_ms": round(latency * 1000)}


class ChatTurn(BaseModel):
    role: str = Field(pattern="^(user|assistant)$")
    content: str = Field(min_length=1, max_length=1700)


class ChatBody(BaseModel):
    question: str = Field(min_length=3, max_length=400)
    history: list[ChatTurn] = Field(default_factory=list, max_length=8)
    frames: list[str] = Field(default_factory=list, max_length=6)

    @field_validator("frames")
    @classmethod
    def _frames_are_small_base64(cls, value):
        for frame in value:
            if len(frame) > 160_000 or not re.fullmatch(r"[A-Za-z0-9+/=]+", frame):
                raise ValueError("bad frame")
        return value


def _chat_context(incident) -> str:
    started = incident.created_at
    lines = [f"[{int(max(0, line['t'] - started))}s] {line['text']}" for line in incident.transcript]
    transcript = "\n".join(lines)[-7000:] or "(nothing was transcribed)"
    noted = [
        f"- {item['type']}: {item['text']} ({item['rating']}, seen {item.get('count', 1)}x)"
        for item in incident.items
    ] or ["- nothing noted"]
    kind = {"live": "live stream", "watch": "protection session"}.get(incident.mode, "SOS")
    return (
        f"Type: {kind}. Wearer first name: {incident.wearer_name or 'unknown'}.\n"
        f"Location points recorded: {len(incident.points)}.\n"
        "Noted by the app:\n" + "\n".join(noted[:40]) + "\nTranscription:\n" + transcript
    )


_chat_limiters: dict[str, RateLimiter] = {}
_chat_global_limiter = RateLimiter(120, 3600.0)

CHAT_DISCLAIMER = "This is a suggestion from an AI and it can make mistakes."


@app.post("/guardian/api/incidents/{incident_id}/chat")
def guardian_chat(
    incident_id: str,
    body: ChatBody,
    request: Request,
    x_guardian_code: str | None = Header(default=None),
) -> dict:
    code = _guardian_from_header(request, x_guardian_code)
    incident = get_incidents().get(incident_id)
    if incident is None or incident.guardian_code != code:
        raise HTTPException(status_code=404, detail="no such incident")
    per_ip = _chat_limiters.setdefault(_client_ip(request), RateLimiter(10, 60.0))
    if not per_ip.allow() or not _chat_global_limiter.allow():
        raise HTTPException(status_code=429, detail="too many questions, wait a minute")
    history = [{"role": turn.role, "content": turn.content} for turn in body.history]
    try:
        answer, latency = _muse_client.chat_about_incident(
            _chat_context(incident), history, " ".join(body.question.split()), body.frames
        )
    except MuseError as exc:
        logger.warning("Muse chat failed: %s", exc)
        raise HTTPException(status_code=503, detail="Muse is unavailable right now")
    if CHAT_DISCLAIMER.lower() not in answer.lower():
        answer = answer.rstrip() + "\n" + CHAT_DISCLAIMER
    logger.info("guardian chat answered ms=%d", int(latency * 1000))
    return {"answer": answer, "latency_ms": round(latency * 1000), "lines": len(incident.transcript)}


@app.get("/guardian/media/{incident_id}/{name}")
def guardian_media(incident_id: str, name: str, request: Request, exp: int = 0, sig: str = ""):
    if exp < time.time() or not hmac.compare_digest(sig, _media_sig(incident_id, name, exp)):
        raise HTTPException(status_code=403, detail="link expired, reload the page")
    incident = get_incidents().get(incident_id)
    if incident is None or not incident.guardian_code:
        raise HTTPException(status_code=404, detail="no such recording")
    if name == PLAYLIST_NAME:
        return _hls_playlist_response(
            incident, lambda n: _signed_media_url(incident.id, n)
        )
    media = "image/jpeg" if re.match(_SHOT_RE, name) else hls.media_type(name)
    if media is None:
        raise HTTPException(status_code=404, detail="no such recording")
    served = get_evidence().response(
        incident.session, name, media, request.headers.get("range")
    ) if get_evidence().exists(incident.session, name) else None
    if served is None:
        raise HTTPException(status_code=404, detail="no such recording")
    return served


@app.get("/keepalive")
def keepalive() -> dict:
    if SETTINGS.storage_backend == "supabase" and SETTINGS.accounts_enabled:
        get_guardians()
        try:
            httpx.get(
                f"{SETTINGS.supabase_url}/rest/v1/profiles",
                params={"select": "id", "limit": "1"},
                headers={
                    "apikey": SETTINGS.supabase_service_role_key,
                    "Authorization": f"Bearer {SETTINGS.supabase_service_role_key}",
                },
                timeout=10,
            )
        except httpx.HTTPError:
            pass
    return {"ok": True}
