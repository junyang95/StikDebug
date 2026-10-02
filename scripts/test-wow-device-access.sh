#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-wow-access-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library \
  -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/WowDeviceAccess.swift" \
  "$repo_root/App/Services/WowDeviceAccessClient.swift" \
  "$repo_root/Tests/WowDeviceAccessTests.swift" \
  -o "$test_directory/WowDeviceAccessTests"
"$test_directory/WowDeviceAccessTests"
