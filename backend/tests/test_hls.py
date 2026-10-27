"""Continuous recording: fragmented-MP4 pieces become one HLS stream."""

import os
import time

import pytest
from fastapi.testclient import TestClient

from app import hls, main
from app.config import Settings
from app.contacts import ContactStore
from app.incidents import IncidentStore
from app.links import ChannelStore, GuardianStore
from app.ratelimit import RateLimiter


def entry(name, size=100, mtime=1000.0):
    return {"name": name, "bytes": size, "mtime": mtime}


def names(*seqs, dur=2000):
    return [entry("init.mp4")] + [entry(hls.segment_name(s, dur)) for s in seqs]


# --- the pure playlist ------------------------------------------------------

def test_segment_names_round_trip():
    assert hls.segment_name(7, 2000) == "seg-00007-2000.m4s"
    assert hls.parse_segment("seg-00007-2000.m4s") == (7, 2000)
    for bad in ["seg-7-2000.m4s", "seg-00007-2000.mp4", "video-00001.mp4", "../seg-00001-2000.m4s"]:
        assert hls.parse_segment(bad) is None


def test_nothing_to_play_without_init_or_segments():
    assert hls.build_playlist([entry("init.mp4")], str, False) is None
    assert hls.build_playlist([entry("seg-00001-2000.m4s")], str, False) is None


def test_live_playlist_is_an_event_without_endlist():
    text = hls.build_playlist(names(1, 2, 3), lambda n: f"u/{n}", over=False)
    assert "#EXT-X-PLAYLIST-TYPE:EVENT" in text and "#EXT-X-ENDLIST" not in text
    assert '#EXT-X-MAP:URI="u/init.mp4"' in text
    assert text.count("#EXTINF:2.000,") == 3
    assert "u/seg-00002-2000.m4s" in text and "#EXT-X-TARGETDURATION:2" in text


def test_finished_playlist_is_one_vod():
    text = hls.build_playlist(names(1, 2), lambda n: n, over=True)
    assert "#EXT-X-PLAYLIST-TYPE:VOD" in text and text.rstrip().endswith("#EXT-X-ENDLIST")


def test_a_missing_piece_is_marked_not_hidden():
    text = hls.build_playlist(names(1, 2, 4, 5), lambda n: n, over=True)
    assert text.count("#EXT-X-DISCONTINUITY") == 1
    assert text.count("#EXT-X-MAP") == 2


def test_target_duration_covers_the_longest_piece():
    entries = [entry("init.mp4"), entry(hls.segment_name(1, 2000)), entry(hls.segment_name(2, 3400))]
    assert "#EXT-X-TARGETDURATION:4" in hls.build_playlist(entries, str, False)


def test_stalled_streams_are_treated_as_over():
    fresh = names(1, 2)
    assert not hls.is_over(False, fresh, now=1010.0)
    assert hls.is_over(False, fresh, now=1000.0 + hls.STALL_SECONDS + 1)
    assert hls.is_over(True, fresh, now=1001.0)


def test_media_types():
    assert hls.media_type("init.mp4") == "video/mp4"
    assert hls.media_type("seg-00001-2000.m4s") == "video/mp4"
    assert hls.media_type("audio-00001.m4a") == "audio/mp4"
    assert hls.media_type("evil.sh") is None


# --- the API -----------------------------------------------------------------

@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "_contact_store", ContactStore(path=str(tmp_path / "c.json")))
    monkeypatch.setattr(main, "_incidents", IncidentStore(path=str(tmp_path / "i.json")))
    monkeypatch.setattr(main, "_guardians", GuardianStore(str(tmp_path / "g.json")))
    monkeypatch.setattr(main, "_channels", ChannelStore(str(tmp_path / "ch.json")))
    monkeypatch.setattr(main, "_incident_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "_guardian_register_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "_guardian_fail_limiters", {})
    monkeypatch.setattr(main, "_guardian_ok_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "SETTINGS", Settings(
        contacts_path=str(tmp_path / "c.json"), notify_log_path=str(tmp_path / "n.jsonl"),
        evidence_dir=str(tmp_path / "ev"), app_token="", notify_mode="dry-run",
        public_base_url="https://demo.test",
    ))
    client = TestClient(main.app)
    client.ev = tmp_path / "ev"
    return client


def start(api, **over):
    body = {"session": "sos-hlstest01", "wearer_name": "Asha", "dry_run": True, "lat": 1.0, "lon": 2.0}
    body.update(over)
    return api.post("/incident/start", json=body).json()


def upload(api, kind, seq=0, ext="mp4", dur=None, data=b"x" * 50):
    q = f"/evidence?session=sos-hlstest01&kind={kind}&seq={seq}&ext={ext}"
    if dur is not None:
        q += f"&dur={dur}"
    return api.post(q, content=data)


