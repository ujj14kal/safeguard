"""Phase 6 endpoints: contacts, incidents, live viewer, app-token auth."""

import json

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.contacts import ContactStore
from app.incidents import IncidentStore
from app.ratelimit import RateLimiter

fake_app_token = "-".join(["not", "a", "real", "app", "token"])
fake_bot_token = "-".join(["not", "a", "real", "bot", "token"])

JSON = {"Content-Type": "application/json"}


@pytest.fixture
def stores(tmp_path, monkeypatch):
    monkeypatch.setattr(
        main,
        "_contact_store",
        ContactStore(
            path=str(tmp_path / "contacts.json"),
        ),
    )
    monkeypatch.setattr(
        main,
        "_incidents",
        IncidentStore(),
    )
    monkeypatch.setattr(
        main,
        "_incident_limiter",
        RateLimiter(1000),
    )
    monkeypatch.setattr(
        main,
        "SETTINGS",
        Settings(
            contacts_path=str(tmp_path / "contacts.json"),
            notify_log_path=str(tmp_path / "notify.jsonl"),
            evidence_dir=str(tmp_path / "evidence"),
            app_token="",
            notify_mode="dry-run",
            public_base_url="https://demo.test",
        ),
    )
    return TestClient(main.app)


def auth_headers():
    return {"X-Safeguard-Token": fake_app_token}


def invite(client, name="Meera"):
    response = client.post("/contacts/invite", json={"name": name})
    assert response.status_code == 200, response.text
    return response.json()


def link_code(code, chat_id=777):
    assert main.get_contact_store().link(code, chat_id) is not None


def start_body(**overrides):
    body = {
        "session": "sos-abcdef12",
        "wearer_name": "Aarav",
        "contact_codes": [],
    }
    body.update(overrides)
    return body


def notify_lines(tmp_path):
    path = tmp_path / "notify.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines()]


# --- contacts ---------------------------------------------------------------


def test_invite_returns_code_and_link(stores):
    body = invite(stores)
    assert body["name"] == "Meera"
    assert len(body["code"]) >= 6
    assert body["link"] == f"https://t.me/safeguard_demo_bot?start={body['code']}"
    status = stores.get(f"/contacts/{body['code']}").json()
    assert status == {"name": "Meera", "linked": False}


def test_invite_limit_and_status(stores):
    codes = [invite(stores, name=f"Friend {i}")["code"] for i in range(5)]
    assert stores.post("/contacts/invite", json={"name": "Extra"}).status_code == 409
    assert stores.post("/contacts/invite", json={"name": "   "}).status_code == 422
    assert stores.get("/contacts/unknown").status_code == 404
    link_code(codes[0])
    assert stores.get(f"/contacts/{codes[0]}").json()["linked"] is True


# --- incidents --------------------------------------------------------------


