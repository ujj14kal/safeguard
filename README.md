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
curl http://127.0.0.1:8000/health   # {"status": "ok", "muse_configured": true}
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

## Third-party components

- **MediaPipe Tasks Vision** and its `gesture_recognizer.task` and
  `face_landmarker.task` models: Google, Apache-2.0
  (https://github.com/google-ai-edge/mediapipe). Prebuilt frameworks are
  pinned in `ios/Packages/MediaPipeTasks`; models are in `ios/Safeguard/Models`.
- Meta's Muse models run on the backend (never bundled).

## Accounts (Supabase)

Optional sign-up/sign-in; the app works without an account. The phone talks
only to this backend (`/auth/signup`, `/auth/login`, `/auth/refresh`,
`/auth/logout`, `/me`); the backend talks to Supabase, so no Supabase key is
ever in the app. Passwords go straight to Supabase Auth and are never stored
or logged here; the profile (name, email, optional phone, language, consent
time) is one row in `public.profiles`.

1. In the Supabase dashboard, open the **Safeguard** project's SQL editor and
   run `supabase/migrations/20261027000000_profiles.sql` (or `supabase link`
   then `supabase db push`). It enables row level security.
2. Project Settings -> API: copy the URL, the anon key and the service-role
   key into the environment (or your git-ignored `.env`) as `SUPABASE_URL`,
   `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`. Restart the backend.
3. Authentication -> Providers -> Email: turn "Confirm email" OFF for quick
   demos, or leave it on (the app then asks the user to open the email link
   and sign in).
4. Set `SAFEGUARD_APP_TOKEN` too: every account route also needs it.

Without these three variables the account routes answer 503 and the app says
accounts are unavailable and lets the user continue without one.

## Conversation listener (opt-in, default OFF)

When switched on (onboarding, or Settings), Safeguard transcribes speech
near the wearer to notice threatening, harassing or coercive talk. Privacy
rules, enforced in code, not just policy:

- Transcription is on-device only (`requiresOnDeviceRecognition`); if the
  device cannot do it on-device, the listener reports deaf instead of
  uploading audio.
- Raw audio is never written to disk and never sent anywhere.
- Transcript text lives only in a ~20 s in-memory window, discarded on stop.
- Only on a trigger, a short TEXT snippet (trigger sentence + context) goes
  to `POST /verify-speech`; the backend logs counts/latency/severity, never
  transcript text.
- Your safety code phrases work without the toggle: with it off, transcripts
  are scanned for code phrases and voice commands, then dropped immediately.

Recording laws differ by country: check yours before switching this on.

Staying quiet when you feel uneasy is a recommendation, not a requirement:
it helps the microphone hear your surroundings instead of you, but it is
not always possible or safe. If you need help right away, say your unsafe
phrase at any time — it works even mid-sentence, with the toggle on or off.

## SOS escalation (Phase 6)

When the check-in goes unanswered, the unsafe phrase is heard, or a
distress word survives its countdown, four tracks start in parallel: a
safest-route map (nearest staffed/public places by walking ETA —
documented in DECISIONS.md, not a crime-risk model), contact alerts with a
live link, a live video + location page for family, and a clearly labelled
DEMO cab sheet. Integrated police alerts are roadmap; the SOS screen has a
"Call 112" button the wearer taps herself.

### Demo end to end

1. **Backend env** (see `.env.example`): set `SAFEGUARD_APP_TOKEN` first —
   the tunnel below exposes the backend, and without the token every app
   endpoint is open. Keep `NOTIFY_MODE` empty for dry-run (alerts land in
   `backend/logs/notifications.jsonl`, nothing is sent), or set it to
   `telegram` plus `TELEGRAM_BOT_TOKEN` from [@BotFather](https://t.me/BotFather)
   for real sends.
2. **Run the backend** on `0.0.0.0:8000` (above).
3. **Tunnel** (contacts and the live page need a public URL). One command
   does tunnel + backend: `brew install cloudflared`, then
   `./scripts/live.sh` (free quick tunnel, no account; it refuses to start
   without `SAFEGUARD_APP_TOKEN` because the tunnel is public). By hand:
   `cloudflared tunnel --url http://127.0.0.1:8000` or
   `ngrok http 8000`. Copy the `https://…` URL into `PUBLIC_BASE_URL` and
   restart the backend so links bake it in.
4. **Build the app** with the same token the backend has:
   `SAFEGUARD_APP_TOKEN=<same-token> ./scripts/build.sh device`
   (Simulator: `run-sim.sh`). The token rides in Info.plist from the
   build setting and is never committed.
5. **Link one Telegram account**: Contacts tab → Add contact → share the
   invite link to your own Telegram account → press **Start** once in the
   bot chat. The row flips to Linked within ~10 s. (No Start, no alerts —
   Telegram cannot message strangers.)
6. **Trigger an SOS**: Start protecting, then say the unsafe phrase (or
   let a check-in go unanswered). The SOS screen shows the four track
   chips, the route map, per-contact delivery and the live link.
7. **Open the live link** from the Telegram message (or Copy/Share on the
   SOS screen) in any phone browser: location trail, status and the
   newest video/audio segments, about 10-15 s behind (segment-based,
   never called real-time).
8. **End**: hold End 3 s (or say the safe phrase). Contacts get "SOS
   ended" once; location, recording and tracks stop.

SMS (needs DLT registration in India) and WhatsApp (needs template
approval) are roadmap: the notifier interface already fits them, only
dry-run and Telegram are implemented.

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
5. On first “Start protecting”, allow camera, microphone and speech
   recognition access. The backend must be running and reachable (above);
   without it the app continues with on-device protection only and says so.

CLI alternative: `DEVELOPMENT_TEAM=<TeamID> ./scripts/build.sh device`.

### First-run setup, and running it again

A fresh install opens an 8-step setup (welcome, name, permissions, contacts,
code phrases, listening choices, sample SOS, summary) and the app is not
reachable until it is finished; closing the app mid-flow resumes at the same
step. To see it again without deleting data, use Settings → "Run setup again".
To see it as a brand-new user, use Settings → "Delete all my data" or delete
the app and reinstall.

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
Phase 5 done: `SafetyStateMachine` + spoken check-in (10 s clock, cooldown,
always-on unsafe phrase, code phrases), opt-in conversation listener
(on-device matcher + 20 s window + `POST /verify-speech`), silent
stay-quiet window, full-screen HUD (boxes, pill, dots, red glow, SOS
scrim), forced-dark theme with contrast tests, button styles, wake-word
voice commands (stop confirmation, dim, toasts). 214/214 iOS tests pass
on the Simulator; backend `cd backend && .venv/bin/python -m pytest`
(51 passed, 1 skipped). See DECISIONS.md for what is still unverified
on a real iPhone (speech accuracy, HUD feel, voice commands end to end).
Phase 6 done: SOS escalation on four parallel tracks — safest route
(MapKit, lowest walking ETA among nearest 3 staffed/public places),
Telegram contact alerts with live link (dry-run default, Start-to-link,
max 5), self-contained live viewer page (segment-based, ~10-15 s behind),
DEMO cab sheet, tap-only Call 112, hold-3-s end flow; app-token auth on
all app endpoints. 334/334 iOS tests pass on the Simulator; backend
`cd backend && .venv/bin/python -m pytest` (116 passed, 1 skipped).
See DECISIONS.md for deviations and what is still unverified on a real
iPhone (MapKit search, live viewer on a phone browser, Telegram linking,
SOS screen feel, mock cab is a demo).
