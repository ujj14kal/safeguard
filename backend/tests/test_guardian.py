
import time

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.contacts import ContactStore
from app.incidents import IncidentStore
from app.links import ChannelStore, GuardianStore, make_guardian_code, normalize_code
from app.links import OwnerLinks
from app.ratelimit import RateLimiter

DEVICE = "device-1234-abcd"


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "_contact_store", ContactStore(path=str(tmp_path / "contacts.json")))
    monkeypatch.setattr(main, "_incidents", IncidentStore(path=str(tmp_path / "inc.json")))
    monkeypatch.setattr(main, "_guardians", GuardianStore(str(tmp_path / "g.json")))
    monkeypatch.setattr(main, "_owner_links", OwnerLinks(str(tmp_path / "o.json")))
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


def test_watch_session_is_listed_for_the_guardian_without_alerts(api):
    code = new_code(api)
    res = start(
        api, session="watch-abc12345", mode="watch", guardian_code=code, contact_codes=[]
    )
    assert res["delivery"] == []
    listed = api.get("/guardian/api/incidents", headers={"X-Guardian-Code": code}).json()
    assert listed["incidents"][0]["mode"] == "watch"


def test_transcript_and_guardian_chat(api, monkeypatch):
    code = new_code(api)
    res = start(api, guardian_code=code)
    incident_id = res["id"]
    posted = api.post(
        f"/incident/{incident_id}/transcript",
        json={"lines": [{"t": 1.0, "text": "come with me"}, {"t": 2.0, "text": "come with me"}]},
    )
    assert posted.status_code == 200 and posted.json()["total"] == 1
    seen = {}

    def fake(context, history, question, frames=None):
        seen.update(context=context, question=question)
        return "She may be pressured. Call her.", 0.1

    monkeypatch.setattr(main._muse_client, "chat_about_incident", fake)
    out = api.post(
        f"/guardian/api/incidents/{incident_id}/chat",
        json={"question": "What happened?", "history": []},
        headers={"X-Guardian-Code": code},
    )
    assert out.status_code == 200
    assert out.json()["answer"].endswith("it can make mistakes.")
    assert "come with me" in seen["context"]
    other = api.post(
        f"/guardian/api/incidents/{incident_id}/chat",
        json={"question": "What happened?"},
        headers={"X-Guardian-Code": new_code(api)},
    )
    assert other.status_code == 404


def test_chat_passes_video_frames_and_rejects_bad_ones(api, monkeypatch):
    code = new_code(api)
    incident_id = start(api, guardian_code=code)["id"]
    seen = {}

    def fake(context, history, question, frames=None):
        seen["frames"] = frames
        return "ok", 0.1

    monkeypatch.setattr(main._muse_client, "chat_about_incident", fake)
    headers = {"X-Guardian-Code": code}
    url = f"/guardian/api/incidents/{incident_id}/chat"
    good = api.post(url, json={"question": "What happened?", "frames": ["QUJD"]}, headers=headers)
    assert good.status_code == 200 and seen["frames"] == ["QUJD"]
    bad = api.post(url, json={"question": "What happened?", "frames": ["not base64!"]}, headers=headers)
    assert bad.status_code == 422


def test_chat_refuses_off_topic_questions_and_states_its_scope(api, monkeypatch):
    from app.muse import CHAT_SYSTEM_PROMPT

    assert "[OFF_TOPIC]" in CHAT_SYSTEM_PROMPT and "general personal-safety" in CHAT_SYSTEM_PROMPT
    code = new_code(api)
    incident_id = start(api, guardian_code=code)["id"]
    monkeypatch.setattr(
        main._muse_client, "chat_about_incident",
        lambda context, history, question, frames=None: ("[OFF_TOPIC]", 0.1),
    )
    out = api.post(
        f"/guardian/api/incidents/{incident_id}/chat",
        json={"question": "Write me a poem about cats"},
        headers={"X-Guardian-Code": code},
    ).json()
    assert out["answer"] == main.CHAT_OFF_TOPIC


def test_one_chat_that_is_guardian_and_contact_gets_a_single_alert(api, monkeypatch):
    import dataclasses

    monkeypatch.setattr(
        main, "SETTINGS",
        dataclasses.replace(main.SETTINGS, notify_mode="telegram", telegram_bot="TestBot"),
    )
    code = new_code(api)
    main.get_guardians().link_chat(code, 777)
    contact = main.get_contact_store().invite("Mum")
    contact_code = contact["code"] if isinstance(contact, dict) else contact
    main.get_contact_store().link(contact_code, 777)
    res = start(api, guardian_code=code, contact_codes=[contact_code])
    sent = [d for d in res["delivery"] if d["status"] == "dry-run"]
    assert [d["code"] for d in sent] == ["guardian"]
    assert any(d["status"] == "skipped" and d["code"] == contact_code for d in res["delivery"])


def test_items_with_a_high_mention_count_are_accepted(api):
    iid = start(api)["id"]
    item = {"type": "name", "text": "Ujjwal", "rating": "possible", "t": time.time(), "count": 80}
    res = api.post(f"/incident/{iid}/items", json={"items": [item]})
    assert res.status_code == 200 and res.json()["stored"] == 1


