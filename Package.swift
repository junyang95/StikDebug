// swift-tools-version: 5.9
import PackageDescription

// Independent host tests; the app's idevice binary is device-only.
let package = Package(
    name: "WLOCProbeValidation",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "WLOCProbeCore", targets: ["WLOCProbeCore"])],
    dependencies: [
        // Xcode 16.2 / Swift 6.0 compatible; do not float to newer toolchain requirements.
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.18.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.3.1")
    ],
    targets: [
        .target(name: "WLOCProbeCore", path: "WLOCProbeCore"),
        .testTarget(name: "WLOCProbeCoreTests", dependencies: ["WLOCProbeCore"], path: "WLOCProbeCoreTests"),
        .target(name: "WLOCCertificateCore", dependencies: ["WLOCProbeCore", .product(name: "X509", package: "swift-certificates")], path: "WLOCCertificateCore"),
        .testTarget(name: "WLOCCertificateCoreTests", dependencies: ["WLOCCertificateCore", "WLOCProbeCore", .product(name: "X509", package: "swift-certificates")], path: "WLOCCertificateCoreTests")
    ]
)
