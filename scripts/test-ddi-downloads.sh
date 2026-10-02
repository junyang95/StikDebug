#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/jit-ddi-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_directory/ModuleCache" \
  "$repo_root/Sources/StikJITError.swift" \
  "$repo_root/Sources/DeveloperDiskImageService.swift" \
  "$repo_root/Sources/DDIAssetCatalog.swift" \
  "$repo_root/Sources/DDIDownloadRunner.swift" \
  "$repo_root/Sources/SynchronousDDIDownloader.swift" \
  "$repo_root/Tests/DDIDownloadTests.swift" \
  -o "$test_directory/DDIDownloadTests"
cp "$repo_root/Resources/DDIAssets.json" "$test_directory/DDIAssets.json"
"$test_directory/DDIDownloadTests"
