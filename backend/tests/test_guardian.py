
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
    assert api.get(url.replace("exp=", "exp=1")).status_code == 403
    path = url.split("?")[0]
    assert api.get(path).status_code == 403
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
    store = IncidentStore(clock=lambda: now[0], ttl_after_end_s=60, stale_after_s=10**9)
    old, _ = store.start("sos-old00001", "A", [], share_token="shared-token-xyz")
    store.end(old.id)
    now[0] += 30
    new, _ = store.start("sos-new00001", "A", [], share_token="shared-token-xyz")
    now[0] += 100
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


NOW = 1_800_000_000.0


def _record(code, lat, lon, age=60, chat=1):
    return {"code": code, "chat_id": chat, "lat": lat, "lon": lon, "loc_at": NOW - age}


def test_nearest_contact_is_told_and_others_hear_the_distance():
    from app.notify import nearest_notes

    pin = (28.6139, 77.2090)
    notes = nearest_notes(
        [_record("a", 28.6200, 77.2100), _record("b", 28.7041, 77.1025)], pin, now=NOW
    )
    assert "nearest contact" in notes["a"] and "km" in notes["a"] or " m " in notes["a"]
    assert "The nearest contact is about" in notes["b"] and "you are about" in notes["b"]


def test_nearest_notes_ignore_stale_missing_or_unlinked_locations():
    from app.notify import nearest_notes

    pin = (28.6139, 77.2090)
    assert nearest_notes([_record("a", 28.62, 77.21, age=13 * 3600)], pin, now=NOW) == {}
    assert nearest_notes([{"code": "a", "chat_id": 1}], pin, now=NOW) == {}
    assert nearest_notes([_record("a", 28.62, 77.21, chat=None)], pin, now=NOW) == {}
    assert nearest_notes([_record("a", 28.62, 77.21)], None, now=NOW) == {}


def test_nearest_notes_in_hindi():
    from app.notify import nearest_notes

    notes = nearest_notes([_record("a", 28.6140, 77.2091)], (28.6139, 77.2090), lang="hi", now=NOW)
    assert "सबसे नज़दीकी" in notes["a"]


def test_contact_locations_come_from_telegram_updates(tmp_path):
    from app.contacts import ContactStore, apply_locations

    store = ContactStore(path=str(tmp_path / "c.json"))
    record = store.invite("Asha")
    store.link(record["code"], 42)
    update = {"update_id": 1, "message": {"chat": {"id": 42}, "location": {"latitude": 28.6, "longitude": 77.2}}}
    assert apply_locations({"result": [update]}, store, NOW) == [(42, False)]
    saved = store.get(record["code"])
    assert (saved["lat"], saved["lon"], saved["loc_at"]) == (28.6, 77.2, NOW)
    live = {"update_id": 2, "edited_message": {"chat": {"id": 42}, "location": {"latitude": 28.61, "longitude": 77.21}}}
    assert apply_locations({"result": [live]}, store, NOW + 5) == [(42, True)]
    stranger = {"update_id": 3, "message": {"chat": {"id": 99}, "location": {"latitude": 1.0, "longitude": 1.0}}}
    assert apply_locations({"result": [stranger]}, store, NOW) == []
    bad = {"update_id": 4, "message": {"chat": {"id": 42}, "location": {"latitude": 999, "longitude": 1.0}}}
    assert apply_locations({"result": [bad]}, store, NOW) == []


def test_sos_alert_includes_the_nearest_note(api):
    code_a = api.post("/contacts/invite", json={"name": "Asha"}).json()["code"]
    code_b = api.post("/contacts/invite", json={"name": "Bela"}).json()["code"]
    store = main.get_contact_store()
    store.link(code_a, 1)
    store.link(code_b, 2)
    store.set_location(1, 28.6200, 77.2100, time.time())
    store.set_location(2, 28.7041, 77.1025, time.time())
    res = start(api, contact_codes=[code_a, code_b])
    assert [d["status"] for d in res["delivery"]] == ["dry-run", "dry-run"]
    lines = [__import__("json").loads(l) for l in open(main.SETTINGS.notify_log_path)]
    texts = {l["chat_id"]: l["text"] for l in lines if l["kind"] == "text"}
    assert "You appear to be the nearest contact" in texts[1]
    assert "The nearest contact is about" in texts[2]


