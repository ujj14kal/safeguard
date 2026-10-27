"""Supabase storage mode: state and recordings live in Storage buckets, so a
host that sleeps or restarts loses nothing. A fake Storage plays Supabase."""

import json
import re
from urllib.parse import unquote

import pytest
from fastapi.testclient import TestClient

from app import main, storage
from app.config import Settings
from app.contacts import ContactStore
from app.incidents import IncidentStore
from app.links import ChannelStore, GuardianStore
from app.ratelimit import RateLimiter
from app.storage import StorageUnavailable, SupabaseObjects, SupabaseStateFile

URL = "https://example-project.supabase.test"
KEY = "service-" + "k" * 12


class FakeStorage:
    def __init__(self):
        self.objects: dict[tuple[str, str], bytes] = {}
        self.down = False
        self.calls: list[tuple[str, str]] = []

    def http(self, method, url, *, headers, content=None, json=None, timeout=20.0):
        if self.down:
            raise StorageUnavailable("ConnectError")
        assert headers["apikey"].startswith("service-"), "service key must ride in headers"
        path = unquote(url.replace(f"{URL}/storage/v1", ""))
        self.calls.append((method, path))
        if path == "/bucket":
            return 200, {}, b"{}"
        m = re.match(r"^/object/list/([^/]+)$", path)
        if m:
            bucket, prefix = m.group(1), json["prefix"]
            items = [
                {"name": p.split("/", 1)[1], "id": "x", "metadata": {"size": len(v)}}
                for (b, p), v in sorted(self.objects.items())
                if b == bucket and p.startswith(prefix + "/")
            ]
            return 200, {}, __import__("json").dumps(items).encode()
        m = re.match(r"^/object/([^/]+)$", path)
        if m and method == "DELETE":
            for victim in json["prefixes"]:
                self.objects.pop((m.group(1), victim), None)
            return 200, {}, b"[]"
        m = re.match(r"^/object/([^/]+)/(.+)$", path)
        if m:
            key = (m.group(1), m.group(2))
            if method == "POST":
                self.objects[key] = content
                return 200, {}, b"{}"
            if method == "GET":
                if key in self.objects:
                    return 200, {}, self.objects[key]
                return 400, {}, b'{"error":"not_found"}'
        return 404, {}, b"{}"

    def stream(self, url, *, headers, timeout=30.0):
        if self.down:
            raise StorageUnavailable("ConnectError")
        m = re.match(r"^.*/object/([^/]+)/(.+)$", unquote(url))
        data = self.objects.get((m.group(1), m.group(2)))
        if data is None:
            return 400, {}, iter([b""])
        rng = headers.get("Range")
        if rng:
            a, b = re.match(r"bytes=(\d+)-(\d*)", rng).groups()
            start, end = int(a), int(b) if b else len(data) - 1
            part = data[start:end + 1]
            return 206, {"Content-Range": f"bytes {start}-{start + len(part) - 1}/{len(data)}",
                         "Content-Length": str(len(part))}, iter([part])
        return 200, {"Content-Length": str(len(data))}, iter([data])


@pytest.fixture()
def fake(monkeypatch):
    f = FakeStorage()
    monkeypatch.setattr(storage, "_http", f.http)
    monkeypatch.setattr(storage, "_stream", f.stream)
    return f


@pytest.fixture()
def hosted(fake, monkeypatch):
    """The app in Supabase mode with empty stores (as after a cold start)."""
    settings = Settings(
        storage_backend="supabase", supabase_url=URL, supabase_service_role_key=KEY,
        supabase_anon_key="anon", app_token="", public_base_url="https://demo.test",
        notify_mode="dry-run",
    )
    monkeypatch.setattr(main, "SETTINGS", settings)
    for name in ("_contact_store", "_incidents", "_guardians", "_channels", "_evidence_backend"):
        monkeypatch.setattr(main, name, None)
    monkeypatch.setattr(main, "_incident_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "_guardian_register_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "_guardian_fail_limiters", {})
    monkeypatch.setattr(main, "_guardian_ok_limiter", RateLimiter(1000))
    return TestClient(main.app)


