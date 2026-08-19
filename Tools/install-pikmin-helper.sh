#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <CoreDevice device identifier>" >&2
  echo "Find it with: xcrun devicectl list devices" >&2
  exit 64
fi

DEVICE_ID="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="${PIKMIN_DEVICE_DERIVED_DATA:-/tmp/PikminHelperDeviceBuild}"

cd "$PROJECT_DIR"

xcodebuild \
  -project StikDebug.xcodeproj \
  -scheme StikDebug \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/StikDebug.app"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "Installed Pikmin Helper on $DEVICE_ID"
