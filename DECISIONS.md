# DECISIONS.md — deviations from the brief

Log of every deviation from the project brief, with reasons. Newest first.

## Phase 8 (2026-10-27): gestures, expressions, listener sensitivity

Not yet run on the iPhone. The classifiers are pure and tested with synthetic
landmarks and blendshapes; the MediaPipe engine itself (models, GPU delegate,
real latency) is unverified until it runs on a device.

1. **MediaPipe Tasks Vision (Google, Apache-2.0)** supplies hand landmarks +
   canned gestures (Gesture Recognizer) and face landmarks + 52 blendshapes
   (Face Landmarker), in VIDEO mode so they track between frames. When it is
   running it REPLACES the two Vision requests (hand pose, face landmarks)
   rather than adding a third pass; if the models are missing or fail to start,
   the old Vision cues run unchanged.
2. **Packaging**: upstream's SwiftPM package needs a clone of the whole
   MediaPipe repo (over 1 GB; it stalled), and its release tags carry no
   Package.swift. `ios/Packages/MediaPipeTasks` is a tiny LOCAL package that
   pins the three prebuilt xcframework zips by URL and checksum (copied from
   upstream's Package.swift), about 100 MB of binaries. Update by copying the
   three url/checksum pairs. Models (`face_landmarker.task` 3.8 MB,
   `gesture_recognizer.task` 8.4 MB, float16, Google, Apache-2.0) are bundled
   in `ios/Safeguard/Models/`.
3. **Middle finger**: MediaPipe's canned gestures do not include it (it would
   say fist or pointing), so it is decided by finger geometry (middle finger
   extended, index/ring/pinky curled, clear dominance) and overrides the canned
   label. Other gestures trust the canned label when it is confident.
4. **Expressions** (happy, angry, sad, surprised, neutral) are weighted sums of
   blendshapes. The weights and thresholds are starting guesses, not tuned on
   real footage. Emotion models from datasets with research-only licences were
   deliberately NOT bundled.
5. **Scoring**: hostile gesture adds up to 0.30 (needs 3+ frames, score >= 0.6),
   angry face adds 0.08. Neither alerts on its own: a lone middle finger or a
   frown never starts the "Are you safe?" flow. Both are also sent to Muse as
   hints (`hostile_gesture`, `angry_face`, `shouting`) which the prompt tells
   it to confirm or reject from the frames.
6. **Latency**: every stage (persons, pose, hands, face) is timed
   (`LatencyMeter`); the debug overlay shows mean and p95, and a
   `latency_ms_mean_p95` line goes to the app log every 10 s. The GPU delegate
   is requested on devices and CPU is used in the Simulator.
7. **Listening sensitivity** (Settings): Normal / High (default) / Maximum.
   Higher levels lift quieter speech (target level 0.10/0.14/0.18, noise floor
   0.004/0.0025/0.0015, max gain 12/20/30) and call shouting at -16/-18/-20
   dBFS. The cost is more background noise reaching the recogniser; the first
   release missed quiet speech, so the default is High. Changes apply within
   about a second.
8. **Privacy**: gestures and expressions are computed on the phone from the
   live frame and never stored; only the rolling fractions leave as hints.
9. **Only a rude gesture** is shown on the HUD for bystanders; gesture and
   expression labels appear only with Settings > Developer > Detection overlay.

## Phase 7.6 (2026-10-27): accounts on Supabase

Backend 152 passed, 1 skipped; iOS 415/415. Nothing here has talked to a real
Supabase project yet: the backend tests use a fake Supabase, the iOS tests a
fake service.

1. **Relay design**: the app calls this backend, the backend calls Supabase
   Auth and PostgREST. The anon and service-role keys never reach the phone.
   Passwords are forwarded, never stored or logged.
2. **Profile row** (`profiles`: name, email, phone, language, consent_at):
   written with the service-role key; RLS lets a signed-in user read and
   update only their own row; no insert/delete policy on purpose.
3. **Accounts are optional**: setup has an "Account" step with "Continue
   without an account", because the app must still work offline or when the
   server is down. Existing installs are not forced to sign up.
4. **Consent** is required at sign-up and timestamped; the privacy text lists
   exactly what is stored.
5. **Tokens** live in the Keychain (this device only, when unlocked); the
   cached profile (name, email) is in UserDefaults and cleared on sign-out.
6. **"Delete all my data"** now also deletes the account on the server (or
   reports that it could not). Settings has "Delete my account" on its own.
7. **Not applied to Supabase**: the Supabase CLI on this Mac is signed in to a
   different account (projects JobSync, Fleet1, etc.), and the project ref
   given earlier (wiyvykavdcisvvuwwxss) is not in it, so nothing was run
   against any project. The migration must be applied by whoever owns the
   Safeguard project.
8. **Muse Code MCP** was not used; the setup is a plain SQL file plus
   environment variables, so no agent needs database access.

## Phase 7.5 (2026-10-27): location fix, SOS redesign, Dashboard, loading, contacts, live viewer

