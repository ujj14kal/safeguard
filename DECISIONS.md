# DECISIONS.md — deviations from the brief

Log of every deviation from the project brief, with reasons. Newest first.

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
