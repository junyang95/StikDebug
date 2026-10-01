#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-launcher-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

xcrun swiftc -parse-as-library \
  -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/PairingRecordStore.swift" \
  "$repo_root/App/Models/PairingPIN.swift" \
  "$repo_root/App/Models/LauncherToolData.swift" \
  "$repo_root/App/Models/LauncherExternalRequest.swift" \
  "$repo_root/Shared/CIDRValidator.swift" \
  "$repo_root/Shared/TunnelConstants.swift" \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/DebugAttachResponse.swift" \
  "$repo_root/Tests/LauncherFoundationTests.swift" \
  -o "$test_directory/LauncherFoundationTests"

"$test_directory/LauncherFoundationTests"
