#!/usr/bin/env bash
# Runs the XCTest suite on a Simulator.
# Needs the iOS platform + a Simulator runtime (Xcode -> Settings -> Platforms).
# Usage: ./scripts/test.sh ["iPhone 17"]
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE_NAME="${1:-iPhone 17}"
UDID="$(xcrun simctl list devices available -j | python3 -c "
import json, sys
want = '''$DEVICE_NAME'''.lower()
devs = json.load(sys.stdin)['devices']
for runtime, lst in devs.items():
    if 'iOS' not in runtime:
        continue
    for d in lst:
        if d['isAvailable'] and d['name'].lower() == want:
            print(d['udid'])
            sys.exit(0)
sys.exit('no available simulator named $DEVICE_NAME')
")"
echo "Using simulator $DEVICE_NAME ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true

xcodebuild -project ios/Safeguard.xcodeproj -scheme Safeguard \
  -destination "platform=iOS Simulator,id=$UDID" -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
