// swift-tools-version: 5.9
import PackageDescription

// Independent host tests; the app's idevice binary is device-only.
let package = Package(
    name: "WLOCProbeValidation",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "WLOCProbeCore", targets: ["WLOCProbeCore"])],
    targets: [
        .target(name: "WLOCProbeCore", path: "WLOCProbeCore"),
        .testTarget(name: "WLOCProbeCoreTests", dependencies: ["WLOCProbeCore"], path: "WLOCProbeCoreTests")
    ]
)
