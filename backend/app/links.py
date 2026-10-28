
import json
import logging
import secrets
import time

from .storage import StorageUnavailable, as_state_file

logger = logging.getLogger("safeguard.links")

_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_CODE_LEN = 12


def make_guardian_code() -> str:
    raw = "".join(secrets.choice(_ALPHABET) for _ in range(_CODE_LEN))
    return "-".join(raw[i : i + 4] for i in range(0, _CODE_LEN, 4))


def normalize_code(code: str) -> str:
    raw = "".join(ch for ch in (code or "").upper() if ch not in "- ")
    if len(raw) != _CODE_LEN or any(ch not in _ALPHABET for ch in raw):
        return ""
    return "-".join(raw[i : i + 4] for i in range(0, _CODE_LEN, 4))


class _JsonMap:

    def __init__(self, path=None):
        self._file = as_state_file(path)
        self._data: dict = {}
        if self._file is not None:
            text = self._file.read()
            if text:
                try:
                    loaded = json.loads(text)
                except json.JSONDecodeError:
                    loaded = None
                if isinstance(loaded, dict):
                    self._data = loaded

    def _save(self) -> None:
        if self._file is None:
            return
        try:
            self._file.write(json.dumps(self._data))
        except (OSError, StorageUnavailable) as exc:
            logger.warning("could not save: %s", type(exc).__name__)


class GuardianStore(_JsonMap):
    def create(self) -> str:
        for _ in range(5):
            code = make_guardian_code()
            if code not in self._data:
                self._data[code] = {"created_at": time.time()}
                self._save()
                return code
        raise RuntimeError("could not mint a unique guardian code")

    def exists(self, code: str) -> bool:
        return normalize_code(code) in self._data

    def link_chat(self, code: str, chat_id) -> bool:
        key = normalize_code(code)
        if key not in self._data or chat_id is None:
            return False
        self._data[key]["chat_id"] = chat_id
        self._save()
        return True

    def chat_id(self, code: str):
        entry = self._data.get(normalize_code(code))
        return entry.get("chat_id") if entry else None

    def revoke(self, code: str) -> bool:
        key = normalize_code(code)
        if key in self._data:
            del self._data[key]
            self._save()
            return True
        return False


class ChannelStore(_JsonMap):

    def get_or_create(self, device_id: str, wearer_name: str) -> dict:
        entry = self._data.get(device_id)
        if entry is None:
            entry = {
                "token": secrets.token_urlsafe(24),
                "wearer_name": wearer_name,
                "created_at": time.time(),
            }
            self._data[device_id] = entry
            self._save()
        elif wearer_name and entry.get("wearer_name") != wearer_name:
            entry["wearer_name"] = wearer_name
            self._save()
        return entry

    def revoke(self, device_id: str) -> bool:
        if device_id in self._data:
            del self._data[device_id]
            self._save()
            return True
        return False

    def by_token(self, token: str) -> dict | None:
        for entry in self._data.values():
            if secrets.compare_digest(entry.get("token", ""), token or ""):
                return entry
        return None