Written directly (not by Muse). iOS `./scripts/test.sh` 398/398; backend 137
passed, 1 skipped. Looked at in the Simulator (Delhi location) for the
Dashboard, Protect idle and the SOS screen; nothing here has run on the iPhone.

1. **Location was wrong** because the tracker took the first Core Location
   callback (often cached or cell-tower, hundreds of metres to km off) and
   never refined it. Now `LocationFixPolicy` rejects fixes older than 15 s,
   never lets a coarse fix replace an accurate one, and waits up to 8 s for a
   precise (<=65 m) fix before the route search; the route re-runs by itself
   when the fix gets precise or the wearer moves 150 m. If Precise Location
   is off for the app it asks for temporary full accuracy during an SOS
   (`NSLocationTemporaryUsageDescriptionDictionary`, key `SOS`). The SOS map
   shows the accuracy circle and a "Location: about N m" chip.
2. **Nearest help**: Apple's point-of-interest search (police, hospital)
   plus a text search, widening 3 -> 8 -> 20 km until something is found;
   with no walking route it still points at the nearest place.
3. **Google Maps**: an in-app Google Maps view and Google place search need
   the Maps SDK and a Google API key (a new dependency and a secret), so they
   are NOT used. The SOS map is MapKit; "Google Maps" opens walking
   directions in the Google Maps app (or its web page) with no key.
4. **SOS screen** redesigned: everything runs by itself (contacts, live page,
   route, demo cab, recording); the only manual action is Call police (112),
   pinned at the bottom with a 3 s hold-to-end beside it.
5. **Dashboard tab** (first tab): readiness checklist (four permissions,
   server, contacts linked, alert mode) with a fix action on each row, 30-day
   stats from local history, recent SOS, the 112 button. Pure rules in
   `Readiness.swift`, tested.
6. **Loading and motion**: shared skeletons/shimmer, a branded loading screen
   while the camera warms up and while the dashboard loads, springs and
   numeric transitions; Reduce Motion respected.
7. **Auto-start protecting** when the app opens (camera already allowed, setup
   done): ON in DEBUG builds, OFF in release (Settings → Listening). A camera
   that starts by itself must be the wearer's own choice.
8. **Contacts from the phone**: asked with a reason first (`NSContactsUsageDescription`),
   searchable picker, the person's name and number are saved ON THIS PHONE
   only (never uploaded); duplicates by number are blocked; the wearer must
   confirm the person agreed, which sets the consent tick.
9. **Live viewer page** restyled; it always plays the newest two parts (it
   used to play from the start and fall behind), shows the accuracy circle,
   last update age and Google Maps links. Still segment-based, "about 10-15 s
   behind", never "real-time". `scripts/live.sh` starts a free Cloudflare quick
   tunnel plus the backend with `PUBLIC_BASE_URL`; it refuses to run without
   `SAFEGUARD_APP_TOKEN` because the tunnel is public. Needs `cloudflared`
   installed. Verified with a throwaway backend (fake token, temp data) behind a
   quick tunnel: incident start needs the token (401 without), the live URL
   uses the tunnel host, the page, state, trail and media segments load for an
   unauthenticated viewer, and the page renders on a phone-sized viewport. That
   test found a real bug (the page fetched `state` relative to
   `/live/<token>`, resolving to `/live/state`); fixed and pinned by a test.
   Not run with the iPhone as the sender, and not through `live.sh` itself
   (it needs your keys and the port your backend already holds).
10. **Hindi** for all new strings is machine-written (same review caveat).

## Phase 7 (2026-10-27): first-run setup, Activity, Settings, Hindi, defaults

Muse Code wrote the first six commits in a second clone (`~/safeguard`); it
was stopped mid-task, its commits fast-forwarded here and its uncommitted
edits copied over, then finished and checked here. Backend
`cd backend && .venv/bin/python -m pytest` (137 passed, 1 skipped); iOS
`./scripts/test.sh` (371/371 on the Simulator).

What shipped: blocking 8-step setup as a pure tested state machine (resumes
at the same step; "Run setup again" in Settings keeps data), local
`IncidentHistory` (Documents JSON, 30-day purge at launch, no transcripts),
Activity tab, Settings grouped Profile/People/Code phrases/Listening/Alerts/
Permissions/Data/About/Developer, delete-all (local data + backend
`DELETE /evidence/{session}` and `DELETE /contacts/{code}`), one `Defaults`
type (release: everything off except distress words and on-device code
phrases), String Catalog (English + Hindi, 368 app keys + 5 Info.plist keys,
a test fails on any missing or empty Hindi value), Hindi "Are you safe?"
voice, alerts to contacts in the wearer's language, contrast tests for new
colour pairs, 44 pt touch targets, Reduce Motion/Transparency.

Deviations and caveats:

1. **Hindi is machine-written.** It needs a native speaker's review before
   anyone relies on it.
