#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-device-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/DeviceModels.swift" \
  "$repo_root/Sources/DeviceMetadata.swift" \
  "$repo_root/Tests/DeviceMetadataTests.swift" \
  -o "$test_directory/DeviceMetadataTests"
"$test_directory/DeviceMetadataTests"
