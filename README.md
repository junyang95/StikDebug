# StikJIT

## JIT启动器 — integrated iOS app

This branch adds **JIT启动器**, a standalone SwiftUI launcher that combines StikJIT
with the local packet tunnel from [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN).
The launcher has a four-step pairing guide, an integrated VPN connect/disconnect
control, running-process selection, and English, Simplified Chinese, and Traditional
Chinese interfaces. A separate LocalDevVPN installation is not required.

Run `xcodegen generate`, open `StikJIT.xcodeproj`, and select the **JITLauncher**
scheme to build for a physical device. See [LAUNCHER.md](LAUNCHER.md) for signing,
setup, validation, simulator preview, and known platform requirements.

The original StikJIT framework and its scheme remain available below.

### Attribution

The integrated VPN **uses code from LocalDevVPN**, based on StosVPN by the SideStore
Team and contributors. It is an independently named integration, not an official
LocalDevVPN release. Upstream source is pinned to
`af3fd697803ada4ac2b8d518358f5ab0a534844c` (verified against upstream main on
2026-10-01). Original notices and the license are preserved in
[`ThirdParty/LocalDevVPN`](ThirdParty/LocalDevVPN).

## StikJIT framework

An iOS XCFramework that enables JIT for another process over the device's RSD tunnel.

StikJIT is self-contained and bundles the idevice FFI and its JIT scripts.

## Integration

For iOS 26 JIT support, StikDebug URL integration, Built-in StikJIT setup, API usage, requirements, and recommended app settings, see [Integrating StikJIT](INTEGRATION.md).

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/StephenDev0/StikJIT)

## Build

```sh
xcodegen generate
xcodebuild archive -scheme StikJIT -destination 'generic/platform=iOS' \
  -archivePath build/StikJIT BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO
xcodebuild -create-xcframework \
  -framework build/StikJIT.xcarchive/Products/Library/Frameworks/StikJIT.framework \
  -output StikJIT.xcframework
```

## License

StikJIT is licensed under the MPL-2.0 (see [`LICENSE`](LICENSE)). It uses StikDebug as a reference, with the bundled [idevice](https://github.com/jkcoxson/idevice), universal.js, and legacy.js retaining their own licenses.
