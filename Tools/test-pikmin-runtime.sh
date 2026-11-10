#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d /tmp/pikmin-runtime-tests.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/Sources/PikminRuntime" "$BUILD/Tests/PikminRuntimeTests"
cat > "$BUILD/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PikminRuntime", platforms: [.macOS(.v14)], targets: [
    .target(name: "PikminRuntime"),
    .testTarget(name: "PikminRuntimeTests", dependencies: ["PikminRuntime"])
], swiftLanguageModes: [.v5])
SWIFT
for source in Core/CoordinatePasteParser.swift Core/RouteTraversal.swift Core/LocationNetworkPolicy.swift Core/OfflineDeviceBinding.swift Device/OfflineBindingMessages.swift Device/LocationSimulationSession.swift Core/CoordinateImportParser.swift Models/GPXRouteDocument.swift Core/MapCoordinateSystem.swift Core/PairingGuidePolicy.swift Core/DDIAssetSet.swift Services/DDIInstallationController.swift Services/DeveloperDiskImageService.swift Core/MovementMath.swift Services/WalkingSessionController.swift Services/FixedLocationSessionController.swift Models/WalkingSessionModels.swift; do
  cp "$ROOT/StikDebug/$source" "$BUILD/Sources/PikminRuntime/"
done
cp "$ROOT/PikminRuntimeTests/RuntimeDoubles.swift" "$BUILD/Sources/PikminRuntime/"
cp "$ROOT"/PikminRuntimeTests/*Tests.swift "$BUILD/Tests/PikminRuntimeTests/"
PIKMIN_BUNDLED_DDI_ROOT="$ROOT/Resources/DDI" swift test --package-path "$BUILD" --scratch-path "${PIKMIN_TEST_BUILD:-/tmp/pikmin-runtime-build}" "$@"
