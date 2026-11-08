#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-connection-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
# Compile the actual connection entry point with a paired-tunnel test boundary.
# No device identity, lockdown, libplist or iOS-only FFI is involved.
xcrun swiftc -parse-as-library \
  -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/EndpointProbe.swift" \
  "$repo_root/Sources/DeviceConnection.swift" \
  "$repo_root/Tests/DeviceConnectionProbeTests.swift" \
  -o "$test_directory/DeviceConnectionProbeTests"
"$test_directory/DeviceConnectionProbeTests"