SHOT = b"\xff\xd8\xff\xe0" + b"j" * 64 + b"\xff\xd9"


def _item(type_, text, rating="possible", t=None, **extra):
    return {"type": type_, "text": text, "rating": rating, "t": t or time.time(), **extra}


def _post_items(api, incident_id, items):
    return api.post(f"/incident/{incident_id}/items", json={"items": items})


def test_names_are_rated_possible_or_strongly_possible():
    from app.muse import clean_names

    names = clean_names([
        {"name": "Rahul", "confidence": 0.9},
        {"name": "meera", "confidence": 0.4},
        {"name": "rahul", "confidence": 0.5},
        {"name": "B4d!", "confidence": 0.9},
        {"name": "Priya", "confidence": "high"},
        "nonsense",
    ])
    assert names == [
        {"name": "Rahul", "rating": "strongly possible"},
        {"name": "Meera", "rating": "possible"},
    ]
    assert clean_names(None) == []


def test_speech_verdict_carries_names_through_the_endpoint(api, monkeypatch):
    import json as _json

    verdict = {
        "severity": "low", "categories": [], "directed_at_wearer": False, "reason": "Casual talk.",
        "names": [{"name": "Asha", "confidence": 0.8}],
    }
    class R:
        status_code = 200
        text = _json.dumps({"choices": [{"message": {"content": _json.dumps(verdict)}}]})
    monkeypatch.setattr("app.muse.httpx.post", lambda *a, **k: R())
    monkeypatch.setattr(main._muse_client, "api_key", "k" * 8)
    out = api.post("/verify-speech", json={"snippet": "hey Asha wait"}).json()
    assert out["names"] == [{"name": "Asha", "rating": "strongly possible"}]


def test_items_merge_and_the_guardian_sees_them_with_screenshots(api):
    code = new_code(api)
    res = start(api, guardian_code=code)
    iid = res["id"]
    seed(api, "sos-abcdef12", {"shot-00001.jpg": SHOT})
    now = time.time()
    out = _post_items(api, iid, [
        _item("plate", "mh 12 ab 1234", t=now - 30),
        _item("name", "Rahul", "strongly possible", t=now - 20, source="Rahul, wait"),
        _item("gesture", "Obscene hand gesture", "strongly possible", t=now - 10, shot="shot-00001.jpg"),
        _item("name", "<script>", t=now),
    ])
    assert out.status_code == 200 and out.json()["stored"] == 3
    again = _post_items(api, iid, [_item("plate", "MH12 AB1234", "strongly possible", t=now - 5)])
    assert again.json()["total"] == 3
    detail = api.get(f"/guardian/api/incidents/{iid}", headers={"X-Guardian-Code": code}).json()
    kinds = [i["type"] for i in detail["items"]]
    assert kinds == ["plate", "name", "gesture"]
    gesture = detail["items"][2]
    assert gesture["shot_url"].startswith("/guardian/media/")
    served = api.get(gesture["shot_url"])
    assert served.status_code == 200 and served.content == SHOT
    assert served.headers["content-type"] == "image/jpeg"
    plate = detail["items"][0]
    assert plate["text"] == "MH 12 AB 1234" and plate["count"] == 2
    assert plate["rating"] == "strongly possible", "a second sighting upgrades the rating"


def test_item_validation_and_unknown_incident(api):
    assert _post_items(api, "nope", [_item("plate", "MH12AB1234")]).status_code == 404
    res = start(api, guardian_code=new_code(api))
    bad = api.post(f"/incident/{res['id']}/items", json={"items": [{"type": "email", "text": "x", "rating": "possible", "t": 1}]})
    assert bad.status_code == 422
    assert api.post(f"/incident/{res['id']}/items", json={"items": [_item("gesture", "x", shot="../etc.jpg")]}).status_code == 422


