"""Contact store + getUpdates linking (no network, no webhook)."""

import json

import pytest

from app import contacts
from app.contacts import ContactStore, link_from_updates


def test_invite_persists_a_code(tmp_path):
    store = ContactStore(
        path=str(tmp_path / "contacts.json"),
    )
    record = store.invite("Meera")
    assert record["name"] == "Meera"
    assert len(record["code"]) >= 6
    assert record["chat_id"] is None
    saved = json.loads(open(tmp_path / "contacts.json").read())
    assert saved["contacts"][0]["code"] == record["code"]
    assert ContactStore(path=str(tmp_path / "contacts.json")).get(record["code"]) == record


def test_invite_trims_names_and_rejects_empty(tmp_path):
    store = ContactStore(
        path=str(tmp_path / "contacts.json"),
    )
    assert store.invite("  Arjun   Rao  ")["name"] == "Arjun Rao"
    with pytest.raises(ValueError):
        store.invite("   ")


def test_max_five_contacts(tmp_path):
    store = ContactStore(
        path=str(tmp_path / "contacts.json"),
    )
    for index in range(5):
        store.invite(f"Friend {index}")
    with pytest.raises(contacts.ContactLimitError):
        store.invite("One too many")


def test_link_and_get(tmp_path):
    store = ContactStore(
        path=str(tmp_path / "contacts.json"),
    )
    record = store.invite("Meera")
    assert store.link(record["code"], 777)["chat_id"] == 777
    assert store.get(record["code"])["chat_id"] == 777
    assert store.get("nope") is None
    assert store.link("nope", 1) is None


def test_corrupt_file_starts_empty(tmp_path):
    path = tmp_path / "contacts.json"
    path.write_text("not json{{{")
    assert ContactStore(path=str(path)).contacts == []


def updates(*messages):
    return {
        "ok": True,
        "result": [
            {
                "update_id": 100 + index,
                "message": {"chat": {"id": chat}, "text": text},
            }
            for index, (chat, text) in enumerate(messages)
        ],
    }


def test_start_command_links(tmp_path):
    store = ContactStore(
        path=str(tmp_path / "contacts.json"),
    )
    record = store.invite("Meera")
    linked, offset = link_from_updates(
        updates((777, f"/start {record['code']}")),
        store,
    )
    assert linked == [record["code"]]
    assert offset == 101
    assert store.get(record["code"])["chat_id"] == 777


def test_unknown_code_and_chatter_ignored(tmp_path):
    store = ContactStore(
        path=str(tmp_path / "contacts.json"),
    )
    record = store.invite("Meera")
    linked, offset = link_from_updates(
        updates(
            (1, "/start wrongcode"),
            (2, "hello bot"),
            (3, "/start"),
            (None, f"/start {record['code']}"),
        ),
        store,
    )
    assert linked == []
    assert offset == 104
    assert store.get(record["code"])["chat_id"] is None


def test_malformed_payload_is_safe(tmp_path):
    store = ContactStore(
        path=str(tmp_path / "contacts.json"),
    )
    assert link_from_updates({}, store) == ([], None)
    assert link_from_updates({"result": "junk"}, store) == ([], None)
    assert link_from_updates({"result": [None, 42]}, store) == ([], None)


def test_invite_link_shape():
    assert contacts.invite_link("demo_bot", "abc123") == "https://t.me/demo_bot?start=abc123"
