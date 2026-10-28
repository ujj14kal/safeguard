"""Standing live link, guardian codes and the read-only guardian API."""

import time

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.contacts import ContactStore
from app.incidents import IncidentStore
from app.links import ChannelStore, GuardianStore, make_guardian_code, normalize_code
from app.ratelimit import RateLimiter

DEVICE = "device-1234-abcd"


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "_contact_store", ContactStore(path=str(tmp_path / "contacts.json")))
    monkeypatch.setattr(main, "_incidents", IncidentStore(path=str(tmp_path / "inc.json")))
    monkeypatch.setattr(main, "_guardians", GuardianStore(str(tmp_path / "g.json")))
    monkeypatch.setattr(main, "_channels", ChannelStore(str(tmp_path / "c.json")))
    monkeypatch.setattr(main, "_incident_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "_guardian_register_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "_guardian_fail_limiters", {})
    monkeypatch.setattr(main, "_guardian_ok_limiter", RateLimiter(1000))
    monkeypatch.setattr(
        main, "SETTINGS",
        Settings(
            contacts_path=str(tmp_path / "contacts.json"),
            notify_log_path=str(tmp_path / "notify.jsonl"),
            evidence_dir=str(tmp_path / "evidence"),
            app_token="", notify_mode="dry-run", public_base_url="https://demo.test",
        ),
    )
    client = TestClient(main.app)
    client.evidence = tmp_path / "evidence"
    return client


def start(api, **over):
    body = {"session": "sos-abcdef12", "wearer_name": "Asha", "dry_run": True,
            "lat": 28.6, "lon": 77.2}
    body.update(over)
    res = api.post("/incident/start", json=body)
    assert res.status_code == 200, res.text
    return res.json()


def seed(api, session, files):
    folder = api.evidence / session
    folder.mkdir(parents=True)
    for name, data in files.items():
        (folder / name).write_bytes(data)


def new_code(api):
    return api.post("/guardian/register").json()["code"]


# --- codes ---------------------------------------------------------------

def test_code_format_and_normalising():
    code = make_guardian_code()
    assert len(code) == 14 and code.count("-") == 2
    assert normalize_code(code.lower().replace("-", " ")) == code
    for bad in ["", "ABCD", "ABCD-EFGH-IJK0", "OOOO-OOOO-OOOO"]:
        assert normalize_code(bad) == ""


def test_register_check_and_revoke(api):
    code = new_code(api)
    assert api.get(f"/guardian/check/{code}").json() == {"valid": True}
    assert api.get("/guardian/check/AAAA-BBBB-CCCC").json() == {"valid": False}
    assert main.get_guardians().revoke(code) is True
    assert api.get(f"/guardian/check/{code}").json() == {"valid": False}


def test_registering_is_rate_limited(api, monkeypatch):
    monkeypatch.setattr(main, "_guardian_register_limiter", RateLimiter(2, 3600.0))
    assert api.post("/guardian/register").status_code == 200
    assert api.post("/guardian/register").status_code == 200
    assert api.post("/guardian/register").status_code == 429


def test_check_needs_the_app_token(api, monkeypatch):
    monkeypatch.setattr(main, "SETTINGS", Settings(app_token="t" * 12, public_base_url="https://demo.test"))
    assert api.get("/guardian/check/AAAA-BBBB-CCCC").status_code == 401


# --- guardian view -------------------------------------------------------

def test_guardian_sees_only_incidents_with_their_code(api):
    mine, other = new_code(api), new_code(api)
    start(api, session="sos-mine0001", guardian_code=mine)
    start(api, session="sos-theirs01", guardian_code=other)
    start(api, session="sos-nobody01")
    listing = api.get("/guardian/api/incidents", headers={"X-Guardian-Code": mine}).json()
    assert [i["status"] for i in listing["incidents"]] == ["active"]
    assert len(listing["incidents"]) == 1


