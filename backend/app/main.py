"""Safeguard backend.

Phase 1: health check. Phase 4: POST /verify (SAM 2 + Muse, with fallback).
Phase 5: POST /verify-speech (Muse judges a text snippet, never audio).
Phase 6 adds the incident/alert/stream endpoints. No API keys in code: all
configuration comes from environment variables (see /.env.example).
"""

import base64
import binascii
import json
import logging
import os
import re
from collections import Counter
from datetime import datetime, timezone

from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel, Field

from .config import SETTINGS
from .muse import MuseClient, MuseError
from .ratelimit import RateLimiter
from .sam2_local import Sam2Runner, Sam2Unavailable

logger = logging.getLogger("safeguard.verify")

app = FastAPI(title="Safeguard backend")

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
def health() -> dict:
    # muse_configured tells the app whether a 5xx means "no API key" (setup
    # problem) rather than a crash. The key itself never leaves the backend.
    return {"status": "ok", "muse_configured": bool(SETTINGS.meta_model_api_key)}


@app.post("/verify", response_model=VerifyResponse)
def verify(request: VerifyRequest) -> VerifyResponse:
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
def verify_speech(request: SpeechVerifyRequest) -> SpeechVerifyResponse:
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


def _check_evidence_token(token: str | None) -> None:
    if SETTINGS.evidence_token and token != SETTINGS.evidence_token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="bad evidence token")


@app.post("/evidence")
async def upload_evidence(
    request: Request,
    session: str,
    kind: str,
    seq: int,
    ext: str,
    x_evidence_token: str | None = Header(default=None),
) -> dict:
    """Store one recording segment (raw bytes in the body) from an SOS.

    The app records video and audio in short segments while an SOS runs and
    uploads each as soon as it is closed, so a phone that is taken or
    smashed has already sent most of the evidence. File names are fixed by
    the server from validated fields; nothing from the client is used as a path.
    """
    _check_evidence_token(x_evidence_token)
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
def list_evidence(session: str, x_evidence_token: str | None = Header(default=None)) -> dict:
    """List the segments stored for one SOS session (names and sizes only)."""
    _check_evidence_token(x_evidence_token)
    if not _SESSION_RE.match(session):
        raise HTTPException(status_code=422, detail="bad session id")
    folder = _evidence_root() / session
    if not folder.is_dir():
        raise HTTPException(status_code=404, detail="no such session")
    files = [{"name": f.name, "bytes": f.stat().st_size} for f in sorted(folder.iterdir())]
    return {"session": session, "files": files}


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
def post_applog(batch: AppLogBatch) -> dict:
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
def get_applog(n: int = 100) -> dict:
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

