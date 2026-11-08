#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-binding-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
plist_library_dir="${PLIST_TEST_LIBRARY_DIR:-$(pkg-config --variable=libdir libplist-2.0)}"
# Real factory, CryptoKit signatures, typed libplist reader, and public recovery
# APIs. Only paired-device transport calls are stubbed; no real device is used.
xcrun clang -I "$repo_root/idevice" -include stdio.h -c "$repo_root/Tests/DeviceTunnelBindingStub.c" -o "$test_directory/transport.o"
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  -I "$repo_root/idevice" -L "$plist_library_dir" -lplist-2.0 \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/OfflineDeviceBinding.swift" \
  "$repo_root/Sources/IdeviceFFI.swift" \
  "$repo_root/Sources/DeviceIdentity.swift" \
  "$repo_root/Sources/DeviceTunnelFactory.swift" \
  "$repo_root/Sources/DeviceRecovery.swift" \
  "$repo_root/Tests/DeviceTunnelBindingTests.swift" \
  "$test_directory/transport.o" -o "$test_directory/DeviceTunnelBindingTests"
"$test_directory/DeviceTunnelBindingTests"
