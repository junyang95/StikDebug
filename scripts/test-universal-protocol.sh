#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$repo_root/Tests/UniversalScriptProtocolTests.js" "$repo_root/App/ScriptResources/universal.js" "$repo_root/Resources/universal.js"
