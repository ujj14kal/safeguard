#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

EXTRA=()
[ -n "${BACKEND_BASE_URL:-}" ] && EXTRA+=("BACKEND_BASE_URL=$BACKEND_BASE_URL")
[ -n "${SAFEGUARD_APP_TOKEN:-}" ] && EXTRA+=("SAFEGUARD_APP_TOKEN=$SAFEGUARD_APP_TOKEN")
[ -n "${BUNDLE_ID:-}" ] && EXTRA+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
MODE="${1:-simulator}"
case "$MODE" in
  simulator)
    xcodebuild -project ios/Safeguard.xcodeproj -scheme Safeguard \
      -destination 'generic/platform=iOS Simulator' -configuration Debug \
      CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ${EXTRA[@]+"${EXTRA[@]}"} build
    ;;
  device)
    : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM (your Apple Team ID) to build for device.}"
    xcodebuild -project ios/Safeguard.xcodeproj -scheme Safeguard \
      -destination 'generic/platform=iOS' -configuration Debug \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" ${EXTRA[@]+"${EXTRA[@]}"} build
    ;;
  *)
    echo "Usage: $0 [simulator|device]" >&2
    exit 2
    ;;
esac
