
import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.contacts import ContactStore
from app.incidents import IncidentStore
from app.notify import alert_text, cab_text, end_text
from app.notify import test_text as build_test_text
from app.ratelimit import RateLimiter

fake_app_token = "-".join(["not", "a", "real", "app", "token"])


@pytest.fixture
def client(tmp_path, monkeypatch):
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


def test_builders_default_to_english():
    assert alert_text("Meera", "https://demo.test/live/x").startswith("SOS from Meera")
    assert end_text("Meera").startswith("SOS from Meera has ended")
    assert build_test_text("Meera", "https://demo.test/live/x").startswith("[TEST]")
    assert cab_text("D", "P1", 4, "https://demo.test/live/x").startswith("DEMO cab")


def test_builders_hindi_differs_and_names_wearer():
    for text in [
        alert_text("Meera", "https://demo.test/live/x", lang="hi"),
        end_text("Meera", lang="hi"),
        build_test_text("Meera", "https://demo.test/live/x", lang="hi"),
        cab_text("D", "P1", 4, "https://demo.test/live/x", lang="hi"),
    ]:
        assert "Meera" in text or "D, P1" in text
        assert any("\u0900" <= ch <= "\u097f" for ch in text), text


def test_start_accepts_lang_and_returns_preview(client):
    body = client.post(
        "/incident/start",
        json={
            "session": "sess-lang-1",
            "wearer_name": "Meera",
            "contact_codes": [],
            "test": True,
            "lang": "hi",
        },
    ).json()
    assert body["fresh"] is True
    assert body["preview_text"].startswith("[TEST] यह Meera")
    assert "https://demo.test/live/" in body["preview_text"]


def test_start_rejects_unknown_lang(client):
    response = client.post(
        "/incident/start",
        json={
            "session": "sess-lang-2",
            "wearer_name": "Meera",
            "contact_codes": [],
            "lang": "fr",
        },
    )
    assert response.status_code == 422


def test_templates_carry_no_appearance_or_transcript():
    import re

    forbidden = {
        "wearing", "wore", "shirt", "pants", "dress", "skinned", "beard",
        "man", "woman", "men", "women", "boy", "girl", "male", "female",
        "heard", "said", "transcript",
    }
    texts = [
        alert_text("Meera", "https://demo.test/live/x"),
        end_text("Meera"),
        build_test_text("Meera", "https://demo.test/live/x"),
        cab_text("D", "P1", 4, "https://demo.test/live/x"),
    ]
    for text in texts:
        words = set(re.findall(r"[a-z]+", text.lower()))
        assert not (words & forbidden), text


def test_end_uses_incident_lang(client):
    started = client.post(
        "/incident/start",
        json={
            "session": "sess-lang-3",
            "wearer_name": "Meera",
            "contact_codes": [],
            "lang": "hi",
        },
    ).json()
    ended = client.post(f"/incident/{started['id']}/end").json()
    assert ended["ended"] is True
    assert main.get_incidents().get(started["id"]).lang == "hi"
