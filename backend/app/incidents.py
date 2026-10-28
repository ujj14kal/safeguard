
import json
import logging
import secrets
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

    def latest(self):
        return self.points[-1] if self.points else None


DEFAULT_TTL_AFTER_END_S = 6 * 3600
DEFAULT_GUARDIAN_TTL_AFTER_END_S = 30 * 86400
DEFAULT_MAX_ACTIVE_S = 24 * 3600
_SAVE_EVERY_S = 5


class IncidentStore:
    def __init__(
        self,
        path=None,
        ttl_after_end_s=DEFAULT_TTL_AFTER_END_S,
        max_active_s=DEFAULT_MAX_ACTIVE_S,
        clock=time.time,
        guardian_ttl_after_end_s=DEFAULT_GUARDIAN_TTL_AFTER_END_S,
    ):
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
                    "alerted", "end_sent", "mode", "guardian_code",
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
        existing = self._by_session.get(session)
        if existing is not None and existing.status == "active" and not self.expired(existing):
            return existing, False
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
            mode=mode if mode in ("sos", "live") else "sos",
            guardian_code=guardian_code,
        )
        self._index(incident)
        self.save()
        return incident, True

    def get(self, incident_id):
        return self._by_id.get(incident_id)

    def for_guardian(self, guardian_code):
        found = [
            incident for incident in self._by_id.values()
            if incident.guardian_code == guardian_code and not self.expired(incident)
        ]
        return sorted(found, key=lambda item: item.created_at, reverse=True)

    def get_by_token(self, share_token):
        incident = self._by_token.get(share_token)
        if incident is None or self.expired(incident):
            return None
        return incident

    def add_point(self, incident_id, lat, lon, accuracy=None, ts=None):
        incident = self._by_id.get(incident_id)
        if incident is None:
            return False
        incident.points.append({
            "lat": lat,
            "lon": lon,
            "accuracy": accuracy,
            "ts": ts if ts is not None else time.time(),
        })
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
