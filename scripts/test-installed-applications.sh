#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-app-reader-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
# Host-side C ABI integration test. The shipped idevice archive is iOS-only;
# use the installed host libplist, not a mock Swift dictionary implementation.
# Set PLIST_TEST_LIBRARY_DIR to run against an alternate compatible C library.
plist_library_dir="${PLIST_TEST_LIBRARY_DIR:-$(pkg-config --variable=libdir libplist-2.0)}"
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  -I "$repo_root/idevice" -L "$plist_library_dir" -lplist-2.0 \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/DeviceModels.swift" \
  "$repo_root/Sources/DeviceMetadata.swift" \
  "$repo_root/Sources/InstalledApplicationReader.swift" \
  "$repo_root/Tests/InstalledApplicationReaderTests.swift" \
  -o "$test_directory/InstalledApplicationReaderTests"
"$test_directory/InstalledApplicationReaderTests"