def test_guardian_can_ask_muse_about_a_screenshot(api, monkeypatch):
    code = new_code(api)
    iid = start(api, guardian_code=code)["id"]
    seed(api, "sos-abcdef12", {"shot-00001.jpg": SHOT})
    _post_items(api, iid, [_item("gesture", "Obscene hand gesture", shot="shot-00001.jpg")])
    seen = {}

    def fake_ask(image_b64, question):
        seen["q"] = question
        return "A raised hand gesture directed at the camera.", 1.2

    monkeypatch.setattr(main._muse_client, "ask_about_image", fake_ask)
    monkeypatch.setattr(main, "_ask_limiters", {})
    headers = {"X-Guardian-Code": code}
    ok = api.post(f"/guardian/api/incidents/{iid}/ask", headers=headers,
                  json={"shot": "shot-00001.jpg", "question": "What is happening here?"})
    assert ok.status_code == 200 and "raised hand" in ok.json()["answer"]
    assert seen["q"] == "What is happening here?"
    other = api.post(f"/guardian/api/incidents/{iid}/ask", headers=headers,
                     json={"shot": "shot-00002.jpg", "question": "What is happening here?"})
    assert other.status_code == 404
    wrong = api.post(f"/guardian/api/incidents/{iid}/ask", headers={"X-Guardian-Code": "AAAA-AAAA-AAAA"},
                     json={"shot": "shot-00001.jpg", "question": "What is happening here?"})
    assert wrong.status_code == 403


def test_ask_is_rate_limited_and_survives_muse_outages(api, monkeypatch):
    from app.muse import MuseError

    code = new_code(api)
    iid = start(api, guardian_code=code)["id"]
    seed(api, "sos-abcdef12", {"shot-00001.jpg": SHOT})
    _post_items(api, iid, [_item("gesture", "Obscene hand gesture", shot="shot-00001.jpg")])
    monkeypatch.setattr(main, "_ask_limiters", {})
    headers = {"X-Guardian-Code": code}
    body = {"shot": "shot-00001.jpg", "question": "What is happening here?"}

    def down(image_b64, question):
        raise MuseError("boom")

    monkeypatch.setattr(main._muse_client, "ask_about_image", down)
    assert api.post(f"/guardian/api/incidents/{iid}/ask", headers=headers, json=body).status_code == 503
    monkeypatch.setattr(main._muse_client, "ask_about_image", lambda i, q: ("Unclear.", 0.5))
    codes = [api.post(f"/guardian/api/incidents/{iid}/ask", headers=headers, json=body).status_code for _ in range(8)]
    assert 429 in codes


def test_ask_prompt_forbids_appearance_and_accusations():
    from app.muse import ASK_SYSTEM_PROMPT, parse_answer

    assert "NEVER describe or guess appearance" in ASK_SYSTEM_PROMPT
    assert parse_answer('{"choices":[{"message":{"content":" A hand is raised. "}}]}') == "A hand is raised."
    import pytest as _pytest
    from app.muse import MuseError
    with _pytest.raises(MuseError):
        parse_answer('{"choices":[{"message":{"content":"  "}}]}')


def test_concurrent_starts_share_one_incident():
    import threading
    from app.incidents import IncidentStore

    store = IncidentStore()
    ids = []
    gate = threading.Barrier(8)

    def go():
        gate.wait()
        incident, _ = store.start("sess", "A", [], share_token="tok")
        ids.append(incident.id)

    threads = [threading.Thread(target=go) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(set(ids)) == 1


def test_silent_incident_is_marked_ended_and_revives_on_activity():
    from app.incidents import IncidentStore

    now = [1000.0]
    store = IncidentStore(clock=lambda: now[0], stale_after_s=90)
    incident, _ = store.start("sess", "A", [], share_token="tok", mode="live", guardian_code="G")
    now[0] += 60
    assert store.get(incident.id).status == "active"
    now[0] += 120
    assert store.get(incident.id).status == "ended"
    assert store.for_guardian("G")[0].status == "ended"
    store.add_point(incident.id, 1.0, 2.0)
    assert store.get(incident.id).status == "active"


def test_new_start_on_same_link_ends_the_old_one():
    from app.incidents import IncidentStore

    store = IncidentStore()
    old, _ = store.start("one", "A", [], share_token="tok", mode="live")
    new, _ = store.start("two", "A", [], share_token="tok")
    assert old.status == "ended" and new.status == "active"


def test_site_root_opens_the_guardian_page(api):
    res = api.get("/")
    assert res.status_code == 200 and "Safeguard" in res.text
