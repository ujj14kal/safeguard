import json as json_lib
import os

os.environ["META_MODEL_API_KEY"] = "fake-test-key"
os.environ["MUSE_MODEL"] = "test-model"
os.environ["MUSE_TIMEOUT_S"] = "5"
os.environ["VERIFY_RATE_LIMIT_PER_MIN"] = "20"
if os.environ.get("SAM2_MODE") != "sam2":
    os.environ.pop("SAM2_CHECKPOINT_PATH", None)
os.environ["VERIFY_LOG_PATH"] = "/tmp/sg-test-verify.jsonl"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app import main  # noqa: E402
from app.ratelimit import RateLimiter  # noqa: E402


@pytest.fixture(autouse=True)
def fresh_state():
    main._muse_limiter = RateLimiter(20)
    main._daily_counts.clear()
    if os.path.exists("/tmp/sg-test-verify.jsonl"):
        os.remove("/tmp/sg-test-verify.jsonl")
    yield


@pytest.fixture()
def client():
    return TestClient(main.app)


class FakeResponse:
    def __init__(self, text: str, status_code: int = 200):
        self.text = text
        self.status_code = status_code


def muse_envelope(verdict: dict) -> str:
    return json_lib.dumps({"choices": [{"message": {"content": json_lib.dumps(verdict)}}]})


CANNED_LOW = {
    "threat_level": "low",
    "behaviours_observed": ["standing still"],
    "confidence": 0.9,
    "reason": "Person is stationary, not a threat.",
}


@pytest.fixture()
def mock_muse(monkeypatch):
    calls: list[dict] = []

    def fake_post(url, headers=None, json=None, timeout=None):
        calls.append({"url": url, "headers": headers, "json": json, "timeout": timeout})
        return FakeResponse(muse_envelope(CANNED_LOW))

    monkeypatch.setattr("app.muse.httpx.post", fake_post)
    return calls