def test_start_alerts_linked_and_skips_waiting(stores, tmp_path):
    linked = invite(stores, name="Meera")
    waiting = invite(stores, name="Arjun")
    link_code(linked["code"])
    response = stores.post(
        "/incident/start",
        json=start_body(contact_codes=[linked["code"], waiting["code"], "ghost"]),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["fresh"] is True
    assert body["id"].startswith("inc-")
    assert len(body["share_token"]) >= 32
    assert body["live_url"].startswith("https://demo.test/live/")
    by_code = {item["code"]: item for item in body["delivery"]}
    assert by_code[linked["code"]]["status"] == "dry-run"
    assert by_code[waiting["code"]]["status"] == "skipped"
    assert by_code["ghost"]["status"] == "skipped"
    lines = notify_lines(tmp_path)
    assert len(lines) == 1  # the linked contact only
    assert "Aarav" in lines[0]["text"] and body["live_url"] in lines[0]["text"]


def test_repeat_start_sends_no_second_burst(stores, tmp_path):
    code = invite(stores)["code"]
    link_code(code)
    first = stores.post("/incident/start", json=start_body(contact_codes=[code])).json()
    assert first["fresh"] is True
    before = notify_lines(tmp_path)
    second = stores.post("/incident/start", json=start_body(contact_codes=[code])).json()
    assert second["fresh"] is False
    assert second["id"] == first["id"]
    assert second["delivery"] == []
    assert notify_lines(tmp_path) == before


def test_start_validates_session_and_fix(stores):
    assert stores.post("/incident/start", json=start_body(session="short")).status_code == 422
    assert stores.post("/incident/start", json=start_body(session="../x")).status_code == 422
    assert stores.post("/incident/start", json=start_body(lat=12.0)).status_code == 422
    assert (
        stores.post("/incident/start", json=start_body(lat=91.0, lon=0.0)).status_code
        == 422
    )


def test_start_with_fix_sends_pin(stores, tmp_path):
    code = invite(stores)["code"]
    link_code(code)
    body = stores.post(
        "/incident/start", json=start_body(contact_codes=[code], lat=12.9716, lon=77.5946)
    ).json()
    assert body["fresh"] is True
    kinds = [line["kind"] for line in notify_lines(tmp_path)]
    assert kinds == ["text", "location"]
    assert "maps.google.com" in notify_lines(tmp_path)[0]["text"]


def test_test_alert_is_labelled(stores, tmp_path):
    code = invite(stores)["code"]
    link_code(code)
    stores.post("/incident/start", json=start_body(contact_codes=[code], test=True))
    (line,) = notify_lines(tmp_path)
    assert line["text"].startswith("[TEST]")


def test_location_lifecycle(stores):
    incident = stores.post("/incident/start", json=start_body()).json()
    point = {"lat": 12.97, "lon": 77.59, "accuracy": 8, "ts": 1700000000}
    assert stores.post(f"/incident/{incident['id']}/location", json=point).json() == {
        "stored": 1
    }
    assert stores.post(f"/incident/{incident['id']}/location", json=point).json() == {
        "stored": 2
    }
    assert stores.post("/incident/inc-missing/location", json=point).status_code == 404
    bad = dict(point, lat=91.0)
    assert stores.post(f"/incident/{incident['id']}/location", json=bad).status_code == 422
    bad = dict(point, accuracy=-1.0)
    assert stores.post(f"/incident/{incident['id']}/location", json=bad).status_code == 422


def test_end_sends_once(stores, tmp_path):
    code = invite(stores)["code"]
    link_code(code)
    incident = stores.post(
        "/incident/start", json=start_body(contact_codes=[code])
    ).json()
    first = stores.post(f"/incident/{incident['id']}/end").json()
    assert first == {
        "ended": True,
        "already_ended": False,
        "delivery": [
            {
                "code": code,
                "name": "Meera",
                "status": "dry-run",
                "detail": "",
            }
        ],
    }
    texts = [line["text"] for line in notify_lines(tmp_path)]
    assert any("has ended" in text for text in texts)
    before = notify_lines(tmp_path)
    again = stores.post(f"/incident/{incident['id']}/end").json()
    assert again["already_ended"] is True
    assert notify_lines(tmp_path) == before
    assert stores.post("/incident/inc-missing/end").status_code == 404


def test_cab_shares_demo_details(stores, tmp_path):
    code = invite(stores)["code"]
    link_code(code)
    incident = stores.post(
        "/incident/start", json=start_body(contact_codes=[code])
    ).json()
    body = {"driver": "Demo Driver", "plate": "DL-1D-EMO", "eta_min": 4}
    response = stores.post(f"/incident/{incident['id']}/cab", json=body)
    assert response.status_code == 200, response.text
    assert response.json()["sent"] == 1
    assert "DEMO" in notify_lines(tmp_path)[-1]["text"]
    assert stores.post("/incident/inc-missing/cab", json=body).status_code == 404
    assert (
        stores.post(f"/incident/{incident['id']}/cab", json=dict(body, eta_min=999)).status_code
        == 422
    )
    stores.post(f"/incident/{incident['id']}/end")
    assert stores.post(f"/incident/{incident['id']}/cab", json=body).status_code == 409


def test_start_rate_limited(stores, monkeypatch):
    monkeypatch.setattr(main, "_incident_limiter", RateLimiter(1))
    assert stores.post("/incident/start", json=start_body()).status_code == 200
    limited = stores.post("/incident/start", json=start_body(session="sos-zzzzzzzz"))
    assert limited.status_code == 429


def test_real_mode_sends_through_telegram(stores, tmp_path, monkeypatch):
    calls = []

    class FakeResponse:
        status_code = 200
        text = '{"ok": true}'

    def fake_post(url, json=None, timeout=None):  # noqa: A002
        calls.append({"url": url, "json": json})
        return FakeResponse()

    monkeypatch.setattr("app.notify.httpx.post", fake_post)
    monkeypatch.setattr(
        main,
        "SETTINGS",
        Settings(
            contacts_path=str(tmp_path / "contacts.json"),
            notify_log_path=str(tmp_path / "notify.jsonl"),
            evidence_dir=str(tmp_path / "evidence"),
            app_token="",
            notify_mode="telegram",
            telegram_bot_token=fake_bot_token,
            public_base_url="https://demo.test",
        ),
    )
    code = invite(stores)["code"]
    link_code(code)
    body = stores.post(
        "/incident/start",
        json=start_body(contact_codes=[code], dry_run=False, lat=1.0, lon=2.0),
    ).json()
    assert body["delivery"][0]["status"] == "sent"
    assert len(calls) == 2  # text + pin
    assert calls[0]["url"].endswith("/sendMessage")
    assert fake_bot_token in calls[0]["url"]
    assert calls[1]["url"].endswith("/sendLocation")
    assert notify_lines(tmp_path) == []


def test_real_mode_without_config_falls_back_to_dry_run(stores):
    code = invite(stores)["code"]
    link_code(code)
    body = stores.post(
        "/incident/start", json=start_body(contact_codes=[code], dry_run=False)
    ).json()
    assert body["delivery"][0]["status"] == "dry-run"


# --- live viewer ------------------------------------------------------------


def seed_session(tmp_path, session, files):
    folder = tmp_path / "evidence" / session
    folder.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (folder / name).write_bytes(content)


def test_viewer_page_and_state(stores, tmp_path):
    incident = stores.post("/incident/start", json=start_body()).json()
    stores.post(
        f"/incident/{incident['id']}/location",
        json={"lat": 12.97, "lon": 77.59, "accuracy": 8, "ts": 1700000001},
    )
    seed_session(
        tmp_path, "sos-abcdef12", {"video-00000.mp4": b"v0", "audio-00000.m4a": b"a0"}
    )
    page = stores.get(f"/live/{incident['share_token']}")
    assert page.status_code == 200
    assert "leaflet@1.9.4" in page.text
    assert "10-15 s behind" in page.text
    lowered = page.text.lower()
    assert "real-time" not in lowered and "realtime" not in lowered
    state = stores.get(f"/live/{incident['share_token']}/state").json()
    assert state["status"] == "active"
    assert state["wearer_name"] == "Aarav"
    assert state["latest"] == {"lat": 12.97, "lon": 77.59, "accuracy": 8, "ts": 1700000001}
    assert state["trail"] == [{"lat": 12.97, "lon": 77.59}]
    assert [(s["kind"], s["seq"]) for s in state["segments"]] == [
        ("audio", 0),
        ("video", 0),
    ]
    assert state["segments"][0]["url"] == "segments/audio-00000.m4a"
    media = stores.get(f"/live/{incident['share_token']}/segments/video-00000.mp4")
    assert media.status_code == 200 and media.content == b"v0"


def test_viewer_token_is_scoped(stores, tmp_path):
    first = stores.post("/incident/start", json=start_body()).json()
    second = stores.post("/incident/start", json=start_body(session="sos-zzzzzzzz")).json()
    seed_session(tmp_path, "sos-zzzzzzzz", {"video-00000.mp4": b"other"})
    # Token A cannot read session B: the file is simply not there for A.
    assert (
        stores.get(f"/live/{first['share_token']}/segments/video-00000.mp4").status_code
        == 404
    )
    assert (
        stores.get(f"/live/{second['share_token']}/segments/video-00000.mp4").content
        == b"other"
    )
    assert stores.get("/live/wrongtoken").status_code == 404
    assert stores.get("/live/wrongtoken/state").status_code == 404
    assert stores.get("/live/wrongtoken/segments/video-00000.mp4").status_code == 404


def test_viewer_rejects_path_tricks(stores):
    incident = stores.post("/incident/start", json=start_body()).json()
    token = incident["share_token"]
    # (A bare ".." never reaches the server: HTTP clients normalize it to
    # the page URL. Everything below does reach the handler and must 404.)
    for name in [
        "video-00000.mp3",
        "audio-00000.mp4",
        "VIDEO-00000.MP4",
        "video-0.mp4",
        "video-00000.mp4x",
    ]:
        assert stores.get(f"/live/{token}/segments/{name}").status_code == 404
    assert stores.get(f"/live/{token}/segments/..%2F..%2Fcontacts.json").status_code in (
        404,
        405,
    )


# --- app token auth ---------------------------------------------------------


@pytest.fixture
def locked(tmp_path, monkeypatch):
    monkeypatch.setattr(
        main,
        "_contact_store",
        ContactStore(
            path=str(tmp_path / "contacts.json"),
        ),
    )
    monkeypatch.setattr(
        main,
        "_incidents",
        IncidentStore(),
    )
    monkeypatch.setattr(
        main,
        "_incident_limiter",
        RateLimiter(1000),
    )
    monkeypatch.setattr(
        main,
        "SETTINGS",
        Settings(
            contacts_path=str(tmp_path / "contacts.json"),
            notify_log_path=str(tmp_path / "notify.jsonl"),
            evidence_dir=str(tmp_path / "evidence"),
            app_token=fake_app_token,
            notify_mode="dry-run",
            public_base_url="https://demo.test",
        ),
    )
    return TestClient(main.app)


def test_app_token_ok_unit(monkeypatch):
    monkeypatch.setattr(main, "SETTINGS", Settings(app_token=""))
    assert main.app_token_ok(None) is True
    assert main.app_token_ok("anything") is True
    monkeypatch.setattr(main, "SETTINGS", Settings(app_token=fake_app_token))
    assert main.app_token_ok(None) is False
    assert main.app_token_ok("wrong") is False
    assert main.app_token_ok(fake_app_token) is True


def test_protected_endpoints_need_the_token(locked):
    assert locked.post("/contacts/invite", json={"name": "Me"}).status_code == 401
    assert locked.get("/contacts/abc").status_code == 401
    assert locked.post("/incident/start", json=start_body()).status_code == 401
    assert (
        locked.post("/incident/inc-x/location", json={"lat": 1, "lon": 2}).status_code
        == 401
    )
    assert locked.post("/incident/inc-x/end").status_code == 401
    assert (
        locked.post(
            "/incident/inc-x/cab",
            json={"driver": "d", "plate": "p", "eta_min": 1},
        ).status_code
        == 401
    )
    assert locked.post("/applog", json={"events": []}).status_code == 401
    assert locked.get("/applog").status_code == 401
    assert (
        locked.post(
            "/evidence",
            params={"session": "sos-abcdef12", "kind": "video", "seq": 0, "ext": "mp4"},
            content=b"abc",
        ).status_code
        == 401
    )
    assert locked.get("/evidence/sos-abcdef12").status_code == 401


def test_verify_endpoints_need_the_token(locked):
    frames = {"frames_b64": ["aGk="], "on_device_features": {}, "boxes_xyxy": []}
    assert locked.post("/verify", json=frames).status_code == 401
    speech = {"snippet": "hello", "on_device": {}}
    assert locked.post("/verify-speech", json=speech).status_code == 401
    # With the header, auth passes (503 = Muse unreachable in tests, not 401).
    assert (
        locked.post("/verify", json=frames, headers=auth_headers()).status_code == 503
    )


def test_token_accepted_and_viewer_exempt(locked):
    assert (
        locked.post("/contacts/invite", json={"name": "Me"}, headers=auth_headers()).status_code
        == 200
    )
    incident = locked.post(
        "/incident/start", json=start_body(), headers=auth_headers()
    ).json()
    assert locked.get(f"/live/{incident['share_token']}").status_code == 200
    assert locked.get(f"/live/{incident['share_token']}/state").status_code == 200
    assert locked.get("/health").status_code == 200


def test_asr_rejects_before_accepting_without_the_token(locked):
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect):
        with locked.websocket_connect("/asr"):
            pass