2. **Existing installs skip setup.** `showSetup` is `!setupComplete &&
   !onboardingSeen`, so a phone that already passed the old one-screen
   onboarding does not see the new flow until "Run setup again" in Settings.
3. **Not verified on the real iPhone**: system permission prompts and the
   "Turn on in Settings" return path, VoiceOver reading order, the largest
   Dynamic Type sizes (setup and Settings scroll, but clipping was not
   checked on a device), Hindi voice availability (a missing voice falls back
   silently to the default), the Telegram invite step with a real bot, and
   delete-all against a live backend while offline.
4. **Machine spot-check only**: Simulator tests cover logic, localisation
   completeness and contrast; nothing here was driven by hand through the
   screens.

## Phase 6 (2026-10-27): SOS escalation, four parallel tracks

Shipped in small commits (backend notify + linking + incidents + viewer +
auth, iOS coordinator + client + tracker + SOS screen + contacts tab +
settings). Backend `cd backend && .venv/bin/python -m pytest` (116 passed,
1 skipped); iOS `./scripts/test.sh` (334/334 on the Simulator).

Backend — `notify.py` (`DryRunNotifier` default, `TelegramNotifier` over
httpx; `SmsNotifier`/`WhatsAppNotifier` are interface-shaped roadmap only —
SMS needs DLT in India, WhatsApp needs template approval). Contact linking
with no public webhook: `POST /contacts/invite` mints a code, a background
task polls Telegram `getUpdates` for `/start <code>`, chat ids persist to
gitignored `backend/data/contacts.json` (max 5). Incidents: unguessable
`token_urlsafe(24)` share token, one alert burst per incident (repeat start
returns fresh=False, no delivery), 429 rate limit, last-500 location points,
"SOS ended" once. The live viewer is one self-contained dark page (Leaflet
1.9.4 pinned CDN) polling `/live/{token}/state` every 2 s; state + segments
are scoped to that token's session only. Auth: `X-Safeguard-Token` on every
app endpoint when `SAFEGUARD_APP_TOKEN` is set (unset allows + warns, for
local dev); `/health` + `/live` stay public.

iOS — `EscalationCoordinator` starts route + contacts + stream + cab
together; each chip shows pending/running/done/failed, retries back off
[2,8,30], one track never stops the others. Route = lowest walking ETA
among the nearest 3 MapKit "police station"/"hospital" hits within ~3 km,
drawn on the SOS map with ETA + Open in Maps. Contacts tab (add/remove ≤5,
Telegram invite share sheet, Linked/Waiting, 10 s re-poll while anyone
waits). Settings: wearer name, "Send real alerts" OFF + confirm dialog,
test alert. Live link gets Copy + Share; cab is a DEMO sheet (fake driver,
plate, countdown, re-share to Telegram); "Call 112" uses `tel:112` on tap
only. End = hold 3 s or the safe phrase; Stop mid-SOS runs the same flow.

Deviations and judgment calls:

1. **"Safest" means staffed/public by ETA, not a crime-risk model**: the
   route answers "where can people help me fastest". Documented here, in
   the code, and nowhere near a risk claim.
2. **Incidents are saved to `data/incidents.json`** (gitignored) so a backend
   restart mid-SOS keeps the family's live link working. **Share links
   expire**: an ended incident's link stops `INCIDENT_TOKEN_TTL_HOURS` (6 h)
   after the end, an active one after `INCIDENT_MAX_ACTIVE_HOURS` (24 h).
   Fixed after the Phase 6 review. Also from that review: `/asr` refuses a
   wrong or missing app token before accepting the socket, and `/health`
   only reveals `muse_configured` to a caller holding the app token.
