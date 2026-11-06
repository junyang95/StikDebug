#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-authorization-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/DeviceAuthorizationCore.swift" \
  "$repo_root/App/Models/WowDeviceAccess.swift" \
  "$repo_root/App/Services/WowDeviceAccessClient.swift" \
  "$repo_root/App/Services/LauncherDeviceAuthorization.swift" \
  "$repo_root/Tests/LauncherDeviceAuthorizationTests.swift" \
  -o "$test_directory/LauncherDeviceAuthorizationTests"
"$test_directory/LauncherDeviceAuthorizationTests"
