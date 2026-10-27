"""Incident store: one burst per session, token entropy, trail cap."""

from app import incidents
from app.incidents import IncidentStore


def test_share_token_is_unguessable():
    tokens = {incidents.make_share_token() for _ in range(200)}
    assert len(tokens) == 200
    assert all(len(token) >= 32 for token in tokens)


def test_one_burst_per_session():
    store = IncidentStore()
    first, fresh = store.start(
        session="sos-abcdef12",
        wearer_name="Aarav",
        contact_codes=["a", "b"],
    )
    assert fresh and first.status == "active"
    assert first.id.startswith("inc-")
    second, fresh_again = store.start(
        session="sos-abcdef12",
        wearer_name="Aarav",
        contact_codes=["a", "b"],
    )
    assert second is first and not fresh_again


def test_new_session_after_end_is_fresh():
    store = IncidentStore()
    first, _ = store.start(
        session="sos-abcdef12",
        wearer_name="Aarav",
        contact_codes=[],
    )
    assert store.end(first.id) is first
    assert first.status == "ended" and first.ended_at > 0
    assert store.end(first.id) is None
    assert store.end("inc-missing") is None
    second, fresh = store.start(
        session="sos-abcdef12",
        wearer_name="Aarav",
        contact_codes=[],
    )
    assert fresh and second is not first


def test_lookups():
    store = IncidentStore()
    incident, _ = store.start(
        session="sos-abcdef12",
        wearer_name="Aarav",
        contact_codes=[],
    )
    assert store.get(incident.id) is incident
    assert store.get("inc-missing") is None
    assert store.get_by_token(incident.share_token) is incident
    assert store.get_by_token("wrong") is None


def test_trail_keeps_last_500():
    store = IncidentStore()
    incident, _ = store.start(
        session="sos-abcdef12",
        wearer_name="Aarav",
        contact_codes=[],
    )
    for index in range(505):
        assert store.add_point(
            incident.id,
            12.0 + index / 1000,
            77.0,
            accuracy=5,
            ts=1000 + index,
        )
    assert len(incident.points) == 500
    assert incident.latest()["ts"] == 1504
    assert incident.points[0]["ts"] == 1005
    assert not store.add_point("inc-missing", 12.0, 77.0)
