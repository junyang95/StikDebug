#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-script-library-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
fixture_bundle="$test_directory/ScriptFixtures.bundle"
mkdir -p "$fixture_bundle/Contents/Resources/ScriptResources"
cat > "$fixture_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.stik.script-tests.resources</string>
<key>CFBundleName</key><string>ScriptFixtures</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
cp "$repo_root/App/ScriptResources/"*.js "$fixture_bundle/Contents/Resources/ScriptResources/"
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/LauncherApplication.swift" \
  "$repo_root/App/Models/ScriptLibrary.swift" \
  "$repo_root/Tests/ScriptLibraryTests.swift" \
  -o "$test_directory/ScriptLibraryTests"
"$test_directory/ScriptLibraryTests" "$fixture_bundle" "$repo_root/App/ScriptResources"
