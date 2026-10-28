#!/usr/bin/env bash
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