def test_bot_replies_to_a_plain_start_and_confirms_a_guardian_link(api, monkeypatch):
    sent = []

    class Recorder:
        def send_text(self, chat_id, text, url_button=None):
            sent.append((chat_id, text, url_button))

        def send_location_request(self, *args, **kwargs):
            pass

    monkeypatch.setattr(main, "make_notifier", lambda settings: Recorder())
    code = new_code(api)
    plain = {"update_id": 1, "message": {"text": "/start", "chat": {"id": 55}}}
    main._handle_telegram_updates({"result": [plain]})
    assert sent and sent[0][0] == 55 and "link" in sent[0][1]
    sent.clear()
    guardian = {"update_id": 2, "message": {"text": f"/start g_{code}", "chat": {"id": 56}}}
    main._handle_telegram_updates({"result": [guardian]})
    assert [chat for chat, _, _ in sent] == [56]
    assert sent[0][2][0] == "Open guardian portal"
    assert main.get_guardians().chat_id(code) == 56


def _as_person(api, token, **over):
    body = {"session": over.pop("session"), "wearer_name": "Samantha", "dry_run": True}
    body.update(over)
    res = api.post("/incident/start", json=body, headers={"X-Safeguard-Token": token})
    assert res.status_code == 200, res.text
    return res.json()["id"]


def _listed(api, code):
    res = api.get("/guardian/api/incidents", headers={"X-Guardian-Code": code})
    return {i["id"] for i in res.json()["incidents"]}


def test_a_new_guardian_code_sees_all_past_recordings_of_the_same_person(api):
    samantha = main.make_device_token()
    old_code, new_code_ = new_code(api), new_code(api)
    first = _as_person(api, samantha, session="sos-aaaaaaa1", guardian_code=old_code)
    assert _listed(api, old_code) == {first}
    second = _as_person(api, samantha, session="sos-aaaaaaa2", guardian_code=new_code_)
    assert _listed(api, new_code_) == {first, second}
    assert _listed(api, old_code) == {first}
    detail = api.get(f"/guardian/api/incidents/{first}", headers={"X-Guardian-Code": new_code_})
    assert detail.status_code == 200


def test_entering_a_code_in_the_app_links_it_and_adopts_earlier_recordings(api):
    samantha = main.make_device_token()
    old_code, new_code_ = new_code(api), new_code(api)
    first = _as_person(api, samantha, session="sos-bbbbbbb1", guardian_code=old_code)
    check = api.get(f"/guardian/check/{new_code_}", headers={"X-Safeguard-Token": samantha})
    assert check.json() == {"valid": True}
    assert _listed(api, new_code_) == {first}


def test_a_guardian_never_sees_another_persons_recordings(api):
    samantha, someone_else = main.make_device_token(), main.make_device_token()
    code_a, code_b = new_code(api), new_code(api)
    mine = _as_person(api, samantha, session="sos-ccccccc1", guardian_code=code_a)
    other = _as_person(api, someone_else, session="sos-ccccccc2", guardian_code=code_b)
    assert _listed(api, code_a) == {mine} and _listed(api, code_b) == {other}
    assert api.get(f"/guardian/api/incidents/{other}", headers={"X-Guardian-Code": code_a}).status_code == 404


def test_recordings_made_before_ownership_existed_are_adopted_by_name_and_link(api):
    samantha = main.make_device_token()
    old_code, new_code_ = new_code(api), new_code(api)
    legacy = [
        start(api, session="sos-ddddddd1", wearer_name="Samantha", guardian_code=old_code)["id"],
        start(api, session="sos-ddddddd2", wearer_name="Samantha")["id"],
    ]
    stranger = start(api, session="sos-ddddddd3", wearer_name="Priya", guardian_code=old_code)["id"]
    _as_person(api, samantha, session="sos-ddddddd4", guardian_code=new_code_)
    listed = _listed(api, new_code_)
    assert set(legacy) <= listed
    assert stranger not in listed


def test_recordings_of_a_person_are_kept_as_long_as_guardian_recordings(api):
    samantha = main.make_device_token()
    code = new_code(api)
    first = _as_person(api, samantha, session="sos-eeeeeee1", guardian_code=code)
    incident = main.get_incidents().get(first)
    assert incident.owner
    incident.status, incident.ended_at = "ended", time.time() - 7 * 3600
    incident.guardian_code = ""
    assert not main.get_incidents().expired(incident)


def test_orphan_recordings_can_be_restored_by_the_owner_only(api):
    code = new_code(api)
    seed(api, "sos-orphan001", {"init.mp4": b"i", "seg-00001-2000.m4s": b"s"})
    seed(api, "sos-orphan002", {"shot-00001.jpg": b"j"})
    seed(api, "sos-live00001", {"init.mp4": b"i", "seg-00001-2000.m4s": b"s"})
    known = start(api, session="sos-live00001", guardian_code=code)["id"]
    body = {"guardian_code": code, "wearer_name": "Samantha"}
    preview = api.post("/admin/recover-recordings", json=body).json()
    assert preview["found"] == 1 and preview["restored"] == 0 and not preview["applied"]
    done = api.post("/admin/recover-recordings", json={**body, "apply": True}).json()
    assert done["restored"] == 1
    listed = api.get("/guardian/api/incidents", headers={"X-Guardian-Code": code}).json()["incidents"]
    assert len(listed) == 2 and known in {i["id"] for i in listed}
    assert api.post("/admin/recover-recordings", json={**body, "apply": True}).json()["found"] == 0