def test_wrong_or_missing_code_is_403_and_brute_force_is_throttled(api):
    assert api.get("/guardian/api/incidents").status_code == 403
    bad = {"X-Guardian-Code": "AAAA-BBBB-CCCC"}
    codes = [api.get("/guardian/api/incidents", headers=bad).status_code for _ in range(12)]
    assert codes[0] == 403 and 429 in codes


def test_detail_has_trail_and_signed_media_that_plays(api):
    code = new_code(api)
    inc = start(api, guardian_code=code)
    seed(api, "sos-abcdef12", {"video-00000.mp4": b"v0", "audio-00000.m4a": b"a0"})
    detail = api.get(f"/guardian/api/incidents/{inc['id']}", headers={"X-Guardian-Code": code}).json()
    assert detail["videos"] == 1 and detail["audios"] == 1
    assert detail["trail"][0]["lat"] == 28.6
    media = api.get(detail["segments"][1]["url"])
    assert media.status_code == 200
    assert media.content in (b"v0", b"a0")


def test_media_links_are_signed_and_scoped(api):
    code = new_code(api)
    inc = start(api, guardian_code=code)
    seed(api, "sos-abcdef12", {"video-00000.mp4": b"v0"})
    url = api.get(f"/guardian/api/incidents/{inc['id']}", headers={"X-Guardian-Code": code}).json()["segments"][0]["url"]
    assert api.get(url).status_code == 200
    assert api.get(url.split("sig=")[0] + "sig=" + "0" * 40).status_code == 403
    assert api.get(url.replace("exp=", "exp=1")).status_code == 403  # tampered expiry
    path = url.split("?")[0]
    assert api.get(path).status_code == 403                           # no signature at all
    expired = f"{path}?exp={int(time.time()) - 5}&sig={main._media_sig(inc['id'], 'video-00000.mp4', int(time.time()) - 5)}"
    assert api.get(expired).status_code == 403


def test_other_guardians_cannot_open_this_incident(api):
    mine, other = new_code(api), new_code(api)
    inc = start(api, guardian_code=mine)
    res = api.get(f"/guardian/api/incidents/{inc['id']}", headers={"X-Guardian-Code": other})
    assert res.status_code == 404


def test_guardian_api_is_read_only(api):
    code = new_code(api)
    inc = start(api, guardian_code=code)
    h = {"X-Guardian-Code": code}
    for method in ("post", "put", "delete", "patch"):
        res = getattr(api, method)(f"/guardian/api/incidents/{inc['id']}", headers=h)
        assert res.status_code in (404, 405)


def test_incidents_with_a_guardian_outlive_the_normal_ttl(tmp_path):
    now = [1000.0]
    store = IncidentStore(clock=lambda: now[0], ttl_after_end_s=60, guardian_ttl_after_end_s=3600)
    plain, _ = store.start("sos-plain001", "A", [])
    watched, _ = store.start("sos-watch001", "A", [], guardian_code="AAAA-BBBB-CCCC")
    store.end(plain.id)
    store.end(watched.id)
    now[0] += 600
    assert store.expired(plain) and not store.expired(watched)


def test_guardian_page_is_public_html(api):
    page = api.get("/guardian")
    assert page.status_code == 200 and "Safeguard guardian" in page.text
    assert "X-Guardian-Code" in page.text


# --- standing live link --------------------------------------------------

def test_channel_is_stable_per_device_and_revocable(api):
    first = api.post("/live/channel", json={"device_id": DEVICE, "wearer_name": "Asha"}).json()
    again = api.post("/live/channel", json={"device_id": DEVICE, "wearer_name": "Asha"}).json()
    assert first["token"] == again["token"] and first["live_url"].startswith("https://demo.test/live/")
    assert api.post("/live/channel", json={"device_id": "x"}).status_code == 422
    assert api.delete(f"/live/channel/{DEVICE}").json() == {"revoked": True}
    assert api.get(f"/live/{first['token']}/state").status_code == 404


