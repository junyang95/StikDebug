#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-ddi-progress-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/App/Models/DDIDownloadProgress.swift" \
  "$repo_root/Tests/DDIDownloadProgressTests.swift" \
  -o "$test_directory/DDIDownloadProgressTests"
"$test_directory/DDIDownloadProgressTests"
