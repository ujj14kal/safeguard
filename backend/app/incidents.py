
import json
import logging
import secrets
import threading
import time
from collections import deque
from dataclasses import dataclass, field

from .storage import StorageUnavailable, as_state_file

logger = logging.getLogger("safeguard.incidents")

MAX_POINTS = 500


def make_incident_id() -> str:
    return "inc-" + secrets.token_urlsafe(9)


def make_share_token() -> str:
    return secrets.token_urlsafe(24)


@dataclass
class Incident:
    id: str
    session: str
    wearer_name: str
    contact_codes: list
    share_token: str
    test: bool
    dry_run: bool
    lang: str = "en"
    status: str = "active"
    points: deque = field(default_factory=lambda: deque(maxlen=MAX_POINTS))
    created_at: float = field(default_factory=time.time)
    ended_at: float = 0
    alerted: bool = False
    end_sent: bool = False
    mode: str = "sos"
    guardian_code: str = ""
    items: list = field(default_factory=list)
    transcript: list = field(default_factory=list)
    last_seen: float = 0
    stale: bool = False

    def latest(self):
        return self.points[-1] if self.points else None


MAX_ITEMS = 120
MAX_TRANSCRIPT_LINES = 400
RATING_ORDER = {"possible": 1, "strongly possible": 2}


def _item_key(item):
    if item["type"] == "gesture":
        return ("gesture", item.get("shot") or int(item["t"]))
    text = item["text"].strip().lower()
    return (item["type"], text.replace(" ", "") if item["type"] == "plate" else text)


DEFAULT_TTL_AFTER_END_S = 6 * 3600
DEFAULT_GUARDIAN_TTL_AFTER_END_S = 30 * 86400
DEFAULT_MAX_ACTIVE_S = 24 * 3600
_SAVE_EVERY_S = 5
DEFAULT_STALE_AFTER_S = 90


