"""SOS incidents: share tokens, one alert burst, location trail.

Incidents are kept in memory AND saved to a JSON file, so a backend restart
in the middle of an SOS does not break the family's live link. Share links
expire: an active incident's link stops working after `max_active_s`, and an
ended incident's link `ttl_after_end_s` after it ended. The 500-point trail
cap bounds memory per incident.
"""

import json
import os
import secrets
import time
from collections import deque
from dataclasses import dataclass, field

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

    def latest(self):
        return self.points[-1] if self.points else None


DEFAULT_TTL_AFTER_END_S = 6 * 3600
DEFAULT_MAX_ACTIVE_S = 24 * 3600
_SAVE_EVERY_S = 5


class IncidentStore:
    def __init__(
        self,
        path=None,
        ttl_after_end_s=DEFAULT_TTL_AFTER_END_S,
        max_active_s=DEFAULT_MAX_ACTIVE_S,
        clock=time.time,
    ):
        self._by_id = {}
        self._by_session = {}
        self._by_token = {}
        self._path = path
        self._ttl_after_end_s = ttl_after_end_s
        self._max_active_s = max_active_s
        self._clock = clock
        self._last_save = 0.0
        self._load()

    # -- expiry ---------------------------------------------------------

    def expired(self, incident) -> bool:
        now = self._clock()
        if incident.status == "ended":
            return now - incident.ended_at > self._ttl_after_end_s
        return now - incident.created_at > self._max_active_s

    # -- persistence ----------------------------------------------------

    def _load(self):
        if not self._path or not os.path.exists(self._path):
            return
        try:
            with open(self._path, encoding="utf-8") as handle:
                records = json.load(handle)
        except (OSError, json.JSONDecodeError):
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
        """Writes all unexpired incidents. Location points call this with
        force=False, which saves at most every few seconds."""
        if not self._path:
            return
        now = self._clock()
        if not force and now - self._last_save < _SAVE_EVERY_S:
            return
        self._last_save = now
        records = []
        for incident in list(self._by_id.values()):
            if self.expired(incident):
                self._by_id.pop(incident.id, None)
                self._by_token.pop(incident.share_token, None)
                if self._by_session.get(incident.session) is incident:
                    self._by_session.pop(incident.session, None)
                continue
            record = {
                key: getattr(incident, key)
                for key in (
                    "id", "session", "wearer_name", "contact_codes", "share_token",
                    "test", "dry_run", "lang", "status", "created_at", "ended_at",
                    "alerted", "end_sent",
                )
            }
            record["points"] = list(incident.points)
            records.append(record)
        try:
            os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)
            tmp = f"{self._path}.tmp"
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(records, handle)
            os.replace(tmp, self._path)
        except OSError:
            pass

    def start(self, session, wearer_name, contact_codes, test=False, dry_run=True, lang="en"):
        """Creates an incident — unless this session already has an active
        one, in which case the existing incident is returned and NO new
        alert burst goes out. Returns (incident, fresh)."""
        existing = self._by_session.get(session)
        if existing is not None and existing.status == "active" and not self.expired(existing):
            return existing, False
        incident = Incident(
            id=make_incident_id(),
            session=session,
            wearer_name=wearer_name,
            contact_codes=list(contact_codes),
            share_token=make_share_token(),
            test=test,
            dry_run=dry_run,
            lang=lang if lang in ("en", "hi") else "en",
            created_at=self._clock(),
        )
        self._index(incident)
        self.save()
        return incident, True

    def get(self, incident_id):
        return self._by_id.get(incident_id)

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
