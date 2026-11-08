# StikJIT

## JIT启动器 — integrated iOS app

This branch adds **JIT启动器** (2.0.9, build 20), a standalone SwiftUI app integrating
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

Version 2.0.9 adds an **offline device binding**. The signing service supplies
`wowdevice.plist` for one device; the client verifies its signature using a fixed
public key and matches it to the actual connected device's lockdown
`UniqueDeviceID` on every newly opened paired tunnel, before device operations.
The identifier stays local: no website authorization request, VIP state, license
expiry or persistent access cache is used. Opening the app and pairing setup
remain available without a credential. Missing, invalid or mismatched credentials
block protected device functions with a clear error. Recovery of a suspended
process and clearing simulated location remain available through a working
paired connection.

Both developer disk image (DDI) families remain included in the IPA; preparation
copies and verifies the selected bundled files before mounting them.

Version 2.0.6 adds an **External VPN** connection mode in Setup and Settings.
Start LocalDevVPN with its default configuration, select External VPN, and check
and prepare JIT. Compatible loopback VPNs exposing the same device endpoint are
also usable. External mode never starts the built-in VPN; it checks the actual
paired device connection before device operations. An ordinary internet VPN is
not sufficient.

Version 2.0.5 imports pairing files as local copies supplied by the system document
picker. Read, validation, save, and busy-state failures now have distinct feedback;
a failed replacement preserves the previous pairing record. iOS/iPadOS 26 and other
supported systems below 27 show the computer pairing guide directly, including the
[idevice_pair download page](https://app-shop.cn/app/106). Use USB **Remote Pairing /
RPPairing**, save the record to Files, import it, then connect the VPN and prepare JIT.
On-device pairing still requires iOS/iPadOS 27. Copy import improves file-provider
compatibility; it does not bypass signing or sandbox checks.

Version 2.0.4 requires an available Wi-Fi path before pairing, VPN connection,
device verification, DDI preparation or new JIT operations. It shows Wi-Fi
readiness, blocks cellular-only connections, rechecks after foreground entry,
and cancels pending work when Wi-Fi disappears while retaining verified DDI
files. Real-location restoration
remains a recovery exception when the existing local device connection works.

The IPA includes eight DDI files across the Personalized and Cryptex families
(33,239,188 bytes, about 31.7 MiB before IPA compression). Their source is pinned
to `doronz88/DeveloperDiskImage` commit
`6eae353ae694bda1c421d4a3eee5459ae59c99a1`, build `27A5228h`. The bundled catalog
records each file's size and SHA-256. Preparation selects the family for the
running OS, copies the complete group into the local cache, verifies it, and
mounts it when needed. Missing or corrupt bundled files report an error; DDI
preparation has no remote download or fallback.

Settings includes **Restore bundled developer image**, which rebuilds the cache
from the IPA while preserving the pairing record. Changing the bundled DDI
version requires an app update. Apple's device personalization or mounting
protocol may still need network access; bundling the image does not guarantee
that the whole JIT setup can complete offline. Physical-device mounting and a
target JIT run remain necessary to verify compatibility.

Opening the app shows the application library. Setup and device tools require
no website account or VIP membership. Protected device operations require a valid
per-device offline credential. Pairing, Developer Mode, available Wi-Fi, a working
loopback VPN and DDI mounting remain the technical requirements for JIT.
The connected device identifier is read locally and is not uploaded by binding checks.
Restoring real location remains available when the existing local device
connection works.

The unsigned source IPA intentionally contains no `wowdevice.plist`. It can be
opened for setup but cannot run protected device functions until the signing
service adds a valid device-specific credential. The main app declares
`WowOfflineDeviceBinding` with product `jit-launcher`; the old
`WowNativeDeviceAccess`/VIP guard must remain absent. Shared enterprise packages
cannot serve multiple devices with one credential. This is an application-level
binding, not a claim of resistance to binary modification. See
[LAUNCHER.md](LAUNCHER.md#offline-device-binding-and-distribution) for the exact
format, signing contract and recovery behavior.

A separate StikDebug, StikPair or LocalDevVPN app is not needed for these integrated
workflows. On-device pairing requires iOS/iPadOS 27 or later; on earlier supported
versions, import a Remote pairing / RPPairing record from a computer. The launcher
and framework support iOS/iPadOS 17.4 or later. JIT still requires a compatible,
properly signed target app; integration does not remove platform requirements.

The pairing guide follows this sequence: start on-device pairing, keep Wi-Fi on,
open Settings, enter Privacy & Security, open Developer Mode, select Pair with
Host → **StikDebug**, and enter the six-digit code from the launcher's notification.
**StikDebug** is the advertised host name; the app remains **JIT启动器**. After
pairing, use the built-in VPN or select External VPN after connecting LocalDevVPN,
then prepare JIT in the launcher.

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
The pairing guide references the user's `codex/pikmin-helper` working tree without
modifying that branch. HealthKit and walking/step-writing features are not
included. Its separate subscription workflow is unchanged.

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
