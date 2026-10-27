"""SOS incidents: share tokens, one alert burst, location trail.

In-memory on purpose for the demo: a restart drops active incidents (the
evidence files and contact links on disk survive). The 500-point trail cap
bounds memory per incident.
"""

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
    status: str = "active"
    points: deque = field(default_factory=lambda: deque(maxlen=MAX_POINTS))
    created_at: float = field(default_factory=time.time)
    ended_at: float = 0
    alerted: bool = False
    end_sent: bool = False

    def latest(self):
        return self.points[-1] if self.points else None


class IncidentStore:
    def __init__(self):
        self._by_id = {}
        self._by_session = {}
        self._by_token = {}

    def start(self, session, wearer_name, contact_codes, test=False, dry_run=True):
        """Creates an incident — unless this session already has an active
        one, in which case the existing incident is returned and NO new
        alert burst goes out. Returns (incident, fresh)."""
        existing = self._by_session.get(session)
        if existing is not None and existing.status == "active":
            return existing, False
        incident = Incident(
            id=make_incident_id(),
            session=session,
            wearer_name=wearer_name,
            contact_codes=list(contact_codes),
            share_token=make_share_token(),
            test=test,
            dry_run=dry_run,
        )
        self._by_id[incident.id] = incident
        self._by_session[session] = incident
        self._by_token[incident.share_token] = incident
        return incident, True

    def get(self, incident_id):
        return self._by_id.get(incident_id)

    def get_by_token(self, share_token):
        return self._by_token.get(share_token)

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
        return True

    def end(self, incident_id):
        incident = self._by_id.get(incident_id)
        if incident is None or incident.status != "active":
            return None
        incident.status = "ended"
        incident.ended_at = time.time()
        return incident