def cold_start(monkeypatch):
    for name in ("_contact_store", "_incidents", "_guardians", "_channels"):
        monkeypatch.setattr(main, name, None)


def start(api, **over):
    body = {"session": "sos-abcdef12", "wearer_name": "Asha", "dry_run": True, "lat": 28.6, "lon": 77.2}
    body.update(over)
    res = api.post("/incident/start", json=body)
    assert res.status_code == 200, res.text
    return res.json()


# --- the state file ----------------------------------------------------------

def test_state_file_round_trip_and_missing(fake):
    f = SupabaseStateFile(SupabaseObjects(URL, KEY, "safeguard-state"), "x.json")
    assert f.read() is None
    f.write('{"a": 1}')
    assert f.read() == '{"a": 1}'
    f.write('{"a": 2}')
    assert f.read() == '{"a": 2}'


def test_unreachable_storage_raises_not_empty(fake):
    fake.down = True
    f = SupabaseStateFile(SupabaseObjects(URL, KEY, "safeguard-state"), "x.json")
    with pytest.raises(StorageUnavailable):
        f.read()


def test_stores_survive_a_cold_start(fake):
    files = lambda name: SupabaseStateFile(SupabaseObjects(URL, KEY, "safeguard-state"), name)  # noqa: E731
    incidents = IncidentStore(path=files("incidents.json"))
    inc, _ = incidents.start("sos-abcdef12", "Asha", [], guardian_code="AAAA-BBBB-CCCC")
    incidents.add_point(inc.id, 1.0, 2.0)
    incidents.save()
    guardians = GuardianStore(files("guardians.json"))
    code = guardians.create()
    channels = ChannelStore(files("channels.json"))
    token = channels.get_or_create("device-1234", "Asha")["token"]
    contacts = ContactStore(files("contacts.json"))
    invite = contacts.invite("Meera")
    # A new process, nothing in memory:
    again = IncidentStore(path=files("incidents.json"))
    assert again.get(inc.id).guardian_code == "AAAA-BBBB-CCCC"
    assert again.get(inc.id).latest()["lat"] == 1.0
    assert GuardianStore(files("guardians.json")).exists(code)
    assert ChannelStore(files("channels.json")).by_token(token) is not None
    assert ContactStore(files("contacts.json")).get(invite["code"])["name"] == "Meera"


def test_a_failed_read_never_overwrites_real_data(fake):
    files = lambda name: SupabaseStateFile(SupabaseObjects(URL, KEY, "safeguard-state"), name)  # noqa: E731
    store = GuardianStore(files("guardians.json"))
    code = store.create()
    fake.down = True
    with pytest.raises(StorageUnavailable):
        GuardianStore(files("guardians.json"))
    fake.down = False
    assert GuardianStore(files("guardians.json")).exists(code)


# --- the API ------------------------------------------------------------------

def test_recordings_go_to_the_bucket_and_play_back_with_ranges(hosted, fake):
    inc = start(hosted)
    body = bytes(range(256)) * 40
    res = hosted.post("/evidence?session=sos-abcdef12&kind=video&seq=0&ext=mp4", content=body)
    assert res.json() == {"stored": True, "bytes": len(body)}
    assert ("safeguard-evidence", "sos-abcdef12/video-00000.mp4") in fake.objects
    state = hosted.get(f"/live/{inc['share_token']}/state").json()
    assert [(s["kind"], s["bytes"]) for s in state["segments"]] == [("video", len(body))]
    full = hosted.get(f"/live/{inc['share_token']}/segments/video-00000.mp4")
    assert full.status_code == 200 and full.content == body
    part = hosted.get(f"/live/{inc['share_token']}/segments/video-00000.mp4", headers={"Range": "bytes=10-19"})
    assert part.status_code == 206 and part.content == body[10:20]
    assert part.headers["content-range"].startswith("bytes 10-19/")


