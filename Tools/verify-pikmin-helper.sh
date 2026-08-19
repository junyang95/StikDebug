#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="${PIKMIN_DERIVED_DATA:-/tmp/PikminHelperVerify}"

cd "$PROJECT_DIR"

plutil -lint StikDebug/Info.plist
plutil -lint StikDebug/PrivacyInfo.xcprivacy
plutil -lint PikminTunnel/Info.plist
plutil -lint PikminLiveActivity/Info.plist

xcodebuild \
  -project StikDebug.xcodeproj \
  -scheme StikDebug \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing \
  -quiet

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/StikDebug.app"
test -f "$APP_PATH/PrivacyInfo.xcprivacy"
test -d "$APP_PATH/PlugIns/PikminTunnel.appex"
test -d "$APP_PATH/PlugIns/PikminLiveActivity.appex"

echo "Pikmin Helper verification passed: $APP_PATH"
