
import base64
import json

import httpx
import pytest

from app import main
from app.config import Settings
from tests.conftest import CANNED_LOW, FakeResponse, muse_envelope

FAKE_JPEG_B64 = base64.b64encode(b"fakejpegbytes").decode()


@pytest.fixture()
def sam2_mode(monkeypatch):
    monkeypatch.setattr(main, "SETTINGS", Settings(sam2_mode="sam2"))


@pytest.fixture()
def auto_mode(monkeypatch):
    monkeypatch.setattr(main, "SETTINGS", Settings(sam2_mode="auto"))


def valid_request(**overrides):
    body = {
        "frames_b64": [FAKE_JPEG_B64] * 4,
        "on_device_features": {"trend": 0.8, "persistence": 0.7},
        "boxes_xyxy": [[10.0, 10.0, 50.0, 100.0]],
    }
    body.update(overrides)
    return body


def test_health_reports_muse_key_presence(client, monkeypatch):
    assert client.get("/health").json() == {"status": "ok", "muse_configured": True}
    monkeypatch.setenv("META_MODEL_API_KEY", "")
    monkeypatch.setattr(main, "SETTINGS", Settings())
    assert client.get("/health").json() == {"status": "ok", "muse_configured": False}


def test_fallback_path_without_checkpoint(client, mock_muse):
    response = client.post("/verify", json=valid_request())
    assert response.status_code == 200
    body = response.json()
    assert body["path"] == "muse-only"
    assert body["sam2_latency_ms"] is None
    assert body["threat_level"] == "low"
    assert len(mock_muse) == 1


def test_sam2_path_with_mocked_runner(client, mock_muse, monkeypatch, sam2_mode):
    geometry = {"frames": 4, "objects": [{"id": 1, "mask_area_growth": 0.5}]}
    monkeypatch.setattr(
        "app.main._sam2.run", lambda frames, boxes: (geometry, 1.5)
    )
    response = client.post("/verify", json=valid_request())
    assert response.status_code == 200
    body = response.json()
    assert body["path"] == "sam2+muse"
    assert body["sam2_latency_ms"] == 1500.0
    sent = mock_muse[0]["json"]["messages"][1]["content"][0]["text"]
    assert "mask_area_growth" in sent


def test_slow_sam2_falls_back(client, mock_muse, monkeypatch, auto_mode):
    from app.sam2_local import Sam2Unavailable

    def slow_run(frames, boxes):
        raise Sam2Unavailable("over 3 s budget")

    monkeypatch.setattr("app.main._sam2.run", slow_run)
    response = client.post("/verify", json=valid_request())
    assert response.status_code == 200
    assert response.json()["path"] == "muse-only"


def test_rate_limit_20_per_min(client, mock_muse):
    for _ in range(20):
        assert client.post("/verify", json=valid_request()).status_code == 200
    response = client.post("/verify", json=valid_request())
    assert response.status_code == 429
    assert len(mock_muse) == 20


def test_muse_timeout_maps_to_503(client, monkeypatch):
    def slow_post(url, headers=None, json=None, timeout=None):
        raise httpx.TimeoutException("too slow")

    monkeypatch.setattr("app.muse.httpx.post", slow_post)
    response = client.post("/verify", json=valid_request())
    assert response.status_code == 503


def test_stationary_verdict_passthrough(client, mock_muse):
    response = client.post("/verify", json=valid_request())
    body = response.json()
    assert body["threat_level"] == "low"
    assert "stationary" in body["reason"]
    assert body["behaviours_observed"] == ["standing still"]


def test_strict_json_rejection(client, monkeypatch):
    def garbage_post(url, headers=None, json=None, timeout=None):
        return FakeResponse('{"choices": []}')

    monkeypatch.setattr("app.muse.httpx.post", garbage_post)
    assert client.post("/verify", json=valid_request()).status_code == 503


def test_appearance_verdict_refused(client, monkeypatch):
    bad = dict(
        CANNED_LOW,
        reason="A man wearing a red shirt is approaching.",
        threat_level="high",
    )

    def bad_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(bad))

    monkeypatch.setattr("app.muse.httpx.post", bad_post)
    assert client.post("/verify", json=valid_request()).status_code == 503


def test_empty_frames_rejected(client):
    assert client.post("/verify", json=valid_request(frames_b64=[])).status_code == 422


def test_bad_base64_rejected(client):
    body = valid_request(frames_b64=["!!!not-base64!!!"])
    assert client.post("/verify", json=body).status_code == 422


def test_daily_counter_log(client, mock_muse):
    client.post("/verify", json=valid_request())
    client.post("/verify", json=valid_request())
    with open("/tmp/sg-test-verify.jsonl") as handle:
        lines = [json.loads(line) for line in handle]
    assert len(lines) == 2
    assert lines[0]["day_count"] == 1
    assert lines[1]["day_count"] == 2
    assert lines[0]["path"] == "muse-only"
    assert lines[0]["muse_latency_ms"] >= 0