class IncidentStore:
    def __init__(
        self,
        path=None,
        ttl_after_end_s=DEFAULT_TTL_AFTER_END_S,
        max_active_s=DEFAULT_MAX_ACTIVE_S,
        clock=time.time,
        guardian_ttl_after_end_s=DEFAULT_GUARDIAN_TTL_AFTER_END_S,
        stale_after_s=DEFAULT_STALE_AFTER_S,
    ):
        self._stale_after_s = stale_after_s
        self._start_lock = threading.Lock()
        self._by_id = {}
        self._by_session = {}
        self._by_token = {}
        self._file = as_state_file(path)
        self._ttl_after_end_s = ttl_after_end_s
        self._guardian_ttl_after_end_s = guardian_ttl_after_end_s
        self._max_active_s = max_active_s
        self._clock = clock
        self._last_save = 0.0
        self._load()


    def expired(self, incident) -> bool:
        now = self._clock()
        if incident.status == "ended":
            keep = self._guardian_ttl_after_end_s if incident.guardian_code else self._ttl_after_end_s
            return now - incident.ended_at > keep
        return now - incident.created_at > self._max_active_s


    def _settle(self, incident):
        if incident is None or incident.status != "active":
            return incident
        seen = incident.last_seen or incident.created_at
        if self._clock() - seen > self._stale_after_s:
            incident.status = "ended"
            incident.ended_at = seen
            incident.stale = True
            self.save(force=False)
        return incident

    def touch(self, incident_id=None, session=None):
        incident = self._by_id.get(incident_id) if incident_id else self._by_session.get(session)
        if incident is not None:
            self._revive(incident)
            if incident.status == "active":
                incident.last_seen = self._clock()

    def _revive(self, incident):
        if incident.status == "ended" and incident.stale and not self.expired(incident):
            incident.status = "active"
            incident.ended_at = 0
            incident.stale = False

    def _load(self):
        if self._file is None:
            return
        text = self._file.read()
        if text is None:
            return
        try:
            records = json.loads(text)
        except json.JSONDecodeError:
            return
        for record in records:
            try:
                points = record.pop("points", [])
                incident = Incident(**record)
                incident.points.extend(points)
            except TypeError:
                continue
            if self.expired(incident):
                continue
            self._index(incident)

    def _index(self, incident):
        self._by_id[incident.id] = incident
        self._by_session[incident.session] = incident
        self._by_token[incident.share_token] = incident

    def save(self, force=True):
        if self._file is None:
            return
        now = self._clock()
        if not force and now - self._last_save < _SAVE_EVERY_S:
            return
        self._last_save = now
        records = []
        for incident in list(self._by_id.values()):
            if self.expired(incident):
                self._by_id.pop(incident.id, None)
                if self._by_token.get(incident.share_token) is incident:
                    self._by_token.pop(incident.share_token, None)
                if self._by_session.get(incident.session) is incident:
                    self._by_session.pop(incident.session, None)
                continue
            record = {
                key: getattr(incident, key)
                for key in (
                    "id", "session", "wearer_name", "contact_codes", "share_token",
                    "test", "dry_run", "lang", "status", "created_at", "ended_at",
                    "alerted", "end_sent", "mode", "guardian_code", "items", "transcript", "last_seen",
                )
            }
            record["points"] = list(incident.points)
            records.append(record)
        try:
            self._file.write(json.dumps(records))
        except (OSError, StorageUnavailable) as exc:
            logger.warning("could not save incidents: %s", type(exc).__name__)

    def start(
        self, session, wearer_name, contact_codes, test=False, dry_run=True, lang="en",
        share_token=None, mode="sos", guardian_code="",
    ):
        with self._start_lock:
            return self._start_locked(
                session, wearer_name, contact_codes, test, dry_run, lang,
                share_token, mode, guardian_code,
            )

    def _start_locked(
        self, session, wearer_name, contact_codes, test, dry_run, lang,
        share_token, mode, guardian_code,
    ):
        existing = self._by_session.get(session)
        if existing is not None and existing.status == "active" and not self.expired(existing):
            return existing, False
        for other in list(self._by_id.values()):
            if other.status == "active" and other.share_token == (share_token or ""):
                other.status = "ended"
                other.ended_at = self._clock()
        incident = Incident(
            id=make_incident_id(),
            session=session,
            wearer_name=wearer_name,
            contact_codes=list(contact_codes),
            share_token=share_token or make_share_token(),
            test=test,
            dry_run=dry_run,
            lang=lang if lang in ("en", "hi") else "en",
            created_at=self._clock(),
            last_seen=self._clock(),
            mode=mode if mode in ("sos", "live", "watch") else "sos",
            guardian_code=guardian_code,
        )
        self._index(incident)
        self.save()
        return incident, True

    def get(self, incident_id):
        return self._settle(self._by_id.get(incident_id))

    def upsert_items(self, incident_id, items):
        incident = self._by_id.get(incident_id)
        if incident is None:
            return None
        self._revive(incident)
        if incident.status == "active":
            incident.last_seen = self._clock()
        for new in items:
            key = _item_key(new)
            existing = next((i for i in incident.items if _item_key(i) == key), None)
            if existing is None:
                if len(incident.items) >= MAX_ITEMS:
                    continue
                incident.items.append(dict(new))
                continue
            existing["count"] = int(existing.get("count", 1)) + int(new.get("count", 1))
            if RATING_ORDER.get(new["rating"], 0) > RATING_ORDER.get(existing["rating"], 0):
                existing["rating"] = new["rating"]
            existing["last"] = max(existing.get("last", existing["t"]), new.get("last", new["t"]))
            if not existing.get("shot") and new.get("shot"):
                existing["shot"] = new["shot"]
            if new.get("source") and not existing.get("source"):
                existing["source"] = new["source"]
        incident.items.sort(key=lambda item: item["t"])
        self.save()
        return incident

    def add_transcript(self, incident_id, lines):
        incident = self._by_id.get(incident_id)
        if incident is None:
            return None
        self._revive(incident)
        if incident.status == "active":
            incident.last_seen = self._clock()
        for line in lines:
            if incident.transcript and incident.transcript[-1]["text"] == line["text"]:
                continue
            incident.transcript.append(line)
        del incident.transcript[:-MAX_TRANSCRIPT_LINES]
        self.save(force=False)
        return incident

    def for_guardian(self, guardian_code):
        found = [
            incident for incident in map(self._settle, list(self._by_id.values()))
            if incident.guardian_code == guardian_code and not self.expired(incident)
        ]
        return sorted(found, key=lambda item: item.created_at, reverse=True)

    def get_by_token(self, share_token):
        incident = self._settle(self._by_token.get(share_token))
        if incident is None or self.expired(incident):
            return None
        return incident

    def add_point(self, incident_id, lat, lon, accuracy=None, ts=None):
        incident = self._by_id.get(incident_id)
        if incident is None:
            return False
        self._revive(incident)
        incident.points.append({
            "lat": lat,
            "lon": lon,
            "accuracy": accuracy,
            "ts": ts if ts is not None else time.time(),
        })
        incident.last_seen = self._clock()
        self.save(force=False)
        return True

    def end(self, incident_id):
        incident = self._by_id.get(incident_id)
        if incident is None or incident.status != "active":
            return None
        incident.status = "ended"
        incident.ended_at = self._clock()
        self.save()
        return incident
