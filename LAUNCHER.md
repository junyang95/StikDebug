# JIT启动器

This branch turns the framework repository into a project with both its original
framework and a standalone launcher. The launcher enables JIT for **another
running process**. It does not debug itself or automatically retrofit a target
app's JIT allocator.

## Build and sign

1. Install Xcode and XcodeGen, then run `xcodegen generate` at the repository root.
2. Open `StikJIT.xcodeproj` and select the `JITLauncher` scheme.
3. Set your signing team for **both** `JITLauncher` and `TunnelProv`. Configure a
   unique `JIT_LAUNCHER_BUNDLE_ID` through the supplied signing configuration or
   build settings. The extension identifier must be the app identifier followed
   by `.TunnelProv`.
4. Ensure both signing profiles permit the Network Extensions capability with
   `packet-tunnel-provider`. Signing only the app, or stripping this entitlement
   while re-signing, prevents the embedded VPN from starting.
5. Build to a physical iPhone/iPad running iOS/iPadOS 17.4 or later.

An unsigned device compile can be checked with:

```sh
xcodegen generate
xcodebuild -project StikJIT.xcodeproj -scheme JITLauncher \
  -destination 'generic/platform=iOS' -derivedDataPath build/Launcher \
  CODE_SIGNING_ALLOWED=NO build
```

The `JITLauncherPreview` scheme builds the same SwiftUI interface for an iOS
simulator without linking the device-only Rust/idevice static library. It explicitly
reports that VPN, pairing validation, and JIT require a physical device. It never
simulates a successful VPN connection or successful JIT session.

```sh
xcodebuild -project StikJIT.xcodeproj -scheme JITLauncherPreview \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/Preview \
  CODE_SIGNING_ALLOWED=NO build
```

`JIT启动器` is the default and Simplified Chinese display name; Traditional Chinese
uses `JIT啟動器`. Interface language follows the system or the app's preferred
language in iOS Settings. English remains available.

## Four-step setup

1. **Developer Mode.** Enable it under Settings → Privacy & Security, complete
   the reboot/confirmation, then confirm that step in the launcher. This toggle
   records the user's confirmation; it is not an automatic entitlement or
   Developer Mode check.
2. **Pairing record.** Connect the unlocked device to a computer, trust the
   computer, and use [idevice_pair](https://github.com/jkcoxson/idevice_pair#over-usb).
   Select **Remote pairing / RPPairing**, create a record, and save it to a file.
   Transfer it through Files/AirDrop and import it in the launcher. A legacy
   Lockdown record is not accepted by this version of the StikJIT framework.
3. **Local VPN.** Tap Connect and approve the system VPN configuration prompt.
   The app installs and controls its own embedded packet tunnel. If another VPN
   prevents connection, switch that VPN off in Settings and retry.
4. **Prepare JIT.** The app checks device reachability and downloads/mounts the
   appropriate developer disk image when needed. Initial preparation needs
   internet access and may take time. Success is shown only after the framework
   verifies readiness.

Open the target app so its process exists, return to the launch tab, refresh the
process list, select the target, and enable JIT. Manual PID entry is also available.
PIDs change when an app restarts; refresh before retrying. The launcher rejects
zero, negative, out-of-range, and its own PID.

The target app must be signed with `get-task-allow`. On systems where TXM/SPTM is
present, it must implement the bundled universal script's protocol. The launcher
does not inspect other apps' entitlements before connection; debugger rejection is
reported as an error. Apps requiring a different script need a separate integration
change; this launcher uses the universal script consistently. See
[INTEGRATION.md](INTEGRATION.md) for the target-side protocol.

## Storage and lifecycle

- Pairing data is stored only in protected Application Support, excluded from
  backup, with owner-only file permissions. Contents are never included in logs.
- Import validates a bounded property list (5 MiB maximum) and the framework's
  actual RPPairing parser before atomically replacing a previous valid record.
- The VPN uses upstream defaults `10.7.1.1/32` (interface), `10.7.0.1/32` (peer),
  matching StikJIT's `10.7.0.1:49152` endpoint. This integration deliberately has
  no editable routes that could desynchronize these two components.
- Only profiles matching this app's extension identifier are selected. The app
  does not remove or stop profiles belonging to other apps.
- All blocking StikJIT/FFI work runs on one dedicated serial background queue.
  The UI remains responsive. A finite iOS background task permits brief app
  switching; it does not promise indefinite background execution.
- Disconnecting the VPN, changing/removing the pairing record, or revoking the
  Developer Mode confirmation invalidates displayed readiness and process data.
- FFI operations cannot currently be cancelled mid-call. If iOS expires the
  background task, the app reports that condition and prevents overlapping work
  until the original operation returns. Reopen the launcher and prepare again.

## Verification

Run `scripts/test-launcher.sh` for host-side record-storage, PID, and network
configuration checks. Device and simulator builds check the actual app targets.
Visual checks should cover all three languages, dark mode, large Dynamic Type,
and narrow iPhone/iPad layouts.

Physical-device acceptance remains required for system VPN consent, signed
extension launch, real pairing, DDI preparation, process discovery, and target JIT.
An unsigned build or simulator preview cannot verify those behaviors.

## Source provenance

The original StikJIT base is `32287268fa5824f9edce4cb359f5833ce0cf7b00`.
The VPN integration uses LocalDevVPN
`af3fd697803ada4ac2b8d518358f5ab0a534844c`, including its default endpoints,
CIDR validator, and packet-reflection provider. The host manager and SwiftUI
launcher are newly written. Provider lifecycle and packet-buffer safety adaptations
are documented with the retained upstream license in `ThirdParty/LocalDevVPN`.
