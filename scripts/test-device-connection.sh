#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-device-connection.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/DeviceConnectionPolicy.swift" \
  "$repo_root/Tests/DeviceConnectionPolicyTests.swift" \
  -o "$test_directory/DeviceConnectionPolicyTests"

"$test_directory/DeviceConnectionPolicyTests"
