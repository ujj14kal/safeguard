"""Accounts: Supabase relay, profile rows, validation, auth guards.

A fake `_call` plays Supabase; no network. Passwords and tokens are built
at runtime so no secret-looking literal sits in the repo.
"""

import pytest
from fastapi.testclient import TestClient

from app import accounts as accounts_mod
from app import main
from app.accounts import SupabaseAccounts
from app.config import Settings
from app.ratelimit import RateLimiter

USER_ID = "11111111-2222-3333-4444-555555555555"
GOOD_PW = "Zebra" + "-" * 1 + "crossing7"
URL = "https://example-project.supabase.test"


class FakeSupabase:
    """Records calls and answers like Supabase would."""

    def __init__(self):
        self.calls: list[dict] = []
        self.profiles: dict[str, dict] = {}
        self.users: dict[str, str] = {}  # email -> password
        self.confirm_email = False
        self.down = False

    def __call__(self, method, url, *, headers, json=None, params=None, timeout=10.0):
        self.calls.append(
            {"method": method, "url": url, "headers": headers, "json": json, "params": params}
        )
        if self.down:
            raise accounts_mod.AccountsError(503, "account service unreachable")
        path = url.replace(URL, "")
        if path == "/auth/v1/signup":
            email = json["email"]
            if email in self.users:
                return 422, {"msg": "User already registered"}
            self.users[email] = json["password"]
            user = {"id": USER_ID, "email": email, "user_metadata": json["data"]}
            if self.confirm_email:
                return 200, user
            return 200, {
                "access_token": "acc-1", "refresh_token": "ref-1-xxxxxxxx",
                "expires_in": 3600, "user": user,
            }
        if path == "/auth/v1/token" and params["grant_type"] == "password":
            if self.users.get(json["email"]) != json["password"]:
                return 400, {"error_description": "Invalid login credentials"}
            return 200, {
                "access_token": "acc-2", "refresh_token": "ref-2-xxxxxxxx", "expires_in": 3600,
                "user": {"id": USER_ID, "email": json["email"], "user_metadata": {"name": "Asha"}},
            }
        if path == "/auth/v1/token" and params["grant_type"] == "refresh_token":
            if json["refresh_token"] != "ref-2-xxxxxxxx":
                return 400, {"error": "invalid_grant"}
            return 200, {"access_token": "acc-3", "refresh_token": "ref-3-xxxxxxxx", "expires_in": 3600}
        if path == "/auth/v1/user":
            if headers["Authorization"] not in ("Bearer acc-1", "Bearer acc-2", "Bearer acc-3"):
                return 401, {"msg": "bad jwt"}
            return 200, {"id": USER_ID, "email": "asha@example.test"}
        if path == "/auth/v1/logout":
            return 204, {}
        if path.startswith("/auth/v1/admin/users/"):
            return 200, {}
        if path == "/rest/v1/profiles":
            return self._profiles(method, json, params)
        return 404, {}

    def _profiles(self, method, json, params):
        if method == "POST":
            row = {**self.profiles.get(json["id"], {}), **json, "created_at": "2026-10-27T00:00:00Z"}
            self.profiles[json["id"]] = row
            return 201, [row]
        uid = params["id"].replace("eq.", "")
        if method == "GET":
            return 200, [self.profiles[uid]] if uid in self.profiles else []
        if method == "PATCH":
            if uid not in self.profiles:
                return 200, []
            self.profiles[uid].update(json)
            return 200, [self.profiles[uid]]
        if method == "DELETE":
            self.profiles.pop(uid, None)
            return 204, {}
        return 404, {}


