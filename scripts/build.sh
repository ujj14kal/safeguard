#!/usr/bin/env bash
# Build the Safeguard iOS app.
# Usage:
#   ./scripts/build.sh [simulator]   - build for Simulator (default, no signing)
#   ./scripts/build.sh device         - build for a connected iPhone
#                                     (needs DEVELOPMENT_TEAM env = Apple Team ID)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-simulator}"
case "$MODE" in
  simulator)
    xcodebuild -project ios/Safeguard.xcodeproj -scheme Safeguard \
      -destination 'generic/platform=iOS Simulator' -configuration Debug \
      CODE_SIGNING_ALLOWED=NO build
    ;;
  device)
    : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM (your Apple Team ID) to build for device.}"
    xcodebuild -project ios/Safeguard.xcodeproj -scheme Safeguard \
      -destination 'generic/platform=iOS' -configuration Debug \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" build
    ;;
  *)
    echo "Usage: $0 [simulator|device]" >&2
    exit 2
    ;;
esac
