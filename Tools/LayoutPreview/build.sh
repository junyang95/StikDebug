#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${PIKMIN_LAYOUT_BUILD:-/tmp/pikmin-layout-preview}"
APP="$BUILD/PikminLayoutPreview.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-ios17.4-simulator \
  "$ROOT/StikDebug/Design/PikminUI.swift" "$ROOT/StikDebug/Design/AdaptiveLayout.swift" \
  "$ROOT/StikDebug/Views/TodayDashboardView.swift" "$ROOT/StikDebug/Views/OnDevicePairingView.swift" \
  "$ROOT/StikDebug/Services/DDIInstallationController.swift" "$ROOT/StikDebug/Views/DDIInstallationView.swift" \
  "$ROOT/StikDebug/Views/PreflightChecklistView.swift" \
  "$ROOT/Tools/LayoutPreview/Fixtures.swift" "$ROOT/Tools/LayoutPreview/Capture.swift" \
  -o "$APP/PikminLayoutPreview"
python3 - "$APP" "$ROOT" <<'PY'
import sys,plistlib,json
from pathlib import Path
app,root=map(Path,sys.argv[1:])
info={'CFBundleIdentifier':'store.wow-app.pikmin-layout-preview','CFBundleExecutable':'PikminLayoutPreview','CFBundleName':'Layout Preview','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL','LSRequiresIPhoneOS':True,'MinimumOSVersion':'17.4','UIDeviceFamily':[1,2],'UILaunchScreen':{},'CFBundleDevelopmentRegion':'zh-Hans'}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
strings=json.loads((root/'StikDebug/Localizable.xcstrings').read_text())['strings']
for lang in ['zh-Hans','zh-Hant','en']:
    values={key:value.get('localizations',{}).get(lang,{}).get('stringUnit',{}).get('value',key) for key,value in strings.items()}
    folder=app/(lang+'.lproj');folder.mkdir(exist_ok=True)
    (folder/'Localizable.strings').write_bytes(plistlib.dumps(values))
PY
codesign --force --sign - "$APP"
echo "$APP"
