"""Muse client over the Meta Model API Chat Completions endpoint.

Docs: https://dev.meta.ai/docs (OpenAI-compatible Chat Completions; auth header built from the key at runtime).
MODEL_API_KEY, Chat Completions documented as the OpenAI-compatible
messages-array endpoint. Vision input as base64 data-URL images, strict JSON
via response_format. Nothing here is invented: shapes follow the documented
OpenAI-compatible contract.
"""

import json
import time

import httpx

SYSTEM_PROMPT = """You are a safety analyst reviewing a short first-person clip. \
Classify visible BEHAVIOUR only: movement, approach, gestures, persistence, \
blocking, following. NEVER consider or mention appearance, identity, age, \
ethnicity, gender presentation, or clothing — if the only thing notable about \
a person is how they look, they are not a threat. Ordinary scenes (people \
standing still, walking past, everyday crowds, someone briefly in view while \
the wearer moves) are low threat: say "stationary, not a threat" or similar \
when nothing threatening is happening. A clip where the camera moves toward \
a motionless person is camera motion, not an approaching person.

Reply with STRICT JSON only, no other text:
{"threat_level": "low|medium|high", "behaviours_observed": ["..."], \
"confidence": 0.0-1.0, "reason": "one short sentence"}"""


class MuseError(Exception):
    pass


class MuseClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        model: str,
        timeout_s: float = 20.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.timeout_s = timeout_s

    def verify(
        self,
        frames_b64: list[str],
        on_device_features: dict,
        sam2_geometry: dict | None,
    ) -> tuple[dict, float]:
        """Returns (strict verdict dict, latency seconds). Raises MuseError."""
        if not self.api_key:
            raise MuseError("META_MODEL_API_KEY is not set")
        context = {
            "on_device_features": on_device_features,
            "sam2_geometry": sam2_geometry or "unavailable (muse-only path)",
        }
        content: list[dict] = [
            {
                "type": "text",
                "text": "On-device context (normalized 0..1, may be noisy): "
                + json.dumps(context),
            }
        ]
        for frame in frames_b64:
            content.append(
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{frame}"},
                }
            )
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": content},
            ],
            "response_format": {"type": "json_object"},
        }
        started = time.monotonic()
        try:
            response = httpx.post(
                f"{self.base_url}/chat/completions",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json=body,
                timeout=self.timeout_s,
            )
        except httpx.TimeoutException as exc:
            raise MuseError(f"Muse call timed out after {self.timeout_s}s") from exc
        except httpx.HTTPError as exc:
            raise MuseError(f"Muse HTTP error: {exc}") from exc
        latency = time.monotonic() - started
        if response.status_code != 200:
            raise MuseError(f"Muse status {response.status_code}: {response.text[:200]}")
        return parse_verdict(response.text), latency


def parse_verdict(raw_body: str) -> dict:
    """Extract and strictly validate the verdict JSON. Raises MuseError."""
    try:
        envelope = json.loads(raw_body)
        content = envelope["choices"][0]["message"]["content"]
        verdict = json.loads(content)
    except (KeyError, IndexError, json.JSONDecodeError, TypeError) as exc:
        raise MuseError(f"Muse returned unparsable JSON: {exc}") from exc
    if not isinstance(verdict, dict):
        raise MuseError("Muse verdict is not a JSON object")
    level = verdict.get("threat_level")
    behaviours = verdict.get("behaviours_observed")
    confidence = verdict.get("confidence")
    reason = verdict.get("reason")
    if level not in ("low", "medium", "high"):
        raise MuseError(f"bad threat_level: {level!r}")
    if not isinstance(behaviours, list) or not all(
        isinstance(b, str) for b in behaviours
    ):
        raise MuseError(f"bad behaviours_observed: {behaviours!r}")
    if not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
        raise MuseError(f"bad confidence: {confidence!r}")
    if not isinstance(reason, str) or not reason:
        raise MuseError("bad reason: must be a non-empty string")
    # Appearance-guard: the model must never smuggle looks-based labels in.
    lowered = " ".join(behaviours + [reason]).lower()
    banned = [
        "wearing",
        "clothes",
        "clothing",
        "dressed",
        "ethnicity",
        "ethnic",
        "skin",
        "age",
        "old man",
        "old woman",
        "young man",
        "young woman",
    ]
    if any(word in lowered for word in banned):
        raise MuseError("verdict mentions appearance; refusing to use it")
    return {
        "threat_level": level,
        "behaviours_observed": behaviours,
        "confidence": float(confidence),
        "reason": reason,
    }
