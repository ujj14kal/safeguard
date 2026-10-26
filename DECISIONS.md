# DECISIONS.md — deviations from the brief

Log of every deviation from the project brief, with reasons. Newest first.

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
