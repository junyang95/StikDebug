#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d /tmp/offline-device-binding-tests.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -parse-as-library "$ROOT/Sources/OfflineDeviceBinding.swift" "$ROOT/Tests/OfflineDeviceBindingTests.swift" -o "$BUILD/tests"
"$BUILD/tests" "$@"
