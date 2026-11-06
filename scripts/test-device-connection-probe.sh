#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-connection-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
plist_library_dir="${PLIST_TEST_LIBRARY_DIR:-$(pkg-config --variable=libdir libplist-2.0)}"
# Host-link actual deviceUDID. Its DeviceTools test boundary throws before these
# iOS-only functions; abort explicitly catches an unexpected call-path change.
cat > "$test_directory/unreachable-device-functions.c" <<'C'
#include <stdlib.h>
#include "idevice.h"
struct IdeviceFfiError *lockdownd_connect_rsd(struct AdapterHandle *a, struct RsdHandshakeHandle *h, struct LockdowndClientHandle **c) { abort(); }
struct IdeviceFfiError *lockdownd_get_value(struct LockdowndClientHandle *c, const char *k, const char *d, plist_t *p) { abort(); }
void lockdownd_client_free(struct LockdowndClientHandle *c) { abort(); }
C
xcrun clang -I "$repo_root/idevice" -c "$test_directory/unreachable-device-functions.c" -o "$test_directory/unreachable-device-functions.o"
xcrun swiftc -parse-as-library \
  -module-cache-path "$test_directory/ModuleCache" \
  -I "$repo_root/idevice" -L "$plist_library_dir" -lplist-2.0 \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/EndpointProbe.swift" \
  "$repo_root/Sources/DeviceIdentity.swift" \
  "$repo_root/Tests/DeviceConnectionProbeTests.swift" \
  "$test_directory/unreachable-device-functions.o" \
  -o "$test_directory/DeviceConnectionProbeTests"
"$test_directory/DeviceConnectionProbeTests"
