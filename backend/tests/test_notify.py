"""Notifier unit tests: dry-run logging, Telegram shapes, message builders."""

import json

import pytest

from app import notify
from app.muse import mentions_appearance

fake_token = "-".join(["not", "a", "real", "token"])
fake_chat = 123456789


class FakePost:
    def __init__(self, status_code=200, body='{"ok": true}'):
        self.calls = []
        self.status_code = status_code
        self.body = body

    def __call__(self, url, json=None, timeout=None):  # noqa: A002
        self.calls.append(
            {
                "url": url,
                "json": json,
                "timeout": timeout,
            }
        )
        response = type("Response", (), {})()
        response.status_code = self.status_code
        response.text = self.body
        return response


def test_dry_run_writes_message_and_sends_nothing(tmp_path):
    log = str(tmp_path / "n.jsonl")
    sender = notify.DryRunNotifier(
        log_path=log,
    )
    result = sender.send_text(
        fake_chat,
        "hello there",
        url_button=(
            "Open live view",
            "https://example.test/live/abc",
        ),
    )
    assert result.ok and result.status == "dry-run"
    (record,) = [json.loads(line) for line in open(log)]
    assert record["kind"] == "text"
    assert record["chat_id"] == fake_chat
    assert record["text"] == "hello there"
    assert record["url_button"][1] == "https://example.test/live/abc"


def test_dry_run_location(tmp_path):
    log = str(tmp_path / "n.jsonl")
    sender = notify.DryRunNotifier(
        log_path=log,
    )
    result = sender.send_location(
        fake_chat,
        12.34,
        56.78,
    )
    assert result.ok and result.status == "dry-run"
    (record,) = [json.loads(line) for line in open(log)]
    assert (record["lat"], record["lon"]) == (12.34, 56.78)


def test_telegram_text_shape(monkeypatch):
    fake = FakePost()
    monkeypatch.setattr(
        notify.httpx,
        "post",
        fake,
    )
    sender = notify.TelegramNotifier(
        token=fake_token,
    )
    result = sender.send_text(
        fake_chat,
        "SOS",
        url_button=(
            "Open live view",
            "https://example.test/live/abc",
        ),
    )
    assert result.ok and result.status == "sent"
    (call,) = fake.calls
    assert call["url"].endswith("/sendMessage")
    assert fake_token in call["url"]
    assert call["json"]["chat_id"] == fake_chat
    assert call["json"]["text"] == "SOS"
    button = call["json"]["reply_markup"]["inline_keyboard"][0][0]
    assert button == {"text": "Open live view", "url": "https://example.test/live/abc"}


def test_telegram_location_shape(monkeypatch):
    fake = FakePost()
    monkeypatch.setattr(
        notify.httpx,
        "post",
        fake,
    )
    sender = notify.TelegramNotifier(
        token=fake_token,
    )
    assert sender.send_location(
        fake_chat,
        12.34,
        56.78,
    ).status == "sent"
    (call,) = fake.calls
    assert call["url"].endswith("/sendLocation")
    assert call["json"]["latitude"] == 12.34
    assert call["json"]["longitude"] == 56.78


def test_telegram_failures(monkeypatch):
    sender = notify.TelegramNotifier(
        token=fake_token,
    )
    monkeypatch.setattr(
        notify.httpx,
        "post",
        FakePost(
            status_code=500,
            body="boom",
        ),
    )
    assert sender.send_text(fake_chat, "x").status == "failed"
    monkeypatch.setattr(
        notify.httpx,
        "post",
        FakePost(body='{"ok": false, "description": "blocked"}'),
    )
    refused = sender.send_text(fake_chat, "x")
    assert refused.status == "failed" and "blocked" in refused.detail

    def raises(url, json=None, timeout=None):  # noqa: A002
        raise notify.httpx.ConnectError("down")

    monkeypatch.setattr(
        notify.httpx,
        "post",
        raises,
    )
    assert sender.send_text(fake_chat, "x").status == "failed"


def test_telegram_needs_a_token():
    with pytest.raises(notify.NotifyConfigError):
        notify.TelegramNotifier(
            token="",
        )


def test_make_notifier_modes(tmp_path):
    dry_settings = type("Settings", (), {})()
    dry_settings.notify_mode = "dry-run"
    dry_settings.notify_log_path = str(tmp_path / "n.jsonl")
    assert isinstance(notify.make_notifier(dry_settings), notify.DryRunNotifier)
    tg_settings = type("Settings", (), {})()
    tg_settings.notify_mode = "telegram"
    tg_settings.telegram_bot_token = fake_token
    assert isinstance(notify.make_notifier(tg_settings), notify.TelegramNotifier)


def test_message_builders_carry_no_appearance_or_transcript():
    live = "https://example.test/live/abc123"
    texts = [
        notify.alert_text(
            "Aarav",
            live,
            maps_url=notify.maps_link(
                12.9716,
                77.5946,
            ),
        ),
        notify.end_text("Aarav"),
        notify.test_text("Aarav", live),
        notify.cab_text(
            "Demo Driver",
            "DL-1D-EMO",
            4,
            live,
        ),
    ]
    for text in texts:
        assert mentions_appearance(text) is None, text
        assert "wearing" not in text.lower()
    assert live in texts[0] and "maps.google.com" in texts[0]
    assert "[TEST]" in texts[2]
    assert "DEMO" in texts[3] and "no real cab service" in texts[3]


def test_ride_link_is_an_uber_universal_link_to_the_wearer():
    link = notify.ride_link(12.9716, 77.5946)
    assert link.startswith("https://m.uber.com/ul/?")
    assert "action=setPickup" in link and "pickup=my_location" in link
    assert "dropoff%5Blatitude%5D=12.97160" in link
    assert "dropoff%5Blongitude%5D=77.59460" in link
    assert " " not in link


def test_alert_text_adds_the_ride_line_only_when_given():
    live = "https://example.test/live/abc123"
    plain = notify.alert_text("Aarav", live)
    assert "Uber" not in plain
    with_ride = notify.alert_text("Aarav", live, ride_url=notify.ride_link(1.0, 2.0))
    assert "Send a cab to them (Uber): https://m.uber.com/ul/" in with_ride
    hindi = notify.alert_text("Aarav", live, lang="hi", ride_url="https://m.uber.com/ul/?x=1")
    assert "Uber" in hindi and "https://m.uber.com/ul/?x=1" in hindi
