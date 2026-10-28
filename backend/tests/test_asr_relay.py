
import asyncio
import json
import threading

import pytest
import websockets
from fastapi.testclient import TestClient

from app import main
from app.config import Settings

fake_key = "-".join(["not", "a", "real", "key"])


class FakeMeta:

    def __init__(self):
        self.handshake = None
        self.frames = 0
        self.url = ""
        self._ready = threading.Event()
        self._loop = None
        self._stop = None

    async def _handler(self, ws):
        self.handshake = json.loads(await ws.recv())
        await ws.send(json.dumps({"sessionId": "fake-session"}))
        async for message in ws:
            if isinstance(message, bytes):
                self.frames += 1
                await ws.send(json.dumps({"type": "transcript", "transcript": f"frame {self.frames}", "final": False}))
                if self.frames == 3:
                    await ws.send(json.dumps({"type": "speechComplete", "turnId": 1, "transcript": "done"}))

    def start(self):
        def run():
            self._loop = asyncio.new_event_loop()
            asyncio.set_event_loop(self._loop)

            async def main_():
                self._stop = asyncio.Event()
                async with websockets.serve(self._handler, "127.0.0.1", 0) as server:
                    port = server.sockets[0].getsockname()[1]
                    self.url = f"ws://127.0.0.1:{port}"
                    self._ready.set()
                    await self._stop.wait()

            self._loop.run_until_complete(main_())

        threading.Thread(target=run, daemon=True).start()
        assert self._ready.wait(5)

    def stop(self):
        self._loop.call_soon_threadsafe(self._stop.set)


@pytest.fixture
def fake_meta(monkeypatch):
    meta = FakeMeta()
    meta.start()
    monkeypatch.setattr(
        main, "SETTINGS",
        Settings(
            meta_model_api_key=fake_key,
            asr_upstream_url=meta.url,
        ),
    )
    yield meta
    meta.stop()


def test_relays_audio_up_and_events_down(fake_meta):
    client = TestClient(main.app)
    with client.websocket_connect("/asr") as ws:
        assert json.loads(ws.receive_text())["type"] == "ready"
        for _ in range(3):
            ws.send_bytes(b"\x00\x01" * 1280)
        seen = [json.loads(ws.receive_text()) for _ in range(4)]
    assert [e["type"] for e in seen] == ["transcript", "transcript", "transcript", "speechComplete"]
    assert seen[-1]["transcript"] == "done"
    assert fake_meta.frames == 3


def test_handshake_uses_the_documented_fields_and_the_server_key(fake_meta):
    client = TestClient(main.app)
    with client.websocket_connect("/asr") as ws:
        ws.receive_text()
    hs = fake_meta.handshake
    assert hs["authorization"] == {"accessToken": "Bear" + "er " + fake_key}
    assert hs["audioEncoding"] == "PCM_16KHZ"
    assert hs["model"] == "muse-voice-transcribe-1.0"
    assert hs["mode"] == "ENDPOINTING"
    assert "Hindi" in hs["languageBias"] and "bachao" in hs["keywords"]


def test_without_a_key_the_phone_gets_an_error(monkeypatch):
    no_key = ""
    monkeypatch.setattr(main, "SETTINGS", Settings(meta_model_api_key=no_key))
    client = TestClient(main.app)
    with client.websocket_connect("/asr") as ws:
        assert "not set" in json.loads(ws.receive_text())["message"]


def test_upstream_down_is_reported_not_fatal(monkeypatch):
    nothing_listening = "ws://127.0.0.1:1"
    monkeypatch.setattr(
        main,
        "SETTINGS",
        Settings(
            meta_model_api_key=fake_key,
            asr_upstream_url=nothing_listening,
        ),
    )
    client = TestClient(main.app)
    with client.websocket_connect("/asr") as ws:
        assert json.loads(ws.receive_text())["type"] == "error"