def test_restoring_needs_the_owner_token(api, monkeypatch):
    import dataclasses

    monkeypatch.setattr(main, "SETTINGS", dataclasses.replace(main.SETTINGS, app_token="owner-secret"))
    code = new_code(api)
    body = {"guardian_code": code, "wearer_name": "Samantha"}
    assert api.post("/admin/recover-recordings", json=body).status_code == 401
    assert api.post("/admin/recover-recordings", json=body, headers={"X-Safeguard-Token": "d1.a.b"}).status_code == 401
    ok = api.post("/admin/recover-recordings", json=body, headers={"X-Safeguard-Token": "owner-secret"})
    assert ok.status_code == 200


def test_restore_attaches_every_recording_of_a_person_to_the_current_code(api):
    old_code, new_code_ = new_code(api), new_code(api)
    start(api, session="sos-ggggggg1", wearer_name="Samantha", guardian_code=old_code)
    start(api, session="sos-ggggggg2", wearer_name="Samantha")
    other = start(api, session="sos-ggggggg3", wearer_name="Priya", guardian_code=old_code)["id"]
    body = {"guardian_code": new_code_, "wearer_name": "samantha"}
    preview = api.post("/admin/recover-recordings", json=body).json()
    assert preview["claimable"] == 2 and preview["claimed"] == 0
    done = api.post("/admin/recover-recordings", json={**body, "apply": True}).json()
    assert done["claimed"] == 2
    listed = {i["id"] for i in api.get("/guardian/api/incidents", headers={"X-Guardian-Code": new_code_}).json()["incidents"]}
    assert len(listed) == 2 and other not in listed
    later_code = new_code(api)
    token = main.make_device_token()
    _as_person(api, token, session="sos-ggggggg4", guardian_code=later_code)
    assert len(_listed(api, later_code)) == 3


def _api_items(api, code, **params):
    res = api.get("/guardian/api/incidents", params=params, headers={"X-Guardian-Code": code})
    assert res.status_code == 200, res.text
    return res.json()


def test_guardian_list_pages_filters_by_date_and_searches_evidence(api):
    code = new_code(api)
    ids = [start(api, session=f"sos-hhhhhhh{n}", guardian_code=code)["id"] for n in range(5)]
    now = time.time()
    for n, incident_id in enumerate(ids):
        main.get_incidents().get(incident_id).created_at = now - n * 86400
    main.get_incidents().upsert_items(ids[0], [
        {"type": "name", "text": "Ujjwal", "rating": "possible", "t": now, "count": 1},
        {"type": "plate", "text": "HR 98 B 3696", "rating": "strongly possible", "t": now, "count": 2},
    ])
    main.get_incidents().upsert_items(ids[1], [
        {"type": "name", "text": "Deepika", "rating": "possible", "t": now, "count": 1},
    ])
    main.get_incidents().add_transcript(ids[2], [{"t": now, "text": "please come with me"}])

    page = _api_items(api, code, per_page=2)
    assert page["total"] == 5 and page["pages"] == 3 and len(page["incidents"]) == 2
    assert [i["id"] for i in page["incidents"]] == ids[:2]
    assert _api_items(api, code, per_page=2, page=3)["incidents"][0]["id"] == ids[4]
    assert _api_items(api, code, per_page=2, page=99)["page"] == 3

    week = _api_items(api, code, since=now - 2.5 * 86400)
    assert {i["id"] for i in week["incidents"]} == set(ids[:3])
    assert {i["id"] for i in _api_items(api, code, until=now - 2.5 * 86400)["incidents"]} == set(ids[3:])

    assert {i["id"] for i in _api_items(api, code, has="evidence")["incidents"]} == set(ids[:2])
    assert {i["id"] for i in _api_items(api, code, has="none")["incidents"]} == set(ids[2:])
    assert [i["id"] for i in _api_items(api, code, has="plates")["incidents"]] == [ids[0]]
    assert [i["id"] for i in _api_items(api, code, has="names")["incidents"]] == ids[:2]

    found = _api_items(api, code, q="ujjwal")
    assert [i["id"] for i in found["incidents"]] == [ids[0]]
    assert found["incidents"][0]["hits"] == ["Name: Ujjwal"]
    assert found["incidents"][0]["evidence"] == {"names": 1, "plates": 1, "gestures": 0}
    assert [i["id"] for i in _api_items(api, code, q="come with")["incidents"]] == [ids[2]]
    assert [i["id"] for i in _api_items(api, code, q="hr 98 3696")["incidents"]] == [ids[0]]
    assert _api_items(api, code, q="nobody here")["total"] == 0
