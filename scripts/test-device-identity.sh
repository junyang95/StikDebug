#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-identity-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
plist_library_dir="${PLIST_TEST_LIBRARY_DIR:-$(pkg-config --variable=libdir libplist-2.0)}"
# Exercise production typed parsing against the real host C ABI. The network
# entry point is device-only and is checked by the regular framework build.
xcrun swiftc -parse-as-library -D DEVICE_IDENTITY_READER_TESTING \
  -module-cache-path "$test_directory/ModuleCache" \
  -I "$repo_root/idevice" -L "$plist_library_dir" -lplist-2.0 \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/DeviceIdentity.swift" \
  "$repo_root/Tests/DeviceIdentityTests.swift" \
  -o "$test_directory/DeviceIdentityTests"
"$test_directory/DeviceIdentityTests"