3. **The route waits through its retries for a first fix** ("Waiting for
   location…" while retryable, "Location unavailable" when terminal): on a
   cold start the fix often lands seconds after Unsafe.
4. **Dry-run is two independent switches**: the app's "Send real alerts"
   sends `dry_run` per incident, the backend's `NOTIFY_MODE` picks the
   notifier. Either side can force dry-run; a real Telegram send needs
   both (app ON + backend `NOTIFY_MODE=telegram` + bot token).
5. **`/verify`, `/evidence` and friends now need the app token** when it
   is set (401 without); the viewer needs only its share token. The token
   rides in Info.plist from the `SAFEGUARD_APP_TOKEN` build setting, never
   committed; `scripts/build.sh` passes it through.
6. **Contact names ride in dry-run logs** (`logs/notifications.jsonl`):
   the brief's "counts and status only" applies to AppLog events and the
   delivery API; the dry-run log exists precisely to show what WOULD have
   been sent, and contains no transcripts, appearance or third parties.
7. **No SMS/WhatsApp**: interface-ready, listed as roadmap in README.
8. **No unit tests for the Settings toggle default or the confirm
   dialog**: the VM starts the mic + timers on init, so no test
   instantiates it; the `dry_run` wire default IS pinned in
   `IncidentClientTests`, and the toggle/dialog are covered by the demo.
   Same for the 3 s hold and the cab countdown (UI glue over tested
   coordinator/builder logic).

Honest status: everything above is green on the Simulator, but no real
iPhone has run it yet — MapKit search quality, the live viewer on a phone
browser, Telegram linking end to end, the TTS/voice interplay mid-SOS and
the feel of the SOS screen are all unverified. The live video is
segment-based (the page says "about 10-15 s behind", never real-time);
Telegram contacts MUST press Start once or no alert can reach them; the
demo tunnel exposes the backend, so `SAFEGUARD_APP_TOKEN` must be set
first; the mock cab books nothing.

## Phase 5 (2026-10-27): voice check-in, listener, window, HUD, commands

Shipped in small commits (A core, A wiring, B backend, B speech core,
B listener, C, D2, D1, D3, D4 — D2 landed before D1 because the HUD needs
the tokens). 214 iOS tests + 51 backend tests (+1 skipped) green.

Part A — `SafetyStateMachine` (pure, timestamped): Idle→Monitoring→
(listening window)→Asking→{Safe,Unsafe,NoReply→Unsafe}, driven by scorer
alerts, Muse verdicts, speech severity, replies and ticks. Asking speaks
"Are you safe?" quietly via AVSpeechSynthesizer; the 10 s clock starts
when the audio starts (the speaker reports back even on failure/cancel).
Verify failures show a reason (unreachable / no key / rate limit / server
error) and never suppress: the machine gets no input from them.

Part B — conversation listener (opt-in, default OFF) + `POST
/verify-speech` (Muse judges a text snippet, never audio; same rate
limit, timeout, strict JSON, appearance guard and no-transcript logging
as /verify). On-device matcher (threat/coercion/pursuit/proposition/
abuse/distress, severities, quotation/negation/benign-frame guards),
20 s in-memory window, gapless recognition restarts, deaf-never-active
states. Speech feeds the scorer (additive) and the machine (strong only,
never straight to Unsafe).

Part C — the 6 s silent stay-quiet window with the calm cue (large text,
VoiceOver once, one light haptic), skip rules, early end by tap/unsafe
phrase, and the onboarding tip.

Part D — full-screen camera HUD (corner brackets, status pill, mic +
backend dots, red edge glow, SOS scrim, voice hints), forced-dark theme
with contrast-tested tokens, button styles, restyled idle/tabs, preview
states for everything, and wake-word voice commands sharing the one
audio engine + recognizer, with stop confirmation, dim mode and toasts.

Deviations and judgment calls:

1. **No volume-button capture**: it needs private API. The non-verbal
   answer is a double tap (ends the window early; answers "I'm OK" when
   asked) plus on-screen buttons, which also serve accessibility.
2. **Safe phrase ignored during the window**: nothing was asked yet, so
   the question is still asked. Unsafe works, tap ends the window early.
3. **Muse `low` never yanks a question**: it cancels movement-only
   suspicion in the window, but Asking always finishes its check-in.
   Unsafe is terminal until Stop (Phase 6 owns what follows SOS).
4. **No-key detection via /health**: the client cannot see 503 bodies
   without breaking the pinned `serverStatus(Int)` error shape, so
   /health now reports `muse_configured` and a 5xx from a keyless
   backend reads as "no API key". Unknown verdict strings are dropped.
5. **Speech is additive in the scorer** (`value = base + speech * 0.30`,
   capped at 1; weight a guess), not a normalized weight: silent speech
   leaves every Phase 3 value bit-for-bit identical, so no retuning and
   no existing expectation changed. Cap bypass + "threatening speech"
   reason at `reasonThreshold` (0.5).
6. **Backend speech `medium` (0.6) feeds only the scorer**: below the
   0.7 strong threshold, so per the brief only `high` triggers the
   check-in directly; medium + any movement can still alert.
7. **The mic is never paused for TTS**: pausing would deafen the unsafe
   phrase, which must work at ANY time. The app "ignores itself"
   instead — our spoken texts match no code phrase and no threat
   pattern (tested) — and voice commands are gated on `speakingNow`.
8. **SFSpeechRecognizer only** (on-device enforced, no server fallback):
   one uniform, testable path; the iOS 26 SpeechAnalyzer option stays
   open. Final transcripts only (no partials).
9. **One recognition task teed in code**: matcher, commands and code
   phrases all read the same final-transcript stream — literally one
   engine and one recognizer, no double mic tap.
10. **Distress is never negation-discounted** ("don't touch me" is
    danger, not safety); quotation discounts ×0.3; benign frames cancel
    ("come with me if you want to live"). Accepted gap, documented in a
    test: benign invitations ("come with me to the shops") match
    on-device and rely on Muse's downgrade.
11. **The listener runs app-foreground-wide (idle included)** so
    "Safeguard, start protecting" can be heard; idle transcripts feed
    commands only (no phrases, no window, no scan, no backend call).
    Costs always-on mic compute in the foreground; iOS suspends it in
    the background and interruptions auto-resume.
12. **Code phrases need no opt-in** (disclosed at onboarding): with the
    toggle off, transcripts are scanned for phrases/commands and
    dropped immediately; no window is ever built.
13. **Restart swaps are new-before-old** with generation-tagged tasks:
    stale-task errors are ignored, stale results still count (they
    cover pre-swap audio). /verify and /verify-speech share one 20/min
    Muse budget so neither starves the other.
14. **"Call 112" uses `telprompt://`** (always asks first — no
    pocket-dialled emergencies); "call 112" WITHOUT the wake word is
    distress (→ check-in), with it is the command. "Share my location"
    answers "not available yet" (Phase 6 hook).
15. **Per-box colours map thresholds directly** (no holds): a box must
    never disagree with its person; the global level keeps its holds.
    Dim lifts on suspected/asking/unsafe, so the overlay can never hide
    the question or the SOS. A wake-worded transcript during a pending
    stop cancels the stop and runs as a command.
16. **The splash and launch screen stay white**: the cross-fade goes
    white → dark. Making the splash dark is a one-line option (re-point
    the `LaunchBackground` colorset at the dark background).
17. Test-target notes: `DS.swift` joined the test target (contrast tests
    read the token hexes); pure speech/safety/HUD files compile into
    both targets per the established pattern.

Honest status: the suites above are green on the Simulator, but Muse
(incl. /verify-speech) has still never been called live (no key).
Speech-recognition accuracy in noise, accents and several speakers, the
HUD feel, TTS timing and end-to-end voice commands are unverified until
iPhone testing (the Simulator runs here had no usable mic; the listener
is covered by pure tests + code review only). All speech/scoring
thresholds are starter guesses for Phase 8 replay tuning.

## Phase 4 review fixes + brand assets (2026-10-27)

Found by reviewing the real Phase 4 code, probing it, and running it:

1. **The phone could not reach the backend**: `VerifierConfig` defaulted to
   `127.0.0.1` (the phone itself), and `Info.plist` had no `BackendBaseURL`, no
   App Transport Security exception for `http://` and no local-network usage
   text, so every /verify call failed silently on a real iPhone while the mocked
   tests stayed green. Now: URL priority is Settings override > Info.plist
   `BackendBaseURL` (build setting `BACKEND_BASE_URL`) > localhost, resolved on
   every call; `NSAllowsLocalNetworking` (not arbitrary loads) and
   `NSLocalNetworkUsageDescription` added; Settings > Debug has a Backend URL
   field and a **Test connection** button (GET /health). The README now says to
   run uvicorn with `--host 0.0.0.0`. A test reads the real Info.plist.
2. **Appearance guard rejected normal verdicts**: it matched substrings, so "age"
   refused "image", "manage", "average", "engaged", "message" (HTTP 503). Now
   whole-word patterns (clothing, race/ethnicity, age, gender words); 25 tests
   cover accepted wording, refused wording and the old false positives.
3. **SAM 2 prompt boxes were wrong**: Vision's lower-left y was sent as top-left
   pixels (a person in the top third landed in the bottom third), and the newest
   boxes were applied to the clip's OLDEST frame. `FrameBuffer` now stores boxes
   per frame and `clip()` starts at the oldest frame with people, returning that
   frame's boxes; `VerifyPayload.pixelBoxes` flips y. Tested.
4. **Secret-scan hook tightened**: the Phase 4 relaxation let any unquoted
   alphanumeric value through (a 32-char hex auth token starting with a letter,
   an unquoted API key, a short unquoted password). Now only dotted paths/calls/
   subscripts, shell variables and bare all-lowercase identifiers pass, token-
   shaped runs block even inside a dotted path, and only ADDED lines are checked.
   `scripts/test-pre-commit.sh` (22 cases) fails 8 on the old hook, 0 on the new.
   Residual gap: an all-lowercase letters-only password reads as a variable name.
5. **Asset catalog was never compiled into the app**: the project referenced
   `Assets.xcassets` by two IDs that had no definitions, so Xcode silently
   skipped it. The accent colour, app icon and launch colour from Phase 1 never
   shipped. Added the missing file reference and build file; `Assets.car` now
   contains AccentColor, AppIcon, LaunchLogo and LaunchBackground. Visible side
   effect: buttons are now teal (the intended accent) instead of default blue.
6. **App icon, launch screen and splash** from the supplied logo
   (`design/logo-source.png`, `scripts/make-brand-assets.py`): shield enlarged
   from 51%x58% to 70%x81% of a 1024 icon on pure white; the launch screen shows
   the same logo (Info.plist `UILaunchScreen`), and `SplashView` starts with it
   fully visible in the same place, fades "Safeguard" in beneath it, holds 3.5 s
   and cross-fades out over 0.6 s (Reduce Motion respected, skippable in debug
   builds with `skipSplash`). Brand tests check icon size, opacity, centring and
   wiring. Not changed: the home-screen label is still "Safeguard".
7. **Not done / still open**: `/verify` has no authentication (add a shared
   secret before exposing it through a tunnel); verify failures are not retried;
   frames are JPEG-encoded at 5 Hz even with nobody in view; backend tests need
   `pip install -r requirements-dev.txt` (run here via a shim only for the new
   parsing tests); Muse has still never been called live.

## Phase 4 (2026-10-26)

Part A — proximity colours (display-only): new `ProximityTracker` maps the
nearest live track's box height through `nearHeight` (0.30) /
`tooCloseHeight` (0.45) in `ThreatConfig` (guesses to tune on real clips),
with `proximityRiseHold` 0.6 s, `proximityFallHold` 1.0 s and 0.05
hysteresis, all timestamp-based. Levels have distinct symbol+text
(`checkmark.shield`/`person.fill`/`exclamationmark.triangle.fill`); red
"Too close" never pulses and never uses the SOS symbol. VoiceOver
announces changes only; medium haptic on rise to tooClose, none on falls;
Reduce Motion disables breathing. Proximity never alerts: scorer `alert`
only adds "Something seems off" text. Preview-states screen gained the
three levels with mock data. 9 new tests.

Part B — /verify (SAM 2 + Muse): `POST /verify` takes 4-8 ~512 px frames
+ on-device feature summary. `SAM2_MODE`: `auto` tries SAM 2 and falls
back when slow/missing, `sam2` requires it (503 otherwise), `muse-only`
never tries. Default is **`muse-only`** (see spike below). SAM 2 path:
tiny checkpoint video predictor, first-frame boxes as prompts, geometry
(mask-area growth, centroid path, corridor overlap/blocks) folded into
the Muse prompt. Muse path: OpenAI-compatible Chat Completions at
`META_MODEL_API_BASE_URL` (default `https://api.meta.ai/v1`), model
`MUSE_MODEL` (default `muse-spark-1.3`), strict JSON
`{threat_level, behaviours_observed[], confidence, reason}`, behaviour
only, never appearance; 20 calls/min limiter; per-call timeout
(`MUSE_TIMEOUT_S`, default 20 s); every call appended to a JSONL log
(path log + status code, latency, model, daily counter). The app's
`VerifierClient` fires only when the on-device score crosses
`VERIFY_THRESHOLD`, sending the ring-buffer clip; never per frame, never
for proximity colour.

Spike (real data point): `sam2.1_hiera_tiny.pt` on 8 CPU frames took
9.14 s — 3x over the 3 s budget — so `muse-only` is the default and SAM 2
is opt-in (`SAM2_MODE=sam2`, GPU assumed). Verified instead: backend unit
suite 15 passed + 1 skipped (e2e correctly skipped by default), and the
e2e test with the real checkpoint + mocked Muse passes (4.38 s incl.
model load, `path: sam2+muse`, geometry reaches the Muse prompt).
Implementation finding: importing `sam2` already initialises GlobalHydra
with `pkg://sam2` on the search path, so the predictor builds with the
repo-style config name from any CWD — do NOT call `hydra.initialize`
(it raises "already initialized"); the earlier init wrapper was deleted.

Honest status: Muse has NEVER been called live (no key; all tests mock
it with canned behaviour-only JSON incl. a "stationary, not a threat"
low case for the 0.74 ego-motion false alert). SAM 2 e2e ran on a
synthetic blob JPEG, not real people. Facing still unverified (Sim pose
unsupported). All thresholds synthetic; Phase 8 replay tuning owns them.
Tests: 69/69 iOS green on the Simulator; backend as above.
Hook: pre-commit rule 3 now allows bare code references (`api_key=SETTINGS.x`)
while still blocking quoted literals and token-shaped values (verified with
fake-secret probes); "Bearer <token>"-shaped doc comments were reworded since
rule 2 flags them. Environment note: the shell sandbox blocks simctl/XPC, so
Simulator runs here need unsandboxed execution.

## Phase 3 scorer review fixes (2026-10-26)

Found by probing the real `FeatureExtractor` + `ThreatScorer` with scenarios the
Phase 3 tests did not cover (alert threshold 0.50):

1. **Minimum history for trend/speed/cornering**: a new track with 2 samples
   (height 0.30 -> 0.32) scored 0.66 and alerted half a second after someone
   appeared, because a two-point slope turns box jitter into "fast approach".
   Slopes now need `minTrendSamples` (6) over `minTrendSpan` (1.0 s). Now 0.21.
2. **Persistence from timestamps**: it was `sample count x 0.2 s`, so a device
   detecting at 2.5 Hz looked half as persistent (0.67 vs 1.0 for the same 8 s).
   Now the matched seconds come from sample timestamps (gaps longer than
   `reappearMinGap` are not presence); the latest sample is credited one
   nominal period, so results at 5 Hz are unchanged.
3. **Static-presence cap**: a stranger standing still, facing you, alone, near
   your path, scored 0.49-0.50 with zero threatening behaviour. If
   trend/speed/cornering are all below `motionMin` (0.15) and the track has not
   reappeared, the score is capped at `staticScoreCap` (0.35, margin 0.15 below
   threshold). Trade-off: someone who stays beside you at a constant distance
   with no approach and no reappearance can no longer alert on presence alone.
4. **Still open (not fixed)**: ego-motion. When *you* walk toward someone
   standing still, their box grows and scores 0.74 (alert). Needs scene-relative
   growth (compare against other tracks) or a motion estimate; only real
   footage can validate it. Also a forward-facing chest/glasses camera cannot
   see a person following from behind, so "following" in demos must be someone
   in view (ahead, beside, or crossing); say so in the pitch.
5. Version label now 0.3.0 (Phase 3). Tests: 53 pass on the iOS 26.5 Simulator
   (45 before, 8 new).

## Phase 3

1. **Upper-body boxes kept (now explicit)**: `upperBodyOnly = true` is set
   deliberately, not just inherited. Upper-body boxes stay stable when legs
   are occluded or out of frame (crowds, doorways, close range — the common
   cases) and keep one consistent box meaning for velocity/growth math; the
   growth features use ratios, so absolute height never matters. If absolute
   distance is ever needed, upper-body height is roughly 0.55x full height.
   Revisit against real footage in Phase 8.
2. **Pose is enrichment, rectangles are critical**: the two Vision requests
   run as separate performs. A pose failure degrades facing to unknown with
   a once-only log and never kills tracking. Found by the Simulator run:
   the pose request cannot initialise there ("Unable to setup request"),
   so facing is unverified until an iPhone/Replay run with real people.
3. **Facing is 2D-only**: nose+eye visibility times a shoulder-spread gate.
   It separates facing-toward (face visible) from profile/back-of-head, but
   has no depth; heavy occlusion yields unknown, not facing.
4. **Reappearing means same-track gaps**: relinking across track IDs would
   need appearance matching, which is forbidden; a track that coasts
   through a gap longer than `reappearMinGap` and matches again counts.
5. **Tuning is synthetic-only so far** (threshold 0.50): following 0.59,
   fast approach 0.87, cornering 0.67, crowd max 0.29, passerby 0.22.
   False-alert behaviour: negatives clear by 0.21+; the thinnest positive
   margin is slow following (+0.09). Borderline scores only ever trigger a
   voice check-in (Phase 5), never an SOS directly — escalation needs
   Unsafe or no-reply. Box jitter, occlusion ID-switches and low-light
   pose loss on real footage are unverified; Phase 8 replay tuning owns
   the thresholds.
6. **Script default device** is now iPhone 17 (this Mac's simulators are
   17-series; there is no iPhone 16 device).

## Phase 2 debug review (2026-10-26)

1. **Replay ignored video rotation** (bug from Phase 1): iPhone portrait clips
   are stored landscape with a rotation flag, and a plain track output drops it,
   so they replayed sideways and Vision looked for sideways people. Now read
   through `AVAssetReaderVideoCompositionOutput` with a composition that applies
   the transform. Reproduced with a 640x360 clip flagged 90 degrees on a macOS
   harness: delivered 640x360 before, 360x640 after.
2. **Stale results after Stop**: a frame still in flight when `stop()` ran
   published its tracks/image afterwards, leaving ghost boxes and a frozen
   frame. `publishDetection`/`publishReplayFrame` now ignore results unless
   protecting.
3. **Detector tests in the Simulator**: Vision failed with "Could not create
   inference context". The detector now sets `usesCPUOnly` under
   `#if targetEnvironment(simulator)` only (deprecated in iOS 17, so that
   build emits a deprecation warning; devices are unaffected). 15/15 tests pass.
4. **Not verified**: the detector only has negative tests (blank/noise find
   nobody). Whether it actually finds a person, and that boxes sit upright on
   people, needs a run on the iPhone. Note Vision's default
   (`upperBodyOnly = true`, revision 2) returns upper-body boxes; revisit when
   Phase 3 chooses distance features.

## Bundle ID (2026-10-26)

1. **Unique bundle ID**: changed `com.safeguard.app` to
   `io.github.ujj14kal.safeguard` (project file, README, `run-sim.sh`, debug
   hook comments). Apple refused to register `com.safeguard.app` to a personal
   team because it is already taken. First device build succeeded with this ID
   and installed on the iPhone; launching needs the developer profile trusted.

## Merge (2026-10-26): upstream Phase 1 review fixes merged into Phase 2.
The lock-based frame counter and drop-while-busy gate now guard the whole
detect-then-track pipeline (not just replay conversion); the camera delivers
upright portrait buffers so the `.up` detector orientation is correct.

Verification after the merge (first real `xcodebuild test`, iOS 26.5 Simulator):
the SafeguardTests target had mismatched build-configuration IDs in the project
file (empty `SWIFT_VERSION`), fixed, and its bundle ID now follows the app's
(`io.github.ujj14kal.safeguard.tests`). Result: 11/11 tracker tests pass; the 4
`PersonDetectorTests` (5 assertions) fail in the Simulator with Vision's
"Could not create inference context", a Simulator limitation, so the detector
is still unverified until it runs on the iPhone.

## Phase 2

1. **Hostless test target**: `SafeguardTests` has no app host and compiles the
   Detection sources directly (no `import Safeguard`), so the same files run
   under `xcodebuild test` and under a macOS SwiftPM harness.
2. **Detector orientation** defaults to `.up`; chest-mount framing is tuned
   against real footage in Phase 8.
3. **Result type**: `VNDetectHumanRectanglesRequest.results` is
   `[VNHumanObservation]` (confirmed via the compiler); mapped straight to
   `DetectedPerson`, no cast.
4. **Detection at 5 Hz** in the view model (Vision cost); the tracker coasts
   between detections. Debug overlay maps boxes through the aspect-fill
   transform using the published frame size.
5. **No positive-path detector test**: asserting "finds a real person" needs
   footage fixtures, which the repo forbids committing; covered by the
   Phase 8 replay tuning instead. Unit tests assert blanks/noise find nobody
   and never throw.
6. **Environment**: `xcodebuild test` impossible here (still no iOS
   platform/runtime); ran the verbatim, hash-verified suite via SwiftPM on
   macOS instead — 15/15 pass. `scripts/test.sh` runs it under Xcode once
   the platform is installed.

## Phase 1 review fixes (2026-10-26)

1. **Camera orientation**: `PhoneCameraSource` now sets the video connection's
   `videoRotationAngle` to 90, so frame buffers are upright portrait. Needed
   before Phase 2: Vision would otherwise receive sideways landscape buffers.
2. **Camera failures stop protection**: runtime errors and interruptions
   (call, other app, backgrounding) are reported to the delegate, so the app
   never shows "Protecting" while no frames arrive.
3. **Replay hardening**: a clip with no frames now fails with a message
   instead of looping hot; replay frames are dropped (not queued) while the
   previous one is still converting, and frame counting uses a lock-based
   counter instead of a Task per frame. This supersedes Phase 1 item 4.
4. **Info.plist**: added the standard bundle keys (`$(PRODUCT_BUNDLE_IDENTIFIER)`,
   version keys from `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, single-scene
   manifest) because `GENERATE_INFOPLIST_FILE = NO`.
5. **Backend deps**: `requirements.txt` has version bounds.
6. **Honest status**: README no longer says Phase 1 is "done"; it is written
   and typechecked but not yet built with `xcodebuild` or run on a Simulator
   or device. Hook install and the GitHub noreply commit email are documented.

## Phase 1

1. **Display-only states**: `ProtectionState` enum drives the shield ring and
   previews; the full SafetyStateMachine (prompt, 10 s no-reply, cooldown,
   code phrases) arrives in Phase 5 as briefed.
2. **Placeholder tabs**: Contacts/Activity/Settings are shells (Settings hosts
   the Debug section); real tabs arrive in Phase 7 as briefed.
3. **Empty AppIcon**: the asset catalog ships an empty AppIcon set (placeholder;
   real shield vector later) so the accent colour compiles now.
4. **Replay rendering**: replay pixel buffers convert to `UIImage` off-main
   for display. Fine for demos; revisited if Phase 2 overlays need it faster.
5. **Async failure reporting**: `VideoFileSource.start()` validates the file
   synchronously and reports track/reader failures via the delegate, because
   modern AVFoundation track loading is async.
6. **Debug deep-link flags**: `debugInitialTab` / `debugInitialRoute`
   defaults (debug builds only) select the initial tab/route for headless
   Simulator screenshots.
7. **Environment (this Mac)**: Xcode here has no iOS platform and no Simulator
   runtime (`xcodebuild`: "iOS 26.5 is not installed"; zero `.simruntime`
   bundles), so `xcodebuild` and Simulator runs are impossible until the iOS
   platform + a runtime are installed via Xcode → Settings → Platforms.
   Verified instead: `swiftc` iOS codegen+link of all sources, a macOS
   harness running the real capture sources end to end, and an ASGI
   `/health` run. `phase-1-ok` tag waits on a Simulator run after install.

## Phase 0

1. **Clone location**: the brief says to `git clone` the repo "into this folder".
   The working folder is the macOS home directory, so cloning the repo contents
   into it directly would mix the repo with the whole home folder. Instead the
   repo was cloned as `./safeguard/` (standard `gh repo clone` layout) and all
   project work happens there.
2. **Hook PII placeholders**: the pre-commit hook blocks staged secrets, tokens,
   `.env` files, and phone numbers. Apple Team ID and personal email are
   configurable at the top of the hook (`BLOCKED_TEAM_ID`, `BLOCKED_EMAIL`) and
   intentionally left empty in the committed copy — real values go only in the
   local, untracked `.git/hooks/pre-commit`, since the repo is public.
3. **Fictional-number allowance**: the hook permits the fictional `+1-555-01xx`
   range so fake contacts/test numbers can appear in code, tests, and docs.
   All other E.164-looking numbers are blocked.
