"""Safeguard backend skeleton. Phase 1: health check only.

Phase 4 adds POST /verify (SAM 2 + Muse); Phase 6 adds the incident,
alert, ingest, watch and live endpoints. No API keys in code: all
configuration comes from environment variables (see /.env.example).
"""

from fastapi import FastAPI

app = FastAPI(title="Safeguard backend")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}
