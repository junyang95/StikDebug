#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-wifi-requirement-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Services/WiFiRequirementMonitor.swift" \
  "$repo_root/Tests/WiFiRequirementTests.swift" \
  -o "$test_directory/WiFiRequirementTests"
"$test_directory/WiFiRequirementTests"
