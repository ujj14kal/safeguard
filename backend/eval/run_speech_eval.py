"""Scores the speech judge on labelled sentences.

  python eval/run_speech_eval.py [--effort low] [--limit N]   (key from the environment)

Reports unsafe-vs-safe accuracy (what the app acts on), a three-way confusion
matrix, the misses, and latency. Uses the same prompt and client as the app.
"""

import argparse
import json
import statistics
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import SETTINGS  # noqa: E402
from app.muse import MuseClient, MuseError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--effort", default=None)
parser.add_argument("--limit", type=int, default=0)
parser.add_argument("--workers", type=int, default=4)
args = parser.parse_args()

cases = [json.loads(line) for line in (Path(__file__).parent / "speech_cases.jsonl").read_text().splitlines() if line.strip()]
if args.limit:
    cases = cases[: args.limit]

client = MuseClient(
    base_url=SETTINGS.meta_model_base_url,
    api_key=SETTINGS.meta_model_api_key,
    model=SETTINGS.muse_model,
    timeout_s=40,
)
client.speech_reasoning_effort = SETTINGS.speech_reasoning_effort
if args.effort:
    client.speech_reasoning_effort = args.effort


def judge(case):
    started = time.monotonic()
    try:
        verdict, _ = client.verify_speech(case["text"], {"severity": 0, "category": "none"})
        return case, verdict["severity"], time.monotonic() - started
    except MuseError as exc:
        return case, f"error:{exc}", time.monotonic() - started


with ThreadPoolExecutor(args.workers) as pool:
    results = list(pool.map(judge, cases))

confusion = Counter()
misses = []
latencies = []
for case, got, took in results:
    confusion[(case["label"], got if not got.startswith("error") else "error")] += 1
    latencies.append(took)
    unsafe_expected = case["label"] != "safe"
    unsafe_got = got in ("medium", "high")
    if unsafe_expected != unsafe_got or (case["label"] == "high" and got != "high" and unsafe_got):
        misses.append((case["label"], got, case["text"]))

total = len(results)
binary_ok = sum(1 for case, got, _ in results if (case["label"] != "safe") == (got in ("medium", "high")))
high_ok = sum(1 for case, got, _ in results if case["label"] == "high" and got == "high")
highs = sum(1 for case, _, _ in results if case["label"] == "high")
print(f"effort={args.effort or 'default'}  cases={total}")
print(f"safe-vs-unsafe accuracy: {binary_ok}/{total} = {100 * binary_ok / total:.0f}%")
print(f"'high' cases rated high : {high_ok}/{highs}")
for label in ("safe", "medium", "high"):
    row = {got: n for (lab, got), n in confusion.items() if lab == label}
    print(f"  expected {label:6} -> {row}")
lat = sorted(latencies)
print(f"latency s: median {statistics.median(lat):.1f}  p90 {lat[int(0.9 * (len(lat) - 1))]:.1f}  max {lat[-1]:.1f}")
for label, got, text in misses:
    print(f"  MISS expected {label:6} got {got:8} | {text}")
