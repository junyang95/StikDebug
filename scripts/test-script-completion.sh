#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-script-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/DebugAttachResponse.swift" \
  "$repo_root/Sources/ScriptCompletionState.swift" \
  "$repo_root/Tests/ScriptCompletionTests.swift" \
  -o "$test_directory/ScriptCompletionTests"
"$test_directory/ScriptCompletionTests"
