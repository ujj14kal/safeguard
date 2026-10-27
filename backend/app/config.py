"""Backend settings. Everything comes from environment variables (see /.env.example)."""

import os
from dataclasses import dataclass, field


def _float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    # Meta Model API (Muse). Docs: https://dev.meta.ai/docs
    # Base URL + auth header + Chat Completions (documented as the
    # OpenAI-compatible messages-array endpoint). Model default is the
    # documented Spark flagship; override with MUSE_MODEL.
    meta_model_base_url: str = field(
        default_factory=lambda: os.environ.get(
            "META_MODEL_API_BASE_URL", "https://api.meta.ai/v1"
        )
    )
    meta_model_api_key: str = field(
        default_factory=lambda: os.environ.get("META_MODEL_API_KEY", "")
    )
    muse_model: str = field(
        default_factory=lambda: os.environ.get("MUSE_MODEL", "muse-spark-1.3")
    )
    muse_timeout_s: float = field(
        default_factory=lambda: _float("MUSE_TIMEOUT_S", 20.0)
    )
    muse_calls_per_min: int = field(
        default_factory=lambda: _int("VERIFY_RATE_LIMIT_PER_MIN", 20)
    )
    # SOS evidence (video and audio segments uploaded by the app). The Mac
    # backend is the "cloud" for the demo; EVIDENCE_DIR can point at a synced
    # or mounted bucket. If EVIDENCE_TOKEN is set, uploads must send it in
    # the X-Evidence-Token header.
    evidence_dir: str = field(default_factory=lambda: os.environ.get("EVIDENCE_DIR", "evidence"))
    evidence_token: str = field(default_factory=lambda: os.environ.get("EVIDENCE_TOKEN", ""))
    evidence_max_mb: int = field(default_factory=lambda: _int("EVIDENCE_MAX_MB", 80))

    # Muse reasoning effort (minimal|low|medium|high). Measured on the labelled
    # speech set: minimal is as accurate as the default at roughly a third of
    # the latency (median 2.2 s vs ~6 s).
    speech_reasoning_effort: str = field(
        default_factory=lambda: os.environ.get("SPEECH_REASONING_EFFORT", "minimal")
    )
    verify_reasoning_effort: str = field(
        default_factory=lambda: os.environ.get("VERIFY_REASONING_EFFORT", "low")
    )

    # Muse Voice Transcribe (realtime speech to text). The key stays here;
    # the phone streams audio to /asr and this relays it to Meta.
    asr_upstream_url: str = field(
        default_factory=lambda: os.environ.get(
            "ASR_UPSTREAM_URL", "wss://api.meta.ai/v1/asr/realtime"
        )
    )
    asr_model: str = field(
        default_factory=lambda: os.environ.get("ASR_MODEL", "muse-voice-transcribe-1.0")
    )

    # Continuous conversation judging sends a text snippet every few seconds,
    # so it gets its own budget and cannot starve /verify.
    speech_calls_per_min: int = field(
        default_factory=lambda: _int("SPEECH_RATE_LIMIT_PER_MIN", 40)
    )

    # SAM 2 (local, optional). Mode: auto (try, fall back on slow/fail),
    # sam2 (require; 503 if unavailable), muse-only (never try).
    # Default is muse-only: the Phase 4 spike timed the tiny checkpoint at
    # 9.1 s per 8-frame clip on CPU (budget 3 s). Use sam2/auto on GPU hardware.
    sam2_mode: str = field(default_factory=lambda: os.environ.get("SAM2_MODE", "muse-only"))
    sam2_checkpoint_path: str = field(
        default_factory=lambda: os.environ.get("SAM2_CHECKPOINT_PATH", "")
    )
    sam2_config: str = field(
        default_factory=lambda: os.environ.get(
            "SAM2_CONFIG", "configs/sam2.1/sam2.1_hiera_t.yaml"
        )
    )
    sam2_max_latency_s: float = field(
        default_factory=lambda: _float("SAM2_MAX_LATENCY_S", 3.0)
    )
    sam2_retry_after_s: float = field(
        default_factory=lambda: _float("SAM2_RETRY_AFTER_S", 600.0)
    )
    verify_corridor_half_width: float = field(
        default_factory=lambda: _float("VERIFY_CORRIDOR_HALF_WIDTH", 0.18)
    )

    # Logging.
    verify_log_path: str = field(
        default_factory=lambda: os.environ.get(
            "VERIFY_LOG_PATH", "logs/verify.jsonl"
        )
    )

    # Phase 6: SOS escalation. The app token guards every app-to-backend
    # endpoint when set (local dev may leave it empty, with a warning).
    app_token: str = field(
        default_factory=lambda: os.environ.get("SAFEGUARD_APP_TOKEN", "")
    )
    notify_mode: str = field(
        default_factory=lambda: os.environ.get("NOTIFY_MODE", "dry-run")
    )
    telegram_bot_token: str = field(
        default_factory=lambda: os.environ.get("TELEGRAM_BOT_TOKEN", "")
    )
    telegram_bot: str = field(
        default_factory=lambda: os.environ.get(
            "TELEGRAM_BOT", "safeguard_demo_bot"
        )
    )
    public_base_url: str = field(
        default_factory=lambda: os.environ.get(
            "PUBLIC_BASE_URL", "http://127.0.0.1:8000"
        )
    )
    contacts_path: str = field(
        default_factory=lambda: os.environ.get(
            "CONTACTS_PATH", "data/contacts.json"
        )
    )
    notify_log_path: str = field(
        default_factory=lambda: os.environ.get(
            "NOTIFY_LOG_PATH", "logs/notifications.jsonl"
        )
    )
    incident_rate_per_min: int = field(
        default_factory=lambda: int(
            os.environ.get("INCIDENT_RATE_LIMIT_PER_MIN", "10")
        )
    )


SETTINGS = Settings()
