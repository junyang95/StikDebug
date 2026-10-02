# StikJIT

## JIT启动器 — integrated iOS app

This branch adds **JIT启动器** (2.0.4, build 15), a standalone SwiftUI app integrating
StikDebug's installed-app launch/JIT workflow and device tools, on-device pairing,
the StikJIT engine, and [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN).
Four tabs cover applications, the seven-step pairing guide, debugging tools, and
settings. Features include app search/favorites/recent history, per-app script
selection, four bundled upstream scripts, custom script import/editing, process
control, device logs, device information, provisioning profiles, location
simulation, and confirmed Shortcut/URL requests. English, Simplified Chinese and
Traditional Chinese are included. The app identifier remains **com.stik.StikPair**.
The application list shows only targets with `get-task-allow`, excludes the
launcher itself, and loads their real icons from the device. An unavailable icon
uses a fallback without preventing the rest of the list from loading.

Version 2.0.4 requires an available Wi-Fi path before pairing, VPN connection,
device verification, DDI preparation or new JIT operations. It shows Wi-Fi
readiness, blocks cellular-only connections, rechecks after foreground entry,
and cancels pending work when Wi-Fi disappears while retaining verified DDI
files. Download requests disallow cellular handoff. Real-location restoration
remains a recovery exception when the existing local device connection works.

Version 2.0.3 addresses downloads that appear stuck at **Downloading developer
disk image**. It shows transferred bytes and progress, uses a versioned Qiniu
mirror with a fixed upstream fallback, bounds connection/stall times, and verifies
the complete DDI file group before replacing cached files. Settings includes
**Download developer image again**, preserving the pairing record. The bundled
asset catalog pins upstream commit `6eae353ae694bda1c421d4a3eee5459ae59c99a1`
(build `27A5228h`); publishing new server files does not silently change that pin.
Release preparation must upload the versioned mirror and verify its public
URLs, sizes, and hashes before distributing the corresponding app.

Cryptex mounting was already present in 2.0.2, with the same relevant FFI/core
as pinned StikDebug 3.1.13. The
[StikDebug 3.1.11 release](https://github.com/StikDebug/StikDebug/releases/tag/3.1.11)
introduced that mounting path to address iPhone 18 Pro compatibility. This release
repairs download handling, rather than introducing cryptex support. A successful
download still needs physical-device mounting and target JIT verification.

Protected new operations require an online check of the actual device UDID with
**wow-app.store** over HTTPS. Sign in to the website in Safari and complete device
identification first: the check requires an existing device registration and a
fresh, signed non-ban result. VIP is not required, and expired VIP is allowed.
The app uses two existing website endpoints; no backend change or deployment is
part of this release. It checks the registration record, not a current browser
session or a separate last-login timestamp. Failed checks block new protected
operations, and no offline permission is cached. Restoring real location remains
available for recovery when the local device connection works. A later ban cannot
revoke JIT already acquired by another process. See [LAUNCHER.md](LAUNCHER.md) for
the verification contract and limits.

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
`4bdfc92aa7cebd7a534f1e1ef56415f5727402de` (3.1.13, fetched 2026-10-01;
remote main reconfirmed with `git ls-remote` on 2026-10-02).
The combined launcher and StikDebug-derived additions are distributed under
AGPL-3.0 with corresponding source. See
[`ThirdParty/StikDebug`](ThirdParty/StikDebug) for attribution and scope.
The pairing guide and signed-license verification reference the user's
`codex/pikmin-helper` working tree without modifying that branch. This launcher's
device-registration policy is separate from its VIP/subscription policy; HealthKit
and walking/step-writing features are not included.

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

The original StikJIT framework is licensed under MPL-2.0 (see [`LICENSE`](LICENSE)).
The integrated launcher's AGPL-3.0 distribution and retained component notices are
described above. The bundled [idevice](https://github.com/jkcoxson/idevice) and
upstream scripts retain their own licenses.
