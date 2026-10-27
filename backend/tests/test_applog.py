"""POST/GET /applog: the debug event log the app writes while testing."""

import json

import pytest
from fastapi.testclient import TestClient

from app import main


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("APPLOG_PATH", str(tmp_path / "app-events.jsonl"))
    return TestClient(main.app), tmp_path / "app-events.jsonl"


def test_stores_events_with_server_time(client):
    c, path = client
    r = c.post("/applog", json={"events": [{"t": 1.5, "kind": "heard", "text": "bachao bachao"}]})
    assert r.status_code == 200 and r.json() == {"stored": 1}
    line = json.loads(path.read_text().splitlines()[0])
    assert line["kind"] == "heard" and line["text"] == "bachao bachao" and "server_ts" in line


def test_tail_returns_latest_events(client):
    c, _ = client
    for i in range(5):
        c.post("/applog", json={"events": [{"kind": "x", "i": i}]})
    events = c.get("/applog", params={"n": 2}).json()["events"]
    assert [e["i"] for e in events] == [3, 4]


def test_long_fields_are_cut_and_batches_are_capped(client):
    c, path = client
    c.post("/applog", json={"events": [{"kind": "heard", "text": "x" * 5000}]})
    assert len(json.loads(path.read_text().splitlines()[0])["text"]) == 600
    too_many = {"events": [{"kind": "x"}] * 201}
    assert c.post("/applog", json=too_many).status_code == 422


def test_empty_log_is_an_empty_list(client):
    c, _ = client
    assert c.get("/applog").json() == {"events": []}
