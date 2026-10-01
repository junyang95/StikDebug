# StikJIT

## JIT启动器 — integrated iOS app

This branch adds **JIT启动器** (2.0.0), a standalone SwiftUI app integrating
StikDebug's installed-app launch/JIT workflow and device tools, on-device pairing,
the StikJIT engine, and [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN).
Four tabs cover applications, the seven-step pairing guide, debugging tools, and
settings. Features include app search/favorites/recent history, per-app script
selection, four bundled upstream scripts, custom script import/editing, process
control, device logs, device information, provisioning profiles, location
simulation, and confirmed Shortcut/URL requests. English, Simplified Chinese and
Traditional Chinese are included. The app identifier remains **com.stik.StikPair**.

A separate StikDebug, StikPair or LocalDevVPN app is not needed for these integrated
workflows. On-device pairing requires iOS/iPadOS 27 or later; on earlier supported
versions, import a Remote pairing / RPPairing record from a computer. The launcher
and framework support iOS/iPadOS 17.4 or later. JIT still requires a compatible,
properly signed target app; integration does not remove platform requirements.

The pairing guide follows this sequence: start on-device pairing, keep Wi-Fi on,
open Settings, enter Privacy & Security, open Developer Mode, select Pair with
Host → **StikDebug**, and enter the six-digit code from the launcher's notification.
**StikDebug** is the advertised host name; the app remains **JIT启动器**. After
pairing, connect the built-in VPN and prepare JIT in the launcher.

Run `xcodegen generate`, open `StikJIT.xcodeproj`, and select the **JITLauncher**
scheme to build for a physical device. See [LAUNCHER.md](LAUNCHER.md) for signing,
setup, validation, simulator preview, and known platform requirements.

The original StikJIT framework and its scheme remain available below.

### Attribution

StikDebug features and scripts are adapted from main commit
`4bdfc92aa7cebd7a534f1e1ef56415f5727402de` (3.1.13, fetched 2026-10-01).
The combined launcher and StikDebug-derived additions are distributed under
AGPL-3.0 with corresponding source. See
[`ThirdParty/StikDebug`](ThirdParty/StikDebug) for attribution and scope.
The pairing guide also draws on the user's `codex/pikmin-helper` working tree,
without modifying that branch or importing its unrelated product features.

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
