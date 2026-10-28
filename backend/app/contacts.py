"""Emergency contacts: invite codes + Telegram chat-id linking.

No public webhook: the backend polls Telegram `getUpdates`, and when a
contact opens the invite link and presses Start, their chat id is stored
against the code. Persisted to a gitignored JSON file.
"""

import json
import secrets

from .storage import StorageUnavailable, as_state_file

MAX_CONTACTS = 5


def make_code() -> str:
    return secrets.token_urlsafe(6)


class ContactLimitError(Exception):
    pass


class ContactStore:
    def __init__(self, path):
        self._file = as_state_file(path)
        self._contacts = None

    @property
    def contacts(self):
        if self._contacts is None:
            self._contacts = self._load()
        return self._contacts

    def _load(self):
        if self._file is None:
            return []
        text = self._file.read()  # StorageUnavailable propagates: never start empty by mistake
        if text is None:
            return []
        try:
            body = json.loads(text)
        except ValueError:
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
        if self._file is None:
            return
        try:
            self._file.write(json.dumps({"contacts": self.contacts}))
        except StorageUnavailable:
            pass  # kept in memory; the next change retries

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

    def remove(self, code):
        """Deletes a contact by invite code. True when one was removed."""
        before = len(self.contacts)
        self._contacts = [r for r in self.contacts if r["code"] != code]
        if len(self.contacts) == before:
            return False
        self._save()
        return True


def invite_link(bot_username, code):
    return f"https://t.me/{bot_username}?start={code}"


GUARDIAN_START_PREFIX = "g_"


def guardian_invite_link(bot_username, code):
    return f"https://t.me/{bot_username}?start={GUARDIAN_START_PREFIX}{code}"


def link_from_updates(payload, store, guardians=None):
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
        if code.startswith(GUARDIAN_START_PREFIX):
            if guardians is not None and guardians.link_chat(code[len(GUARDIAN_START_PREFIX):], chat_id):
                linked.append(code)
            continue
        if store.link(code, chat_id) is not None:
            linked.append(code)
    return linked, offset
