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

## Seven-step on-device pairing

On-device pairing requires **iOS/iPadOS 27 or later**, matching the
[device-initiated pairing requirement in idevice_pair](https://github.com/jkcoxson/idevice_pair#over-wi-fi-with-iphone-or-ipad).
This requirement applies only to starting pairing from Settings. The launcher and
JIT framework still support iOS/iPadOS 17.4 or later with an imported RPPairing
record.

1. 点“开始本机配对” — Tap **Start on-device pairing** in the launcher.
2. 保持 Wi-Fi 开启 — Keep **Wi-Fi** turned on.
3. 打开“设置” — Open **Settings**.
4. 进入“隐私与安全” — Enter **Privacy & Security**.
5. 打开“开发者模式” — Open **Developer Mode**.
6. 选择“与主机配对” → StikDebug — Select **Pair with Host → StikDebug**.
7. 输入通知中的 6 位配对码 — Enter the **six-digit pairing code from the notification**.

The app's display name remains **JIT启动器** (Traditional Chinese: **JIT啟動器**).
**StikDebug** is the host name advertised to Settings so it matches step 6. The
launcher requests local network and notification permission, advertises a
pairable host, and delivers the actual code produced by the pairing handshake in
a local notification. The code is entered in **Settings**, not in the launcher.
Leading zeroes are part of the code. Pairing is complete only after the handshake
succeeds and the resulting RPPairing record has been validated and saved.

If Developer Mode is off, enable it and complete any restart and confirmation
requested by iOS, then return to the launcher to start pairing again. The app
cannot turn on Wi-Fi or Developer Mode, or navigate directly to those Settings
pages. Open Settings manually and follow the guide. If notifications are denied,
enable them in the app's Settings page and retry so the code can be seen while
Settings is in front.

The launcher requests a finite amount of background time while you switch to
Settings. iOS controls the available time; it is not an unlimited pairing session.
If pairing expires, or if you cancel, return to the launcher and tap **Start
on-device pairing** again. A new attempt uses a new host identity and pairing code;
use only the current notification. Pending and delivered pairing notifications
are removed when the attempt ends.

### Import a pairing record when needed

For older supported versions, or when on-device pairing is unavailable, connect
the unlocked device to a computer, trust it, and use
[idevice_pair](https://github.com/jkcoxson/idevice_pair#over-usb). Select **Remote
pairing / RPPairing**, create a record, and save it to a file. Transfer it through
Files/AirDrop, then use the launcher's secondary **Import pairing file** action.
A legacy Lockdown record is not accepted by this version of the StikJIT framework.

### After pairing: connect VPN and prepare JIT

Tap **Connect** in the local VPN section and approve the system VPN configuration
prompt. The app installs and controls its own embedded packet tunnel. If another
VPN prevents connection, switch that VPN off in Settings and retry.

Tap **Prepare JIT**. The app checks device reachability and downloads/mounts the
appropriate developer disk image when needed. Initial preparation needs internet
access and may take time. Success is shown only after the framework verifies
readiness. VPN connection and JIT preparation are separate actions after the
seven pairing steps.

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
- Blocking StikJIT/FFI work runs off the main thread. The UI remains responsive.
  A finite iOS background task permits brief app switching; it does not promise
  indefinite background execution. See Apple's
  [background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
- Disconnecting the VPN, changing/removing the pairing record, or revoking the
  Developer Mode confirmation invalidates displayed readiness and process data.
- On-device pairing cancellation stops advertising and shuts down the active
  pairing socket so the handshake can return. Late callbacks from an ended
  attempt must not update a new attempt or replace its pairing record.
- Other JIT FFI operations cannot currently be cancelled mid-call. If iOS expires
  their background task, the app reports that condition and prevents overlapping
  work until the original operation returns. Reopen the launcher and prepare again.
- The app declares the fixed `_remotepairing-pairable-host._tcp` Bonjour service
  and its local network purpose. Fixed-service Bonjour advertisement does not
  require adding the multicast entitlement; see
  [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Verification

Run `scripts/test-launcher.sh` for host-side record-storage, PID, and network
configuration checks. Device and simulator builds check the actual app targets.
Visual checks should cover all three languages, dark mode, large Dynamic Type,
and narrow iPhone/iPad layouts.

Physical-device acceptance remains required for system VPN consent, signed
extension launch, Bonjour host visibility in Settings, notification delivery of
the real pairing code, pairing cancellation/background expiry, real pairing,
DDI preparation, process discovery, and target JIT. On-device pairing needs an
iOS/iPadOS 27 or later device. An unsigned build or simulator preview cannot
verify those behaviors.

## Source provenance

The original StikJIT base is `32287268fa5824f9edce4cb359f5833ce0cf7b00`.
The VPN integration uses LocalDevVPN
`af3fd697803ada4ac2b8d518358f5ab0a534844c`, including its default endpoints,
CIDR validator, and packet-reflection provider. The host manager and SwiftUI
launcher are newly written. Provider lifecycle and packet-buffer safety adaptations
are documented with the retained upstream license in `ThirdParty/LocalDevVPN`.
