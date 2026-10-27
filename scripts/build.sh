#!/usr/bin/env bash
# Build the Safeguard iOS app.
# Usage:
#   ./scripts/build.sh [simulator]   - build for Simulator (default, no signing)
#   ./scripts/build.sh device         - build for a connected iPhone
#                                     (needs DEVELOPMENT_TEAM env = Apple Team ID)
# Optional: BACKEND_BASE_URL=http://<mac-ip>:8000 bakes the verification
# backend URL into the build (Settings > Debug can override it at runtime).
# Optional: SAFEGUARD_APP_TOKEN=<token> bakes the backend app token into the
# build (Info.plist SafeguardAppToken). Never commit the value; pass it from
# your environment. Local dev builds can leave it empty (backend allows).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-simulator}"
case "$MODE" in
  simulator)
    xcodebuild -project ios/Safeguard.xcodeproj -scheme Safeguard \
      -destination 'generic/platform=iOS Simulator' -configuration Debug \
      CODE_SIGNING_ALLOWED=NO BACKEND_BASE_URL="${BACKEND_BASE_URL:-}" \
      SAFEGUARD_APP_TOKEN="${SAFEGUARD_APP_TOKEN:-}" build
    ;;
  device)
    : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM (your Apple Team ID) to build for device.}"
    xcodebuild -project ios/Safeguard.xcodeproj -scheme Safeguard \
      -destination 'generic/platform=iOS' -configuration Debug \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" BACKEND_BASE_URL="${BACKEND_BASE_URL:-}" \
      SAFEGUARD_APP_TOKEN="${SAFEGUARD_APP_TOKEN:-}" build
    ;;
  *)
    echo "Usage: $0 [simulator|device]" >&2
    exit 2
    ;;
esac