def test_cold_start_keeps_the_family_link_working(hosted, fake, monkeypatch):
    inc = start(hosted)
    hosted.post("/evidence?session=sos-abcdef12&kind=audio&seq=0&ext=m4a", content=b"a" * 100)
    cold_start(monkeypatch)
    state = hosted.get(f"/live/{inc['share_token']}/state")
    assert state.status_code == 200 and state.json()["status"] == "active"
    assert state.json()["segments"][0]["kind"] == "audio"


def test_guardian_flow_works_on_storage(hosted, fake, monkeypatch):
    code = hosted.post("/guardian/register").json()["code"]
    inc = start(hosted, guardian_code=code)
    hosted.post("/evidence?session=sos-abcdef12&kind=video&seq=0&ext=mp4", content=b"v" * 50)
    cold_start(monkeypatch)
    listing = hosted.get("/guardian/api/incidents", headers={"X-Guardian-Code": code}).json()
    assert len(listing["incidents"]) == 1
    detail = hosted.get(f"/guardian/api/incidents/{inc['id']}", headers={"X-Guardian-Code": code}).json()
    assert hosted.get(detail["segments"][0]["url"]).content == b"v" * 50


def test_delete_evidence_removes_the_objects(hosted, fake):
    hosted.post("/evidence?session=sos-abcdef12&kind=video&seq=0&ext=mp4", content=b"v")
    hosted.post("/evidence?session=sos-abcdef12&kind=audio&seq=0&ext=m4a", content=b"a")
    assert hosted.delete("/evidence/sos-abcdef12").json() == {"deleted": True}
    assert not [k for k in fake.objects if k[0] == "safeguard-evidence"]
    assert hosted.delete("/evidence/sos-abcdef12").json() == {"deleted": False}


def test_storage_outage_is_503_not_data_loss(hosted, fake):
    fake.down = True
    res = hosted.post("/guardian/register")
    assert res.status_code == 503 and "storage unavailable" in res.json()["detail"]


def test_applog_stays_in_memory_with_no_disk(hosted, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    assert hosted.post("/applog", json={"events": [{"kind": "x", "v": 1}]}).json() == {"stored": 1}
    assert hosted.get("/applog").json()["events"][-1]["kind"] == "x"
    assert not (tmp_path / "logs").exists()


# --- Telegram webhook ----------------------------------------------------------

def test_telegram_webhook_links_a_contact_and_checks_the_secret(hosted, fake, monkeypatch):
    monkeypatch.setattr(main, "SETTINGS", Settings(
        storage_backend="supabase", supabase_url=URL, supabase_service_role_key=KEY,
        telegram_bot_token="bot-" + "t" * 10, notify_mode="telegram", app_token="",
    ))
    invite = hosted.post("/contacts/invite", json={"name": "Meera"})
    code = invite.json()["code"]
    update = {"update_id": 5, "message": {"text": f"/start {code}", "chat": {"id": 4242}}}
    assert hosted.post("/telegram/webhook", json=update).status_code == 401
    wrong = hosted.post("/telegram/webhook", json=update,
                        headers={"X-Telegram-Bot-Api-Secret-Token": "nope"})
    assert wrong.status_code == 401
    ok = hosted.post("/telegram/webhook", json=update,
                     headers={"X-Telegram-Bot-Api-Secret-Token": main._telegram_webhook_secret()})
    assert ok.status_code == 200
    assert main.get_contact_store().get(code)["chat_id"] == 4242


def test_webhook_is_off_without_a_bot_token(hosted):
    res = hosted.post("/telegram/webhook", json={}, headers={"X-Telegram-Bot-Api-Secret-Token": ""})
    assert res.status_code == 401


def test_keepalive_touches_storage_and_always_answers(hosted, fake):
    assert hosted.get("/keepalive").json() == {"ok": True}
    assert any(path.startswith("/object/safeguard-state/guardians.json") for _, path in fake.calls)
