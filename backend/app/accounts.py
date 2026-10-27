"""User accounts on Supabase.

Supabase Auth keeps the credentials (passwords are never stored or logged
here); this backend relays sign-up / sign-in so the Supabase keys stay on
the server, and keeps the user's profile (name, phone, language, consent)
in a `profiles` table written with the service-role key.

Every call goes through `_call`, the one place that talks HTTP, so tests
replace it. Nothing here logs request bodies, passwords or tokens.
"""

import logging
import re
from dataclasses import dataclass

import httpx

logger = logging.getLogger("safeguard.accounts")

_EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")
_PHONE_RE = re.compile(r"^\+?[0-9][0-9 \-]{6,18}$")
_UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")

MIN_PASSWORD_LEN = 8
MAX_PASSWORD_LEN = 72
PROFILE_FIELDS = ("name", "phone", "language")


class AccountsError(Exception):
    """A failure with a status the endpoint can return as-is."""

    def __init__(self, status_code: int, message: str):
        super().__init__(message)
        self.status_code = status_code
        self.message = message


class AccountsNotConfigured(AccountsError):
    def __init__(self) -> None:
        super().__init__(503, "accounts are not configured on this server")


def valid_email(email: str) -> bool:
    return bool(_EMAIL_RE.match(email.strip()))


def valid_phone(phone: str) -> bool:
    return bool(_PHONE_RE.match(phone.strip()))


def password_problem(password: str) -> str | None:
    """Plain-language reason a password is rejected, or None."""
    if len(password) < MIN_PASSWORD_LEN:
        return f"use at least {MIN_PASSWORD_LEN} characters"
    if len(password) > MAX_PASSWORD_LEN:
        return f"use at most {MAX_PASSWORD_LEN} characters"
    if password.lower() == password or not any(c.isdigit() for c in password):
        return "mix upper and lower case letters and add a number"
    return None


def clean_profile(fields: dict) -> dict:
    """Only the profile columns, trimmed; empty phone becomes None."""
    out: dict = {}
    for key in PROFILE_FIELDS:
        if key not in fields or fields[key] is None:
            continue
        value = str(fields[key]).strip()
        out[key] = value or None if key == "phone" else value
    return out


@dataclass
class Session:
    access_token: str
    refresh_token: str
    expires_in: int

    def as_dict(self) -> dict:
        return {
            "access_token": self.access_token,
            "refresh_token": self.refresh_token,
            "expires_in": self.expires_in,
        }


def _call(method, url, *, headers, json=None, params=None, timeout=10.0):
    """The only HTTP call. Returns (status_code, parsed json or {})."""
    try:
        response = httpx.request(
            method, url, headers=headers, json=json, params=params, timeout=timeout
        )
    except httpx.HTTPError as exc:
        logger.warning("supabase unreachable: %s", type(exc).__name__)
        raise AccountsError(503, "account service unreachable") from exc
    try:
        body = response.json()
    except ValueError:
        body = {}
    return response.status_code, body if isinstance(body, (dict, list)) else {}


def _message(body) -> str:
    if isinstance(body, dict):
        for key in ("msg", "message", "error_description", "error"):
            if isinstance(body.get(key), str):
                return body[key]
    return ""


