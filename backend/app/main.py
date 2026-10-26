"""Safeguard backend.

Phase 1: health check. Phase 4: POST /verify (SAM 2 + Muse, with fallback).
Phase 6 adds the incident/alert/stream endpoints. No API keys in code: all
configuration comes from environment variables (see /.env.example).
"""

import base64
import binascii
import json
import logging
import os
from collections import Counter
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel, Field

from .config import SETTINGS
from .muse import MuseClient, MuseError
from .ratelimit import RateLimiter
from .sam2_local import Sam2Runner, Sam2Unavailable

logger = logging.getLogger("safeguard.verify")

app = FastAPI(title="Safeguard backend")

_muse_limiter = RateLimiter(SETTINGS.muse_calls_per_min)
_muse_client = MuseClient(
    base_url=SETTINGS.meta_model_base_url,
    api_key=SETTINGS.meta_model_api_key,
    model=SETTINGS.muse_model,
    timeout_s=SETTINGS.muse_timeout_s,
)
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
