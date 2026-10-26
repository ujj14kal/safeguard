"""Verdict parsing and the appearance guard.

The guard must refuse looks-based wording but never refuse ordinary behaviour
verdicts. Fake data only.
"""

import json

import pytest

from app.muse import MuseError, mentions_appearance, parse_verdict


def envelope(reason: str, behaviours=("stationary",), level: str = "low") -> str:
    verdict = {
        "threat_level": level,
        "behaviours_observed": list(behaviours),
        "confidence": 0.8,
        "reason": reason,
    }
    return json.dumps({"choices": [{"message": {"content": json.dumps(verdict)}}]})


# Wording a model will plausibly use. Several contain "age" or "man" INSIDE
# another word, which the old substring check wrongly refused.
CLEAN_REASONS = [
    "A person is standing still while the camera moves toward them.",
    "No approach is visible across the image sequence.",
    "Person stays in the same place in all images.",
    "Person appears to manage a stall and gestures to customers.",
    "Person keeps an average distance and does not close in.",
    "Person is engaged in a phone call and not approaching.",
    "Person walks past without changing direction.",
    "The message on the sign is irrelevant; nobody is following.",
    "Crowd at a crossing, no one is blocking the way.",
    "Person is human-sized in frame and stays at the edge of the stage.",
    "Someone follows at a steady pace for the whole clip.",
]

APPEARANCE_REASONS = [
    "A man wearing a red shirt is approaching.",
    "A young woman is walking behind the wearer.",
    "An old man is standing close.",
    "The person looks about thirty, aged 30 to 40.",
    "An elderly person is following.",
    "A teenager keeps pace with the wearer.",
    "Dark skin and a hoodie, moving closer.",
    "Their ethnicity makes the behaviour suspicious.",
    "A girl in a skirt blocks the path.",
    "Person wore a jacket and is approaching fast.",
    "A guy with a beard stands close.",
]


@pytest.mark.parametrize("reason", CLEAN_REASONS)
def test_ordinary_behaviour_wording_is_accepted(reason):
    verdict = parse_verdict(envelope(reason))
    assert verdict["reason"] == reason
    assert mentions_appearance(reason) is None


@pytest.mark.parametrize("reason", APPEARANCE_REASONS)
def test_appearance_wording_is_refused(reason):
    assert mentions_appearance(reason) is not None
    with pytest.raises(MuseError, match="appearance"):
        parse_verdict(envelope(reason))


def test_appearance_in_behaviour_list_is_refused():
    with pytest.raises(MuseError, match="appearance"):
        parse_verdict(envelope("Person approaches quickly.", behaviours=["wearing a coat"]))


def test_appearance_words_inside_other_words_are_not_matched():
    for text in ("image", "images", "manage", "average", "engaged", "message", "stage", "page"):
        assert mentions_appearance(text) is None, text


def test_refusal_names_the_term():
    with pytest.raises(MuseError, match="'wearing'"):
        parse_verdict(envelope("Someone wearing gloves approaches."))
