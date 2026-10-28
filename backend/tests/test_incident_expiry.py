
import json

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.incidents import IncidentStore

fake_app_token = "-".join(["not", "a", "real", "app", "token"])


class Clock:
    def __init__(self):
        self.now = 1_000_000.0

    def __call__(self):
        return self.now


def make_store(path, clock, **kwargs):
    return IncidentStore(path=str(path), clock=clock, **kwargs)


def test_active_link_expires_after_the_maximum(tmp_path):
    clock = Clock()
    store = make_store(tmp_path / "i.json", clock, max_active_s=3600)
    incident, _ = store.start("sos-aaaaaaaa", "A", [])
    assert store.get_by_token(incident.share_token) is incident
    clock.now += 3601
    assert store.get_by_token(incident.share_token) is None


def test_ended_link_expires_after_the_ttl(tmp_path):
    clock = Clock()
    store = make_store(tmp_path / "i.json", clock, ttl_after_end_s=600)
    incident, _ = store.start("sos-bbbbbbbb", "A", [])
    store.end(incident.id)
    clock.now += 599
    assert store.get_by_token(incident.share_token) is incident
    clock.now += 2
    assert store.get_by_token(incident.share_token) is None


def test_an_expired_session_can_start_a_fresh_incident(tmp_path):
    clock = Clock()
    store = make_store(tmp_path / "i.json", clock, max_active_s=100)
    first, _ = store.start("sos-cccccccc", "A", [])
    clock.now += 200
    second, fresh = store.start("sos-cccccccc", "A", [])
    assert fresh and second.share_token != first.share_token


def test_incident_survives_a_restart_with_its_trail(tmp_path):
    clock = Clock()
    path = tmp_path / "i.json"
    store = make_store(path, clock)
    incident, _ = store.start("sos-dddddddd", "Asha", ["code1"])
    store.add_point(incident.id, 28.61, 77.2, 10, ts=1)
    store.add_point(incident.id, 28.62, 77.21, 10, ts=2)
    clock.now += 10
    store.add_point(incident.id, 28.63, 77.22, 10, ts=3)
    store.end(incident.id)

    reloaded = make_store(path, clock)
    again = reloaded.get_by_token(incident.share_token)
    assert again is not None and again.wearer_name == "Asha" and again.status == "ended"
    assert len(again.points) == 3
    assert reloaded.start("sos-dddddddd", "Asha", [])[1] is True


def test_expired_incidents_are_not_reloaded_or_kept_on_disk(tmp_path):
    clock = Clock()
    path = tmp_path / "i.json"
    store = make_store(path, clock, max_active_s=100)
    store.start("sos-eeeeeeee", "A", [])
    clock.now += 500
    assert make_store(path, clock, max_active_s=100)._by_id == {}
    store.save()
    assert json.loads(path.read_text()) == []


def test_a_corrupt_file_does_not_break_startup(tmp_path):
    path = tmp_path / "i.json"
    path.write_text("{not json")
    assert make_store(path, Clock())._by_id == {}


def test_share_link_expiry_is_enforced_by_the_live_endpoints(tmp_path, monkeypatch):
    clock = Clock()
    store = make_store(tmp_path / "i.json", clock, ttl_after_end_s=60)
    monkeypatch.setattr(main, "_incidents", store)
    monkeypatch.setattr(main, "SETTINGS", Settings(app_token="", public_base_url="https://demo.test"))
    client = TestClient(main.app)
    incident, _ = store.start("sos-ffffffff", "A", [])
    assert client.get(f"/live/{incident.share_token}/state").status_code == 200
    store.end(incident.id)
    clock.now += 61
    assert client.get(f"/live/{incident.share_token}/state").status_code == 404
    assert client.get(f"/live/{incident.share_token}").status_code == 404


def test_health_only_reveals_the_key_state_to_the_app(monkeypatch):
    no_key = ""
    monkeypatch.setattr(
        main,
        "SETTINGS",
        Settings(
            app_token=fake_app_token,
            meta_model_api_key=no_key,
        ),
    )
    client = TestClient(main.app)
    assert client.get("/health").json() == {"status": "ok"}
    assert client.get("/health", headers={"X-Safeguard-Token": "wrong"}).json() == {"status": "ok"}
    full = client.get("/health", headers={"X-Safeguard-Token": fake_app_token}).json()
    assert full == {"status": "ok", "muse_configured": False}
