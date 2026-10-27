"""Tests for POST /verify-speech: strict JSON, guards, fallback, privacy."""

import httpx

from app import main
from app.ratelimit import RateLimiter
from tests.conftest import FakeResponse, muse_envelope


def speech_request(**overrides):
    body = {
        "snippet": "Come with me, don't make a scene.",
        "on_device": {"severity": 0.9, "category": "coercion"},
    }
    body.update(overrides)
    return body


def speech_verdict(**overrides):
    verdict = {
        "severity": "high",
        "categories": ["coercion"],
        "directed_at_wearer": True,
        "reason": "Direct order to follow, aimed at the wearer.",
    }
    verdict.update(overrides)
    return verdict


def test_happy_path(client, monkeypatch):
    def good_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(speech_verdict()))

    monkeypatch.setattr("app.muse.httpx.post", good_post)
    response = client.post("/verify-speech", json=speech_request())
    assert response.status_code == 200
    assert response.json() == speech_verdict()


def test_snippet_reaches_muse_prompt(client, monkeypatch):
    seen: dict = {}

    def spy_post(url, headers=None, json=None, timeout=None):
        seen["messages"] = json["messages"]
        return FakeResponse(muse_envelope(speech_verdict()))

    monkeypatch.setattr("app.muse.httpx.post", spy_post)
    client.post("/verify-speech", json=speech_request(snippet="unique marker words"))
    user_text = seen["messages"][1]["content"]
    assert "unique marker words" in user_text
    assert "coercion" in user_text  # on-device context also passed


def test_muse_can_downgrade(client, monkeypatch):
    low = speech_verdict(
        severity="low",
        categories=[],
        directed_at_wearer=False,
        reason="Quoting a film line, not directed at the wearer.",
    )

    def low_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(low))

    monkeypatch.setattr("app.muse.httpx.post", low_post)
    response = client.post(
        "/verify-speech",
        json=speech_request(
            snippet='She said "come with me" in the film.',
            on_device={"severity": 0.9, "category": "coercion"},
        ),
    )
    assert response.json()["severity"] == "low"


def test_strict_json_rejection(client, monkeypatch):
    def garbage_post(url, headers=None, json=None, timeout=None):
        return FakeResponse('{"choices": []}')

    monkeypatch.setattr("app.muse.httpx.post", garbage_post)
    assert client.post("/verify-speech", json=speech_request()).status_code == 503


def test_bad_types_rejected(client, monkeypatch):
    bad = speech_verdict(directed_at_wearer="yes", severity="extreme")

    def bad_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(bad))

    monkeypatch.setattr("app.muse.httpx.post", bad_post)
    assert client.post("/verify-speech", json=speech_request()).status_code == 503


def test_appearance_wording_is_redacted_not_fatal(client, monkeypatch):
    bad = speech_verdict(
        reason="A man wearing a red shirt is shouting.", categories=["threat", "red shirt"]
    )

    def bad_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(bad))

    monkeypatch.setattr("app.muse.httpx.post", bad_post)
    response = client.post("/verify-speech", json=speech_request())
    assert response.status_code == 200
    body = response.json()
    assert "shirt" not in body["reason"] and "man" not in body["reason"].split()
    assert body["categories"] == ["threat"]
    assert body["severity"] == bad["severity"]


def test_timeout_maps_to_503(client, monkeypatch):
    def slow_post(url, headers=None, json=None, timeout=None):
        raise httpx.TimeoutException("too slow")

    monkeypatch.setattr("app.muse.httpx.post", slow_post)
    assert client.post("/verify-speech", json=speech_request()).status_code == 503


def test_speech_has_its_own_rate_limit(client, monkeypatch):
    def good_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(speech_verdict()))

    monkeypatch.setattr("app.muse.httpx.post", good_post)
    monkeypatch.setattr(main, "_speech_limiter", RateLimiter(2))
    assert client.post("/verify-speech", json=speech_request()).status_code == 200
    assert client.post("/verify-speech", json=speech_request()).status_code == 200
    limited = client.post("/verify-speech", json=speech_request())
    assert limited.status_code == 429


def test_exhausted_verify_budget_does_not_block_speech(client, monkeypatch):
    def good_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(speech_verdict()))

    monkeypatch.setattr("app.muse.httpx.post", good_post)
    monkeypatch.setattr(main, "_muse_limiter", RateLimiter(0))
    monkeypatch.setattr(main, "_speech_limiter", RateLimiter(5))
    assert client.post("/verify-speech", json=speech_request()).status_code == 200


def test_snippet_length_limits(client):
    assert client.post("/verify-speech", json=speech_request(snippet="")).status_code == 422
    assert (
        client.post("/verify-speech", json=speech_request(snippet="x" * 2001)).status_code
        == 422
    )


def test_transcript_never_in_logs(client, monkeypatch):
    def good_post(url, headers=None, json=None, timeout=None):
        return FakeResponse(muse_envelope(speech_verdict()))

    monkeypatch.setattr("app.muse.httpx.post", good_post)
    marker = "quixotic platypus murmur"
    client.post("/verify-speech", json=speech_request(snippet=marker))
    with open("/tmp/sg-test-verify.jsonl") as handle:
        logged = handle.read()
    assert marker not in logged
    assert '"severity": "high"' in logged
    assert '"endpoint": "verify-speech"' in logged
    assert "muse_latency_ms" in logged
