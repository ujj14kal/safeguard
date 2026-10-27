"""Outbound contact alerts for SOS escalation.

Two notifiers behind one interface: `DryRunNotifier` (default — writes
every would-be message to a local JSONL file and sends nothing) and
`TelegramNotifier` (Telegram Bot API over httpx). `SmsNotifier` and
`WhatsAppNotifier` are roadmap (see README); add them here later.
"""

import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone

import httpx

logger = logging.getLogger("safeguard.notify")

TELEGRAM_API = "https://api.telegram.org"


@dataclass
class NotifyResult:
    ok: bool
    # "sent" | "dry-run" | "failed" | "skipped"
    status: str
    detail: str = ""


class NotifyConfigError(Exception):
    pass


class Notifier:
    """Interface every channel implements (Telegram now, SMS/WhatsApp later)."""

    name = "base"

    def send_text(self, chat_id, text, url_button=None) -> NotifyResult:
        raise NotImplementedError

    def send_location(self, chat_id, lat, lon) -> NotifyResult:
        raise NotImplementedError


class DryRunNotifier(Notifier):
    """Default: log the full would-be message locally, send nothing."""

    name = "dry-run"

    def __init__(self, log_path):
        self.log_path = log_path

    def _write(self, record):
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "channel": self.name,
            **record,
        }
        line = json.dumps(record)
        try:
            parent = os.path.dirname(self.log_path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(self.log_path, "a") as handle:
                handle.write(line + "\n")
        except OSError as exc:
            logger.warning("could not write notify log: %s", exc)

    def send_text(self, chat_id, text, url_button=None) -> NotifyResult:
        self._write({
            "kind": "text",
            "chat_id": chat_id,
            "text": text,
            "url_button": url_button,
        })
        return NotifyResult(True, "dry-run")

    def send_location(self, chat_id, lat, lon) -> NotifyResult:
        self._write({
            "kind": "location",
            "chat_id": chat_id,
            "lat": lat,
            "lon": lon,
        })
        return NotifyResult(True, "dry-run")


class TelegramNotifier(Notifier):
    """Real Telegram delivery. The bot token comes only from the settings
    (environment); it is never logged."""

    name = "telegram"

    def __init__(self, token, timeout_s=10):
        if not token:
            raise NotifyConfigError("TELEGRAM_BOT_TOKEN is not set")
        self._token = token
        self._timeout_s = timeout_s

    def _call(self, method, payload) -> NotifyResult:
        try:
            response = httpx.post(
                f"{TELEGRAM_API}/bot{self._token}/{method}",
                json=payload,
                timeout=self._timeout_s,
            )
        except httpx.HTTPError as exc:
            return NotifyResult(False, "failed", f"HTTP error: {exc}")
        if response.status_code != 200:
            return NotifyResult(
                False, "failed", f"Telegram status {response.status_code}"
            )
        try:
            body = json.loads(response.text)
        except json.JSONDecodeError:
            return NotifyResult(False, "failed", "Telegram returned bad JSON")
        if not body.get("ok"):
            return NotifyResult(
                False, "failed", f"Telegram refused: {body.get('description', '')}"[:120]
            )
        return NotifyResult(True, "sent")

    def send_text(self, chat_id, text, url_button=None) -> NotifyResult:
        payload = {"chat_id": chat_id, "text": text}
        if url_button is not None:
            label, url = url_button
            payload["reply_markup"] = {
                "inline_keyboard": [[{"text": label, "url": url}]]
            }
        return self._call("sendMessage", payload)

    def send_location(self, chat_id, lat, lon) -> NotifyResult:
        return self._call(
            "sendLocation",
            {"chat_id": chat_id, "latitude": lat, "longitude": lon},
        )


def make_notifier(settings) -> Notifier:
    """Dry-run unless the mode is telegram (which needs a bot token)."""
    if settings.notify_mode == "telegram":
        return TelegramNotifier(settings.telegram_bot_token)
    return DryRunNotifier(settings.notify_log_path)


# Message builders. Privacy rule: wearer name + links only — never
# transcripts, appearance, or anything about other people.

def maps_link(lat: float, lon: float) -> str:
    return f"https://maps.google.com/?q={lat:.5f},{lon:.5f}"


# Contact alerts go out in the wearer's app language ("en" or "hi").
# Hindi strings are machine-written: a native speaker should review them
# before real use (see DECISIONS.md).
def alert_text(wearer_name: str, live_url: str, maps_url=None, lang: str = "en") -> str:
    if lang == "hi":
        lines = [
            f"{wearer_name} की ओर से SOS। उन्हें मदद की ज़रूरत हो सकती है।",
            f"लाइव लोकेशन और वीडियो: {live_url}",
        ]
        if maps_url:
            lines.append(f"नक्शे का पिन: {maps_url}")
        return "\n".join(lines)
    lines = [
        f"SOS from {wearer_name}. They may need help.",
        f"Live location and video: {live_url}",
    ]
    if maps_url:
        lines.append(f"Map pin: {maps_url}")
    return "\n".join(lines)


def end_text(wearer_name: str, lang: str = "en") -> str:
    if lang == "hi":
        return f"{wearer_name} की ओर से SOS समाप्त हो गया है। वे सुरक्षित हैं।"
    return f"SOS from {wearer_name} has ended. They are safe."


def test_text(wearer_name: str, live_url: str, lang: str = "en") -> str:
    if lang == "hi":
        return (
            f"[TEST] यह {wearer_name} की ओर से एक परीक्षण अलर्ट है। "
            f"कोई कार्रवाई ज़रूरी नहीं है। लाइव पेज: {live_url}"
        )
    return (
        f"[TEST] This is a test alert from {wearer_name}. "
        f"No action needed. Live page: {live_url}"
    )


def cab_text(driver: str, plate: str, eta_min: int, live_url: str, lang: str = "en") -> str:
    if lang == "hi":
        return (
            "डेमो कैब (कोई असली कैब सेवा जुड़ी नहीं है): "
            f"{driver}, {plate}, लगभग {eta_min} मिनट में आ रही है। "
            f"लाइव पेज: {live_url}"
        )
    return (
        "DEMO cab (no real cab service is connected): "
        f"{driver}, {plate}, arriving in about {eta_min} min. "
        f"Live page: {live_url}"
    )
