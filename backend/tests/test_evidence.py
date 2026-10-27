"""POST /evidence: raw segment upload with validated names, size cap, token."""

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "SETTINGS", Settings(evidence_dir=str(tmp_path), evidence_token="", evidence_max_mb=1))
    return TestClient(main.app), tmp_path


def post(c, body=b"\x00\x01fake-bytes", **params):
    q = {"session": "sos-1234abcd", "kind": "video", "seq": 0, "ext": "mp4"}
    q.update(params)
    return c.post("/evidence", params=q, content=body)


def test_stores_a_segment_under_a_server_chosen_name(client):
    c, root = client
    r = post(c)
    assert r.status_code == 200 and r.json() == {"stored": True, "bytes": 12}
    assert (root / "sos-1234abcd" / "video-00000.mp4").read_bytes() == b"\x00\x01fake-bytes"


def test_audio_and_listing(client):
    c, _ = client
    post(c, kind="audio", ext="m4a", seq=3)
    post(c, seq=1)
    listing = c.get("/evidence/sos-1234abcd").json()
    assert [f["name"] for f in listing["files"]] == ["audio-00003.m4a", "video-00001.mp4"]


@pytest.mark.parametrize("params", [
    {"session": "../etc"}, {"session": "short"}, {"session": "a/b/c/d/e/f/g/h"},
    {"kind": "script"}, {"ext": "sh"}, {"kind": "audio", "ext": "mp4"}, {"seq": -1}, {"seq": 999999},
])
def test_rejects_bad_fields_and_path_tricks(client, params):
    c, root = client
    assert post(c, **params).status_code == 422
    assert not list(root.rglob("*.*"))


def test_rejects_empty_and_oversized(client):
    c, _ = client
    assert post(c, body=b"").status_code == 422
    assert post(c, body=b"x" * (1024 * 1024 + 1)).status_code == 413


def test_token_required_when_configured(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "SETTINGS", Settings(evidence_dir=str(tmp_path), evidence_token="t0k3n-for-test", evidence_max_mb=1))
    c = TestClient(main.app)
    assert post(c).status_code == 401
    ok = c.post(
        "/evidence",
        params={"session": "sos-1234abcd", "kind": "video", "seq": 0, "ext": "mp4"},
        content=b"abc",
        headers={"X-Evidence-Token": "t0k3n-for-test"},
    )
    assert ok.status_code == 200


def test_unknown_session_listing_is_404(client):
    c, _ = client
    assert c.get("/evidence/sos-nothere1").status_code == 404