def test_upload_names_init_and_segments_from_validated_fields(api):
    assert upload(api, "init").json()["stored"] is True
    assert upload(api, "seg", seq=1, ext="m4s", dur=2000).status_code == 200
    stored = sorted(p.name for p in (api.ev / "sos-hlstest01").iterdir())
    assert stored == ["init.mp4", "seg-00001-2000.m4s"]


def test_upload_rejects_bad_durations_and_extensions(api):
    assert upload(api, "seg", seq=1, ext="m4s").status_code == 422          # no duration
    assert upload(api, "seg", seq=1, ext="m4s", dur=5).status_code == 422
    assert upload(api, "seg", seq=1, ext="m4s", dur=999999).status_code == 422
    assert upload(api, "seg", seq=1, ext="mp4", dur=2000).status_code == 422
    assert upload(api, "init", ext="m4s").status_code == 422


def test_family_page_gets_a_live_event_playlist_then_a_finished_one(api):
    inc = start(api)
    upload(api, "init")
    for n in (1, 2, 3):
        upload(api, "seg", seq=n, ext="m4s", dur=2000)
    token = inc["share_token"]
    state = api.get(f"/live/{token}/state").json()
    assert state["hls"]["segments"] == 3 and state["hls"]["over"] is False
    live = api.get(f"/live/{token}/stream.m3u8")
    assert live.status_code == 200 and "mpegurl" in live.headers["content-type"]
    assert "EVENT" in live.text and "segments/init.mp4" in live.text
    assert live.headers["cache-control"] == "no-store"
    api.post(f"/incident/{inc['id']}/end")
    done = api.get(f"/live/{token}/stream.m3u8").text
    assert "VOD" in done and "#EXT-X-ENDLIST" in done
    assert api.get(f"/live/{token}/segments/seg-00002-2000.m4s").status_code == 200
    assert api.get(f"/live/{token}/segments/init.mp4").content == b"x" * 50


def test_playlist_404_until_there_is_something_to_play(api):
    inc = start(api)
    assert api.get(f"/live/{inc['share_token']}/stream.m3u8").status_code == 404
    assert api.get(f"/live/{inc['share_token']}/state").json()["hls"] is None


def test_a_phone_that_went_quiet_is_closed_for_viewers(api):
    inc = start(api)
    upload(api, "init")
    upload(api, "seg", seq=1, ext="m4s", dur=2000)
    old = time.time() - hls.STALL_SECONDS - 30
    for path in (api.ev / "sos-hlstest01").iterdir():
        os.utime(path, (old, old))
    text = api.get(f"/live/{inc['share_token']}/stream.m3u8").text
    assert "VOD" in text and "#EXT-X-ENDLIST" in text      # no waiting for ever
    assert api.get(f"/live/{inc['share_token']}/state").json()["status"] == "active"


def test_guardian_gets_one_signed_playlist_with_signed_pieces(api):
    code = api.post("/guardian/register").json()["code"]
    inc = start(api, guardian_code=code)
    upload(api, "init")
    upload(api, "seg", seq=1, ext="m4s", dur=2000)
    api.post(f"/incident/{inc['id']}/end")
    h = {"X-Guardian-Code": code}
    summary = api.get("/guardian/api/incidents", headers=h).json()["incidents"][0]
    assert summary["continuous"] is True
    detail = api.get(f"/guardian/api/incidents/{inc['id']}", headers=h).json()
    url = detail["hls"]["url"]
    assert detail["hls"]["over"] is True and "sig=" in url
    playlist = api.get(url)
    assert playlist.status_code == 200 and "#EXT-X-ENDLIST" in playlist.text
    piece = [line for line in playlist.text.splitlines() if line.startswith("/guardian/media/")]
    assert piece and all("sig=" in line for line in piece)
    for line in piece:
        assert api.get(line).status_code == 200
    # unsigned or tampered playlist is refused
    assert api.get(url.split("?")[0]).status_code == 403
    assert api.get(url.split("sig=")[0] + "sig=" + "0" * 40).status_code == 403


def test_other_guardians_never_get_a_playlist(api):
    mine, other = api.post("/guardian/register").json()["code"], api.post("/guardian/register").json()["code"]
    inc = start(api, guardian_code=mine)
    upload(api, "init")
    upload(api, "seg", seq=1, ext="m4s", dur=2000)
    res = api.get(f"/guardian/api/incidents/{inc['id']}", headers={"X-Guardian-Code": other})
    assert res.status_code == 404


def test_old_style_parts_still_work_next_to_the_stream(api):
    inc = start(api)
    api.post("/evidence?session=sos-hlstest01&kind=video&seq=0&ext=mp4", content=b"v")
    state = api.get(f"/live/{inc['share_token']}/state").json()
    assert [s["kind"] for s in state["segments"]] == ["video"] and state["hls"] is None
