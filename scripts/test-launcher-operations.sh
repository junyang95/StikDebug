#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-launcher-operations.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/LauncherOperationToken.swift" \
  "$repo_root/App/Models/LauncherApplicationLaunch.swift" \
  "$repo_root/Tests/LauncherOperationTests.swift" \
  -o "$test_directory/LauncherOperationTests"

"$test_directory/LauncherOperationTests"