@pytest.fixture()
def fake(monkeypatch):
    sb = FakeSupabase()
    monkeypatch.setattr(accounts_mod, "_call", sb)
    anon, service = "anon-" + "a" * 10, "service-" + "b" * 10
    monkeypatch.setattr(main, "_accounts_override", SupabaseAccounts(URL, anon, service))
    monkeypatch.setattr(main, "_auth_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "SETTINGS", Settings(app_token=""))
    return sb


@pytest.fixture()
def api(fake):
    return TestClient(main.app)


def signup_body(**over):
    body = {
        "email": "Asha@Example.test", "password": GOOD_PW, "name": "  Asha   Rao ",
        "phone": "+1 555 0101", "language": "hi", "consent": True,
    }
    body.update(over)
    return body


def test_signup_creates_user_and_profile(api, fake):
    res = api.post("/auth/signup", json=signup_body())
    assert res.status_code == 200
    out = res.json()
    assert out["user"]["email"] == "asha@example.test"
    assert out["user"]["name"] == "Asha Rao"
    assert out["user"]["language"] == "hi"
    assert out["session"]["access_token"] == "acc-1"
    assert out["needs_confirmation"] is False
    row = fake.profiles[USER_ID]
    assert row["phone"] == "+1 555 0101" and row["consent_at"]


def test_signup_with_email_confirmation_returns_no_session(api, fake):
    fake.confirm_email = True
    out = api.post("/auth/signup", json=signup_body()).json()
    assert out["session"] is None and out["needs_confirmation"] is True
    assert USER_ID in fake.profiles


def test_signup_needs_consent_and_good_input(api):
    assert api.post("/auth/signup", json=signup_body(consent=False)).status_code == 422
    assert api.post("/auth/signup", json=signup_body(email="nope")).status_code == 422
    assert api.post("/auth/signup", json=signup_body(phone="abc")).status_code == 422
    too_short = "Ab" + "1"
    short = api.post("/auth/signup", json=signup_body(password=too_short))
    assert short.status_code == 422 and "characters" in short.json()["detail"]
    all_lower = "alllower" + "case1"
    flat = api.post("/auth/signup", json=signup_body(password=all_lower))
    assert flat.status_code == 422


def test_duplicate_email_is_409(api):
    assert api.post("/auth/signup", json=signup_body()).status_code == 200
    assert api.post("/auth/signup", json=signup_body()).status_code == 409


def test_login_refresh_me_flow(api, fake):
    api.post("/auth/signup", json=signup_body())
    login = api.post("/auth/login", json={"email": "asha@example.test", "password": GOOD_PW})
    assert login.status_code == 200
    token = login.json()["session"]["access_token"]
    auth = {"Authorization": f"Bearer {token}"}
    me = api.get("/me", headers=auth).json()
    assert me["name"] == "Asha Rao" and me["id"] == USER_ID
    upd = api.put("/me", json={"name": "Asha R", "language": "en"}, headers=auth)
    assert upd.status_code == 200 and upd.json()["name"] == "Asha R"
    refreshed = api.post("/auth/refresh", json={"refresh_token": "ref-2-xxxxxxxx"})
    assert refreshed.json()["session"]["access_token"] == "acc-3"


def test_wrong_password_is_401(api):
    api.post("/auth/signup", json=signup_body())
    bad = api.post("/auth/login", json={"email": "asha@example.test", "password": "wrong-Pass1"})
    assert bad.status_code == 401


def test_login_creates_missing_profile_row(api, fake):
    api.post("/auth/signup", json=signup_body())
    fake.profiles.clear()
    api.post("/auth/login", json={"email": "asha@example.test", "password": GOOD_PW})
    assert USER_ID in fake.profiles


def test_me_requires_a_valid_bearer(api):
    assert api.get("/me").status_code == 401
    assert api.get("/me", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_delete_account_removes_profile_and_user(api, fake):
    api.post("/auth/signup", json=signup_body())
    token = api.post(
        "/auth/login", json={"email": "asha@example.test", "password": GOOD_PW}
    ).json()["session"]["access_token"]
    res = api.delete("/me", headers={"Authorization": f"Bearer {token}"})
    assert res.json() == {"deleted": True}
    assert USER_ID not in fake.profiles
    assert any(c["url"].endswith(f"/auth/v1/admin/users/{USER_ID}") for c in fake.calls)


def test_app_token_guards_every_route(fake, monkeypatch):
    want = "t" * 12
    monkeypatch.setattr(main, "SETTINGS", Settings(app_token=want))
    client = TestClient(main.app)
    assert client.post("/auth/signup", json=signup_body()).status_code == 401
    assert client.post("/auth/login", json={"email": "a@b.co", "password": "x"}).status_code == 401
    assert client.get("/me").status_code == 401
    ok = client.post("/auth/signup", json=signup_body(), headers={"X-Safeguard-Token": want})
    assert ok.status_code == 200


def test_not_configured_is_503(monkeypatch):
    monkeypatch.setattr(main, "_accounts_override", None)
    monkeypatch.setattr(main, "_auth_limiter", RateLimiter(1000))
    monkeypatch.setattr(main, "SETTINGS", Settings(supabase_url="", app_token=""))
    res = TestClient(main.app).post("/auth/signup", json=signup_body())
    assert res.status_code == 503


def test_unreachable_supabase_is_503(api, fake):
    fake.down = True
    assert api.post("/auth/signup", json=signup_body()).status_code == 503


def test_auth_rate_limit(api, monkeypatch):
    monkeypatch.setattr(main, "_auth_limiter", RateLimiter(2))
    for _ in range(2):
        api.post("/auth/login", json={"email": "a@b.co", "password": "x"})
    assert api.post("/auth/login", json={"email": "a@b.co", "password": "x"}).status_code == 429


def test_secrets_stay_in_headers_not_in_responses(api, fake):
    out = api.post("/auth/signup", json=signup_body()).text
    assert "service-" not in out and "anon-" not in out and GOOD_PW not in out
    for call in fake.calls:
        if "/rest/v1/" in call["url"]:
            assert call["headers"]["apikey"].startswith("service-")


def test_password_helper():
    assert accounts_mod.password_problem("Abcdefg1") is None
    assert accounts_mod.password_problem("x" * 80) is not None
