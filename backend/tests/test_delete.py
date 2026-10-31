
import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.contacts import ContactStore

fake_app_token = "-".join(["not", "a", "real", "app", "token"])


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(
        main,
        "_contact_store",
        ContactStore(
            path=str(tmp_path / "contacts.json"),
        ),
    )
    monkeypatch.setattr(
        main,
        "SETTINGS",
        Settings(
            contacts_path=str(tmp_path / "contacts.json"),
            notify_log_path=str(tmp_path / "notify.jsonl"),
            evidence_dir=str(tmp_path / "evidence"),
            app_token=fake_app_token,
            notify_mode="dry-run",
            public_base_url="https://demo.test",
        ),
    )
    return TestClient(main.app)


def auth_headers():
    return {"X-Safeguard-Token": fake_app_token}


def test_delete_contact_needs_app_token(client):
    code = client.post(
        "/contacts/invite",
        json={"name": "Meera"},
        headers=auth_headers(),
    ).json()["code"]
    assert client.delete(f"/contacts/{code}").status_code == 401
    assert client.delete(
        f"/contacts/{code}",
        headers={"X-Safeguard-Token": "wrong"},
    ).status_code == 401


def test_delete_contact_removes_and_is_idempotent(client):
    code = client.post(
        "/contacts/invite",
        json={"name": "Meera"},
        headers=auth_headers(),
    ).json()["code"]
    first = client.delete(
        f"/contacts/{code}",
        headers=auth_headers(),
    )
    assert first.status_code == 200
    assert first.json() == {"deleted": True}
    assert client.get(
        f"/contacts/{code}",
        headers=auth_headers(),
    ).status_code == 404
    second = client.delete(
        f"/contacts/{code}",
        headers=auth_headers(),
    )
    assert second.status_code == 200
    assert second.json() == {"deleted": False}


def test_delete_contact_rejects_bad_codes(client):
    for bad in ["..", "../x", "a/b", "a b", "x" * 65, "%2e%2e"]:
        response = client.delete(
            f"/contacts/{bad}",
            headers=auth_headers(),
        )
        assert response.status_code in (404, 405, 422), bad


def test_delete_evidence_needs_app_token(client):
    assert client.delete("/evidence/somesession").status_code == 401


def test_delete_evidence_removes_dir_and_is_idempotent(client, tmp_path):
    folder = tmp_path / "evidence" / "somesession1"
    folder.mkdir(parents=True)
    (folder / "video-00000.mp4").write_bytes(b"fake")
    first = client.delete(
        "/evidence/somesession1",
        headers=auth_headers(),
    )
    assert first.status_code == 200
    assert first.json() == {"deleted": True}
    assert not folder.exists()
    second = client.delete(
        "/evidence/somesession1",
        headers=auth_headers(),
    )
    assert second.status_code == 200
    assert second.json() == {"deleted": False}


def test_delete_evidence_rejects_bad_sessions(client):
    for bad in ["..", "../x", "short", "a b", "x" * 65]:
        response = client.delete(
            f"/evidence/{bad}",
            headers=auth_headers(),
        )
        assert response.status_code in (404, 405, 422), bad


def test_delete_evidence_cannot_escape_root(client, tmp_path):
    outside = tmp_path / "outside.txt"
    outside.write_text("keep")
    client.delete(
        "/evidence/..%2f..%2foutside",
        headers=auth_headers(),
    )
    assert outside.read_text() == "keep"