class SupabaseAccounts:
    def __init__(self, url: str, anon_key: str, service_key: str):
        if not (url and anon_key and service_key):
            raise AccountsNotConfigured()
        self.url = url.rstrip("/")
        self._anon = anon_key
        self._service = service_key

    # -- header helpers (keys only ever leave in headers, never logged) --

    def _anon_headers(self, bearer: str | None = None) -> dict:
        return {
            "apikey": self._anon,
            "Authorization": f"Bearer {bearer or self._anon}",
            "Content-Type": "application/json",
        }

    def _service_headers(self, prefer: str | None = None) -> dict:
        headers = {
            "apikey": self._service,
            "Authorization": f"Bearer {self._service}",
            "Content-Type": "application/json",
        }
        if prefer:
            headers["Prefer"] = prefer
        return headers

    # -- auth --

    def sign_up(self, email: str, password: str, profile: dict) -> tuple[dict, Session | None]:
        code, body = _call(
            "POST", f"{self.url}/auth/v1/signup",
            headers=self._anon_headers(),
            json={"email": email, "password": password, "data": profile},
        )
        if code in (400, 409, 422):
            text = _message(body).lower()
            if "already" in text or "registered" in text:
                raise AccountsError(409, "an account with this email already exists")
            if "password" in text:
                raise AccountsError(422, "that password is too weak")
            raise AccountsError(422, "could not create the account with those details")
        if code == 429:
            raise AccountsError(429, "too many attempts, wait a minute")
        if code >= 300 or not isinstance(body, dict):
            raise AccountsError(503, "account service error")
        user = body.get("user") if isinstance(body.get("user"), dict) else body
        if not isinstance(user.get("id"), str) or not _UUID_RE.match(user["id"]):
            raise AccountsError(503, "account service returned no user")
        session = self._session(body) if body.get("access_token") else None
        return user, session

    def sign_in(self, email: str, password: str) -> tuple[dict, Session]:
        code, body = _call(
            "POST", f"{self.url}/auth/v1/token", params={"grant_type": "password"},
            headers=self._anon_headers(), json={"email": email, "password": password},
        )
        if code in (400, 401, 422):
            raise AccountsError(401, "wrong email or password")
        if code == 429:
            raise AccountsError(429, "too many attempts, wait a minute")
        if code >= 300 or not isinstance(body, dict) or not body.get("access_token"):
            raise AccountsError(503, "account service error")
        user = body.get("user") if isinstance(body.get("user"), dict) else {}
        return user, self._session(body)

    def refresh(self, refresh_token: str) -> Session:
        code, body = _call(
            "POST", f"{self.url}/auth/v1/token", params={"grant_type": "refresh_token"},
            headers=self._anon_headers(), json={"refresh_token": refresh_token},
        )
        if code in (400, 401, 403, 422):
            raise AccountsError(401, "session expired, sign in again")
        if code >= 300 or not isinstance(body, dict) or not body.get("access_token"):
            raise AccountsError(503, "account service error")
        return self._session(body)

    def user_for(self, access_token: str) -> dict:
        """The signed-in user for an access token (Supabase validates it)."""
        code, body = _call(
            "GET", f"{self.url}/auth/v1/user", headers=self._anon_headers(access_token)
        )
        if code in (401, 403):
            raise AccountsError(401, "session expired, sign in again")
        if code >= 300 or not isinstance(body, dict) or not isinstance(body.get("id"), str):
            raise AccountsError(503, "account service error")
        return body

    def sign_out(self, access_token: str) -> None:
        _call(
            "POST", f"{self.url}/auth/v1/logout", headers=self._anon_headers(access_token)
        )

    def delete_user(self, user_id: str) -> None:
        if not _UUID_RE.match(user_id):
            raise AccountsError(422, "bad user id")
        # Profile rows cascade from auth.users, but delete explicitly too.
        self._profile_call("DELETE", {"id": f"eq.{user_id}"})
        code, _ = _call(
            "DELETE", f"{self.url}/auth/v1/admin/users/{user_id}",
            headers=self._service_headers(),
        )
        if code >= 300 and code != 404:
            raise AccountsError(503, "could not delete the account")

    # -- profile rows --

    def _profile_call(self, method, params, json=None, prefer=None):
        return _call(
            method, f"{self.url}/rest/v1/profiles",
            headers=self._service_headers(prefer), params=params, json=json,
        )

    def upsert_profile(
        self, user_id: str, email: str, fields: dict, consent_at: str | None = None
    ) -> dict:
        if not _UUID_RE.match(user_id):
            raise AccountsError(422, "bad user id")
        row = {"id": user_id, "email": email, **clean_profile(fields)}
        if consent_at:
            row["consent_at"] = consent_at
        code, body = _call(
            "POST", f"{self.url}/rest/v1/profiles",
            headers=self._service_headers("resolution=merge-duplicates,return=representation"),
            params={"on_conflict": "id"}, json=row,
        )
        if code >= 300:
            raise AccountsError(503, "could not save the profile")
        return body[0] if isinstance(body, list) and body else row

    def get_profile(self, user_id: str) -> dict | None:
        if not _UUID_RE.match(user_id):
            raise AccountsError(422, "bad user id")
        code, body = self._profile_call("GET", {"id": f"eq.{user_id}", "select": "*"})
        if code >= 300:
            raise AccountsError(503, "could not read the profile")
        return body[0] if isinstance(body, list) and body else None

    def update_profile(self, user_id: str, fields: dict) -> dict:
        patch = clean_profile(fields)
        if not patch:
            raise AccountsError(422, "nothing to update")
        code, body = self._profile_call(
            "PATCH", {"id": f"eq.{user_id}"}, json=patch, prefer="return=representation"
        )
        if code >= 300:
            raise AccountsError(503, "could not save the profile")
        if not (isinstance(body, list) and body):
            raise AccountsError(404, "profile not found")
        return body[0]

    @staticmethod
    def _session(body: dict) -> Session:
        return Session(
            access_token=str(body["access_token"]),
            refresh_token=str(body.get("refresh_token", "")),
            expires_in=int(body.get("expires_in", 3600)),
        )