def test_idle_link_says_not_live_then_goes_live_on_the_same_url(api):
    channel = api.post("/live/channel", json={"device_id": DEVICE, "wearer_name": "Asha"}).json()
    token = channel["token"]
    assert api.get(f"/live/{token}").status_code == 200
    idle = api.get(f"/live/{token}/state").json()
    assert idle["status"] == "idle" and idle["wearer_name"] == "Asha"
    inc = start(api, mode="live", channel_token=token)
    assert inc["live_url"] == channel["live_url"]
    assert api.get(f"/live/{token}/state").json()["status"] == "active"
    assert api.get(f"/live/{token}/state").json()["mode"] == "live"


def test_live_mode_messages_nobody_and_sos_on_the_channel_reuses_the_url(api):
    channel = api.post("/live/channel", json={"device_id": DEVICE, "wearer_name": "Asha"}).json()
    live = start(api, session="sos-live0001", mode="live", channel_token=channel["token"])
    assert live["delivery"] == [] and live["preview_text"] == ""
    sos = start(api, session="sos-sos00001", channel_token=channel["token"])
    assert sos["live_url"] == channel["live_url"]
    assert "Live location and video" in sos["preview_text"]


def test_unknown_channel_token_falls_back_to_a_fresh_link(api):
    inc = start(api, channel_token="no-such-token")
    assert "/live/" in inc["live_url"] and not inc["live_url"].endswith("no-such-token")


def test_expiring_one_incident_keeps_the_channel_token_for_the_newer_one():
    now = [1000.0]
    store = IncidentStore(clock=lambda: now[0], ttl_after_end_s=60)
    old, _ = store.start("sos-old00001", "A", [], share_token="shared-token-xyz")
    store.end(old.id)
    now[0] += 30
    new, _ = store.start("sos-new00001", "A", [], share_token="shared-token-xyz")
    now[0] += 100  # old one expired, new one active
    store.save()
    assert store.get_by_token("shared-token-xyz") is new


def test_guardian_links_telegram_and_gets_the_sos_alert(api, monkeypatch):
    from app.contacts import link_from_updates

    import dataclasses

    monkeypatch.setattr(
        main, "SETTINGS",
        dataclasses.replace(main.SETTINGS, notify_mode="telegram", telegram_bot="TestBot"),
    )
    code = new_code(api)
    headers = {"X-Guardian-Code": code}
    info = api.get("/guardian/api/alerts", headers=headers).json()
    assert info["available"] and not info["linked"]
    assert info["link"] == f"https://t.me/TestBot?start=g_{code}"

    # The guardian presses Start in Telegram.
    update = {"update_id": 5, "message": {"text": f"/start g_{code}", "chat": {"id": 777}}}
    linked, _ = link_from_updates({"result": [update]}, main.get_contact_store(), main.get_guardians())
    assert linked and api.get("/guardian/api/alerts", headers=headers).json()["linked"]

    res = start(api, guardian_code=code)
    guardian = [d for d in res["delivery"] if d["code"] == "guardian"]
    assert guardian and guardian[0]["status"] == "dry-run"


def test_unlinked_guardian_is_skipped_and_tests_do_not_alert(api):
    code = new_code(api)
    res = start(api, guardian_code=code)
    assert [d["status"] for d in res["delivery"] if d["code"] == "guardian"] == ["skipped"]
    res = start(api, guardian_code=code, session="sos-test0001", test=True)
    assert not [d for d in res["delivery"] if d["code"] == "guardian"]


def test_guardian_alert_route_needs_a_valid_code(api):
    assert api.get("/guardian/api/alerts", headers={"X-Guardian-Code": "AAAA-AAAA-AAAA"}).status_code == 403


def test_a_start_with_a_wrong_prefix_never_links_a_guardian(api):
    from app.contacts import link_from_updates

    code = new_code(api)
    update = {"update_id": 1, "message": {"text": f"/start {code}", "chat": {"id": 9}}}
    link_from_updates({"result": [update]}, main.get_contact_store(), main.get_guardians())
    assert main.get_guardians().chat_id(code) is None
