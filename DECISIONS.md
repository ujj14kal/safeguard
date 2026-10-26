# DECISIONS.md — deviations from the brief

Log of every deviation from the project brief, with reasons. Newest first.

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
