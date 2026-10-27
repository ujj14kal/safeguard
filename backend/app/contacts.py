"""Emergency contacts: invite codes + Telegram chat-id linking.

No public webhook: the backend polls Telegram `getUpdates`, and when a
contact opens the invite link and presses Start, their chat id is stored
against the code. Persisted to a gitignored JSON file.
"""

import json
import os
import secrets

MAX_CONTACTS = 5


def make_code() -> str:
    return secrets.token_urlsafe(6)


class ContactLimitError(Exception):
    pass


class ContactStore:
    def __init__(self, path):
        self._path = path
        self._contacts = None

    @property
    def contacts(self):
        if self._contacts is None:
            self._contacts = self._load()
        return self._contacts

    def _load(self):
        try:
            with open(self._path) as handle:
                body = json.load(handle)
        except (OSError, ValueError):
            return []
        if not isinstance(body, dict) or not isinstance(body.get("contacts"), list):
            return []
        kept = []
        for item in body["contacts"]:
            if not isinstance(item, dict):
                continue
            name = item.get("name")
            code = item.get("code")
            if not name or not code:
                continue
            kept.append({
                "name": str(name)[:60],
                "code": str(code)[:32],
                "chat_id": item.get("chat_id"),
            })
        return kept[:MAX_CONTACTS]

    def _save(self):
        parent = os.path.dirname(self._path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(self._path, "w") as handle:
            json.dump({"contacts": self.contacts}, handle)

    def invite(self, name):
        """Adds a contact, returning its record (with a fresh code)."""
        clean = " ".join(str(name).split())[:60]
        if not clean:
            raise ValueError("name is required")
        if len(self.contacts) >= MAX_CONTACTS:
            raise ContactLimitError(f"at most {MAX_CONTACTS} contacts")
        record = {"name": clean, "code": make_code(), "chat_id": None}
        self.contacts.append(record)
        self._save()
        return dict(record)

    def link(self, code, chat_id):
        """Stores a chat id against an invite code. Returns the record."""
        for record in self.contacts:
            if record["code"] == code:
                record["chat_id"] = chat_id
                self._save()
                return dict(record)
        return None

    def get(self, code):
        for record in self.contacts:
            if record["code"] == code:
                return dict(record)
        return None


def invite_link(bot_username, code):
    return f"https://t.me/{bot_username}?start={code}"


def link_from_updates(payload, store):
    """Applies one Telegram `getUpdates` payload to the store.

    Returns (linked codes, next offset). Pure apart from the store calls,
    so tests feed it fake payloads without touching the network.
    """
    linked = []
    offset = None
    results = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        return linked, offset
    for update in results:
        if not isinstance(update, dict):
            continue
        update_id = update.get("update_id")
        if isinstance(update_id, int):
            offset = update_id + 1
        message = update.get("message") or {}
        text = message.get("text") or ""
        first = text.split()[0] if text.split() else ""
        if not first.startswith("/start"):
            continue
        parts = text.split(None, 1)
        code = parts[1].strip() if len(parts) > 1 else ""
        chat = message.get("chat") or {}
        chat_id = chat.get("id")
        if not code or chat_id is None:
            continue
        if store.link(code, chat_id) is not None:
            linked.append(code)
    return linked, offset
