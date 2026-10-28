
import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlencode

import httpx

logger = logging.getLogger("safeguard.notify")

TELEGRAM_API = "https://api.telegram.org"


@dataclass
class NotifyResult:
    ok: bool
    status: str
    detail: str = ""


class NotifyConfigError(Exception):
    pass


class Notifier:

    name = "base"

    def send_text(self, chat_id, text, url_button=None) -> NotifyResult:
        raise NotImplementedError

    def send_location(self, chat_id, lat, lon) -> NotifyResult:
        raise NotImplementedError


    def send_location_request(self, chat_id, text, button) -> NotifyResult:
        return NotifyResult(True, "skipped")


class DryRunNotifier(Notifier):

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

    def send_location_request(self, chat_id, text, button) -> NotifyResult:
        return self._call("sendMessage", {
            "chat_id": chat_id,
            "text": text,
            "reply_markup": {
                "keyboard": [[{"text": button, "request_location": True}]],
                "resize_keyboard": True,
                "one_time_keyboard": True,
            },
        })


def make_notifier(settings) -> Notifier:
    if settings.notify_mode == "telegram":
        return TelegramNotifier(settings.telegram_bot_token)
    return DryRunNotifier(settings.notify_log_path)


def maps_link(lat: float, lon: float) -> str:
    return f"https://maps.google.com/?q={lat:.5f},{lon:.5f}"


def ride_link(lat: float, lon: float) -> str:
    query = urlencode({
        "action": "setPickup",
        "pickup": "my_location",
        "dropoff[latitude]": f"{lat:.5f}",
        "dropoff[longitude]": f"{lon:.5f}",
        "dropoff[nickname]": "SOS",
    })
    return f"https://m.uber.com/ul/?{query}"


def alert_text(
    wearer_name: str, live_url: str, maps_url=None, lang: str = "en", ride_url=None
) -> str:
    if lang == "hi":
        lines = [
            f"{wearer_name} की ओर से SOS। उन्हें मदद की ज़रूरत हो सकती है।",
            f"लाइव लोकेशन और वीडियो: {live_url}",
        ]
        if maps_url:
            lines.append(f"नक्शे का पिन: {maps_url}")
        if ride_url:
            lines.append(f"उन तक कैब भेजें (Uber): {ride_url}")
        return "\n".join(lines)
    lines = [
        f"SOS from {wearer_name}. They may need help.",
        f"Live location and video: {live_url}",
    ]
    if maps_url:
        lines.append(f"Map pin: {maps_url}")
    if ride_url:
        lines.append(f"Send a cab to them (Uber): {ride_url}")
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


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    from math import asin, cos, radians, sin, sqrt

    dlat, dlon = radians(lat2 - lat1), radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    return 2 * 6371.0 * asin(sqrt(a))


def _km_text(km: float, lang: str) -> str:
    if km < 1:
        meters = max(50, int(round(km * 1000 / 50.0)) * 50)
        return f"{meters} मीटर" if lang == "hi" else f"{meters} m"
    return f"{km:.1f} किमी" if lang == "hi" else f"{km:.1f} km"


def nearest_notes(contacts, pin, lang="en", now=None, max_age_s=12 * 3600) -> dict:
    if pin is None:
        return {}
    now = now if now is not None else datetime.now(timezone.utc).timestamp()
    ranked = []
    for record in contacts:
        lat, lon, at = record.get("lat"), record.get("lon"), record.get("loc_at")
        if record.get("chat_id") is None or lat is None or lon is None or at is None:
            continue
        if now - at > max_age_s:
            continue
        ranked.append((haversine_km(pin[0], pin[1], lat, lon), record["code"]))
    if not ranked:
        return {}
    ranked.sort()
    nearest_km, nearest_code = ranked[0]
    notes = {}
    for km, code in ranked:
        if code == nearest_code:
            notes[code] = (
                f"आप सबसे नज़दीकी संपर्क लगते हैं, लगभग {_km_text(km, lang)} दूर।"
                if lang == "hi"
                else f"You appear to be the nearest contact, about {_km_text(km, lang)} away."
            )
        else:
            notes[code] = (
                f"सबसे नज़दीकी संपर्क लगभग {_km_text(nearest_km, lang)} दूर है; आप लगभग {_km_text(km, lang)} दूर हैं।"
                if lang == "hi"
                else f"The nearest contact is about {_km_text(nearest_km, lang)} away; you are about {_km_text(km, lang)} away."
            )
    return notes
