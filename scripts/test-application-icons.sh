#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-application-icon-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/ApplicationIconThumbnail.swift" \
  "$repo_root/Tests/ApplicationIconThumbnailTests.swift" \
  -o "$test_directory/ApplicationIconThumbnailTests"
"$test_directory/ApplicationIconThumbnailTests"
