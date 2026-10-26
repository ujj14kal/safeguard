# DECISIONS.md — deviations from the brief

Log of every deviation from the project brief, with reasons. Newest first.

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
