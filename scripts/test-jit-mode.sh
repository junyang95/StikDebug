#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-mode-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/JITExecutionMode.swift" \
  "$repo_root/Tests/JITExecutionModeTests.swift" \
  -o "$test_directory/JITExecutionModeTests"
"$test_directory/JITExecutionModeTests"
