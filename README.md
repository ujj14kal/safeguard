# safeguard

Safeguard is a personal-safety iOS app for women: it watches for threatening
BEHAVIOURS by people nearby (never appearance or identity), asks the wearer by
voice whether she is safe, and escalates on four parallel tracks if she isn't.
Built for the Meta AI global developer hackathon and pitched as an app for
Meta AI glasses — the glasses are a drop-in `FrameSource` later; the demo runs
on a physical iPhone in a chest/collar mount.

> Foreground-only app: iOS forbids background camera use, so Safeguard
> protects only while open, and keeps the screen awake while protecting.

## Keys and secrets

All API keys and tokens come from environment variables — see `.env.example`
(copy it to `.env` locally and fill it in). Never commit `.env` files or real
credentials; a pre-commit hook (`scripts/pre-commit.sh`) blocks them. Git hooks
are not cloned, so install it once per clone:

```sh
cp scripts/pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

Test the hook itself with `./scripts/test-pre-commit.sh` (fake secrets must be
blocked, code references must pass).

Commit with your GitHub noreply address (`git config user.email
<id>+<username>@users.noreply.github.com`): the repo is public and commit
metadata is public too.

## Layout

- `ios/` — native app (Swift + SwiftUI, iOS 17+, no third-party UI libraries)
- `backend/` — FastAPI service (Python)
- `scripts/` — `build.sh`, `run-sim.sh`, `pre-commit.sh`

## Prerequisites

- Xcode with the **iOS platform** and an **iOS Simulator runtime** installed
  (Xcode → Settings → Platforms). Verify:
  `xcrun simctl list runtimes` should list an iOS runtime.
- A physical iPhone + Apple ID for on-device runs. The Simulator has no
  camera — use Replay mode there (feed a recorded video through the pipeline).
- Python 3.11+ for the backend.

## Run the backend

```sh
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
curl http://127.0.0.1:8000/health   # {"status": "ok"}
```

### Pointing the iPhone at the backend

`127.0.0.1` on a phone is the phone itself, so a real iPhone cannot reach a
backend on `127.0.0.1`. Run the backend with `--host 0.0.0.0` (above), put the
iPhone on the same Wi-Fi as the Mac, then either:

- in the app: **Settings → Debug → Verification backend**, enter
  `http://<your-mac-ip>:8000` and tap **Test connection**; or
- at build time: `BACKEND_BASE_URL=http://<your-mac-ip>:8000 ./scripts/build.sh device`
  (passed to xcodebuild as a build setting).

The first request asks for local-network permission. Plain `http://` is
allowed only for local addresses (`NSAllowsLocalNetworking`); use an `https://`
tunnel URL for anything else. The simulator can keep using `127.0.0.1`.

## App icon and launch screen

The icon, launch logo and splash are generated from `design/logo-source.png`:

```sh
python3 scripts/make-brand-assets.py   # needs Pillow and numpy
```

It rewrites `AppIcon`, `LaunchLogo` and `LaunchBackground` in
`ios/Safeguard/Assets.xcassets`. In debug builds the splash can be skipped with
`defaults write io.github.ujj14kal.safeguard skipSplash -bool YES`.

## Run the app in the Simulator

```sh
./scripts/build.sh simulator     # no signing needed
./scripts/run-sim.sh "iPhone 17" # builds, installs, launches
```

Then: Protect tab → “Replay a video…” → pick a `.mov`/`.mp4` (Simulator has
no camera). Debug builds include a Preview-states screen
(Settings → Debug) rendering every protection state plus mock SOS track
cards. Headless screenshot hooks (debug builds only):

```sh
defaults write io.github.ujj14kal.safeguard debugInitialTab settings
defaults write io.github.ujj14kal.safeguard debugInitialRoute preview-states
```

## Run on your iPhone

1. Open `ios/Safeguard.xcodeproj` in Xcode.
2. Safeguard target → Signing & Capabilities → select your Team
   (a free Apple ID works for local runs).
3. Connect the iPhone, select it as the run destination, Run.
4. First time only: on the iPhone, trust your developer identity under
   Settings → General → VPN & Device Management.
5. On first “Start protecting”, allow camera access.

CLI alternative: `DEVELOPMENT_TEAM=<TeamID> ./scripts/build.sh device`.

## Status

Phase 1 written, **not yet verified in Xcode**: Xcode project, DesignSystem,
`FrameSource` + phone camera + Replay + glasses stub, camera preview, Protect
tab with shield ring, Preview-states screen (debug), backend `/health`, build
scripts. All Swift sources typecheck against the iOS 26.5 SDK, but the app has
not yet been built with `xcodebuild`, run in the Simulator, or run on a device
(the iOS platform/Simulator runtime must be installed first — see
Prerequisites). It becomes "done" once that run succeeds.
Phase 2 written, **not yet verified in Xcode**: `PersonDetector` (Vision human
rectangles) + greedy-IoU `Tracker` with stable IDs, 15 XCTest tests, detection
loop + debug overlay in the app, `scripts/test.sh`. The suite passes on macOS
via SwiftPM on verbatim copies; `xcodebuild test` awaits the same install.
Phase 3 done: `ThreatConfig` (all thresholds/windows/weights), `BodyPose` +
facing score, `FeatureExtractor` (trend, speed, persistence, facing,
isolation, blocking, cornering over explicit second-based windows),
`ThreatScorer` with reasons, pose attached in the detector, scores on the
debug overlay. 45/45 tests pass on the iOS Simulator.
Phase 4 done: display-only proximity colours on the shield (clear/near/
tooClose with holds + hysteresis) and backend `POST /verify` (SAM 2 +
Muse with `muse-only` default after the CPU spike ran 3x over budget;
see DECISIONS.md). The app calls /verify only above the on-device score
threshold. Backend tests: `cd backend && .venv/bin/python -m pytest
tests/ -q` (15 passed, 1 skipped; the skipped e2e needs a real SAM 2
checkpoint + `SAM2_MODE=sam2`). 69/69 iOS tests pass on the Simulator.
Next: Phase 5 (audio loop + state machine + check-in screen).
