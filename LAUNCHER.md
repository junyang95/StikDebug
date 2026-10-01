# JIT启动器

JIT启动器 combines StikDebug-derived application/debugging tools, on-device remote
pairing, and an embedded LocalDevVPN tunnel in one application. The original
StikJIT framework remains a separate build target. The launcher is an integration
with its own interface and lifecycle management, not a verbatim copy of every
upstream StikDebug feature.

The app identifier stays **`com.stik.StikPair`** so replacement uploads match the
existing application. Its VPN extension is **`com.stik.StikPair.TunnelProv`**.
The display name is **JIT启动器**, or **JIT啟動器** in Traditional Chinese. English,
Simplified Chinese, and Traditional Chinese interfaces follow the system or the
app's language preference in iOS Settings.

## Application-list compatibility fix (2.0.1)

Installed-app refresh now reads the Bundle ID, display/fallback name, and
`get-task-allow` directly from typed libplist nodes. It no longer serializes the
entire installation-proxy record and reparses it with Foundation. Unrelated
metadata rejected by Foundation therefore cannot prevent an otherwise valid app
from appearing. Invalid required records are skipped individually; a nonempty
response with no readable application identifiers reports an explicit error.
Service/connection errors are still propagated.

Run `scripts/test-installed-applications.sh` on a Mac with host libplist and
pkg-config available. This compiles the production reader against the real C
API. Its regression fixture reproduces the old Foundation Cocoa 3840 failure
with unrelated deeply nested metadata, then verifies that required fields remain
readable and the app stays in the catalog. The fixture establishes the failure
mechanism; the user's exact device response was not captured. The host library
is not the device's Rust plist_ffi implementation, whose borrowed-pointer and
node-type semantics were separately checked against version 0.1.6.

## Four-tab workflow

| Tab | Current behavior |
| --- | --- |
| Applications / 应用 | Read the installed-app catalog, search names and Bundle IDs, filter debuggable apps, keep favorites/recent launches, choose an app-specific script, launch an app, or launch and enable JIT. |
| Setup / 配对引导 | Follow the seven pairing steps, view/copy the actual pairing PIN, import a remote pairing record when needed, connect the embedded VPN, and check/prepare the developer disk image (DDI). |
| Tools / 工具 | Manage scripts; inspect/terminate processes or enable JIT by PID; view JIT and system logs; read device metadata; inspect/import/export/remove provisioning profiles; simulate or restore device location. |
| Settings / 设置 | Control the local VPN, inspect/remove the pairing record, return to setup, open this app's system settings for language/permissions, and read upstream attribution/licenses. |

A launch without a stored pairing record opens Setup first. An existing
record opens Applications, but it does not imply that VPN or JIT preparation is
already ready. Complete connection/preparation before launching a target or
accepting an external JIT request. No separate StikDebug, StikPair, or LocalDevVPN
installation is required by this integrated workflow.

## Seven-step on-device pairing

On-device pairing requires **iOS/iPadOS 27 or later**, matching the
[device-initiated pairing requirement in idevice_pair](https://github.com/jkcoxson/idevice_pair#over-wi-fi-with-iphone-or-ipad).
The application and JIT framework target iOS/iPadOS 17.4 or later; earlier supported
systems use an imported RPPairing record instead of device-initiated pairing.

1. 点“开始本机配对” — Tap **Start on-device pairing**.
2. 保持 Wi-Fi 开启 — Keep **Wi-Fi** turned on.
3. 打开“设置” — Open **Settings**.
4. 进入“隐私与安全” — Enter **Privacy & Security**.
5. 打开“开发者模式” — Open **Developer Mode**.
6. 选择“与主机配对” → StikDebug — Select **Pair with Host → StikDebug**.
7. 输入通知中的 6 位配对码 — Enter the **six-digit code from the notification**.

**StikDebug is this app's advertised pairing host name**, not a request to install
another application. Allow local network and notification access when prompted.
The PIN comes from the pairing handshake; leading zeroes matter. Enter it in
Settings. A large PIN and a copy action are also available at the top of the guide.
Copying uses the local device's clipboard with a short expiration, not Universal
Clipboard. The guide does not mark Wi-Fi or Settings actions as completed because
the app cannot observe those actions. Completion means the handshake succeeded
and the resulting remote pairing record was validated and saved.

If Developer Mode is off, enable it and complete any system restart/confirmation,
then return and start pairing again. The launcher cannot switch on Wi-Fi or
Developer Mode. It does not use private Settings deep links: navigate manually
through the seven steps. The permission-help button opens **this app's settings**,
not the Developer Mode page. If notifications are unavailable, read the current
PIN in the launcher or enable notifications in that permissions page and retry.

Pairing receives finite background execution time while you switch to Settings.
iOS controls that time. Cancellation or expiration ends the advertisement,
interrupts the pairing connection, and removes pending/delivered PIN notifications.
Return to the launcher to start a new attempt; do not reuse an old PIN. A late
callback from an ended attempt cannot replace the saved record or update a newer
attempt.

### Import a record instead

Use the secondary **Import pairing file** section for older supported systems or
when on-device pairing is unavailable. Connect the unlocked device to a computer,
trust it, and use [idevice_pair](https://github.com/jkcoxson/idevice_pair#over-usb).
Choose **Remote pairing / RPPairing**, create/save the record, then transfer it
through Files or AirDrop. Legacy Lockdown pairing records are not accepted by this
framework. A record must belong to the device being used.

### Connect and prepare

After pairing, confirm Developer Mode and tap **Connect VPN and prepare JIT**.
Approve the system VPN configuration prompt. Preparation begins only after iOS
reports the tunnel connected. If it is already connected, the action becomes
**Check and prepare JIT**. The readiness section separately reports the saved
record, actual VPN status, and verified device/DDI readiness.

Preparation checks the device connection, downloads and mounts DDI when needed,
and verifies the result. The first download needs internet access and can take
several minutes; keep the app in the foreground. A connected VPN alone does not
prove that device services or JIT are ready. If another VPN prevents this local
tunnel from working, switch that VPN off and retry.

After preparation, the app refreshes the installed-app catalog. Select a target
in Applications, then use **Launch and enable JIT** or **Launch app**. The launcher
starts the selected Bundle ID and obtains its actual PID. Manual PID entry and
running-process selection remain available under Tools → Processes; refresh after
an app restarts because its PID changes. Invalid PIDs and the launcher's own
process are rejected.

## Application and script compatibility

The current application list uses placeholder icons; device icon loading has not
yet been connected to that list. This is separate from the launcher's own bundled
Home Screen icon.

The catalog reads `get-task-allow` from device-reported app entitlements. Apps
without it are shown as launch-only; having it is necessary but does not guarantee
that every app supports JIT on every iOS/device combination. On TXM/SPTM devices,
the target must implement the protocol expected by its selected script. The
launcher does not retrofit an app's allocator. See [INTEGRATION.md](INTEGRATION.md)
for the target-side JIT protocol.

The app bundles StikDebug's `universal.js`, `legacy.js`, `Geode.js`, and `maciOS.js`.
Script selection uses this order: an explicit assignment for the app, the upstream
app-name mapping, then the user's default script. It is no longer fixed to the
universal script. Bundled scripts are read-only; Tools → Scripts supports viewing,
creating, importing, editing, deleting, and choosing a default. Custom scripts are
UTF-8 `.js` files, at most 1 MiB each, with at most 100 custom files. Imports reject
file names containing path separators, symlinks, NUL bytes, and invalid text;
importing a script does not execute it.

The JavaScript host provides `get_pid`, `send_command`, `prepare_memory_region`,
`log`, and `hasTXM`. `hasTXM()` uses the framework's detected device capability;
an unknown result is an error rather than silently being treated as false.
**`resume_app()` and `take_screenshot()` are not implemented** in this runtime and
raise explicit errors. A process resume signal is not a replacement for upstream
`resume_app()` foreground-launch behavior. Scripts that depend on other upstream
host functions need adaptation; this is not a general StikDebug scripting API
compatibility guarantee.

On the script path, merely returning from JavaScript is not counted as JIT
success: the runtime requires acknowledged attachment, successful nonempty memory
preparation, and explicit detachment. Script/protocol errors trigger best-effort
debugger cleanup; a failed suspended launch also attempts to resume the target.
Non-TXM devices use the framework's acknowledged attach/detach path. These checks
confirm the observed protocol sequence, not successful execution of every target
app's JIT workload; that still needs a device test.

## Tools and external requests

- **Console:** JIT-operation messages and device syslog are separate sources.
  System logs support pause, search, and clear. Both pending batches and retained
  display lines are bounded. Leaving the console or backgrounding the app requests
  a stop. The bundled FFI cannot interrupt a pending `syslog_relay_next` read: the
  UI stays in **Stopping** until that read returns or the connection ends. Handles
  are released by the reader thread, and a second reader cannot start meanwhile.
- **Device information:** Reads metadata from the connected device. It is not
  populated by simulator fixtures.
- **Provisioning profiles:** Shows profile metadata and expiry, and supports
  import, export, and confirmed removal. A displayed expiry is not a claim that
  the signature is trusted or that an app has been refreshed. The device validates
  profile installation; these tools do not sign an IPA or renew a developer account.
- **Location:** Choose a map point or enter finite, in-range latitude/longitude,
  confirm the change, and use **Restore real location** when finished. Disconnecting
  VPN is not a location-reset action. This feature is a coordinate simulator; the
  Pikmin branch's walking routes, step writing, HealthKit, VIP/subscription and
  authorization features are not included.
- **Shortcuts:** The **Enable app JIT** action opens the launcher with a Bundle ID.
  Confirm the request in the app after completing pairing, VPN, and JIT preparation.
  It does not silently grant trust, prepare the device, or execute imported scripts.

Registered URL schemes are `jitlauncher` and `stikpair`, with these actions:

```text
jitlauncher://enable-jit?bundle-id=com.example.app
jitlauncher://launch-app?bundle-id=com.example.app
jitlauncher://kill-process?pid=1234
```

All external actions require in-app confirmation and the same readiness checks as
UI actions. App requests refresh the installed-app catalog before resolving the
target. Duplicate/unknown parameters, malformed Bundle IDs/PIDs, and externally
supplied scripts are rejected. Upstream `stikdebug://` links and all of StikDebug's
LiveContainer/URL workflows are not registered as interchangeable aliases here.

## Build, sign, and verify

1. Install Xcode and XcodeGen; run `xcodegen generate` at the repository root.
2. Open `StikJIT.xcodeproj` and choose the `JITLauncher` scheme.
3. Configure a signing team for **both** `JITLauncher` and `TunnelProv`. Preserve
   `JIT_LAUNCHER_BUNDLE_ID = com.stik.StikPair` in `Config/Signing.xcconfig` for the
   existing upload target. The extension identifier follows it with `.TunnelProv`.
4. Both provisioning profiles must permit Network Extensions with
   `packet-tunnel-provider`. Re-sign both app and extension without stripping that
   entitlement. An unsigned IPA cannot be installed and exercised as-is.
5. Build/install on a physical iPhone/iPad running a supported OS.

Unsigned build checks:

```sh
xcodegen generate
xcodebuild -project StikJIT.xcodeproj -scheme JITLauncher \
  -destination 'generic/platform=iOS' -derivedDataPath build/Launcher \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project StikJIT.xcodeproj -scheme JITLauncherPreview \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/Preview \
  CODE_SIGNING_ALLOWED=NO build
```

`JITLauncherPreview` uses the same SwiftUI interface without linking the
device-only idevice archive. It reports that VPN, pairing, device tools, and JIT
need real hardware; it does not fake successful connections or installed apps.
Run `scripts/test-launcher.sh` for host-side storage/input/protocol checks. These
checks and successful builds do not establish physical-device acceptance.

Signed-device verification remains required for VPN consent and extension launch,
Bonjour host visibility, real PIN notifications, pairing/expiry/cancellation,
DDI preparation, installed-app discovery and launch, each target/script JIT
combination, logs, profile changes, and location restoration. The on-device pairing
sequence specifically needs an iOS/iPadOS 27+ device. Review all three languages,
Dynamic Type, light/dark appearance, and compact iPhone/iPad layouts as well.

## Storage and execution lifecycle

Pairing records live in protected Application Support, excluded from backup, with
owner-only permissions. Imports are bounded at 5 MiB, parsed with the actual
RPPairing validator, and replaced atomically. On-device host identity metadata is
stored with its record. Private pairing contents and PINs are not logged.

The embedded VPN keeps upstream endpoints `10.7.1.1/32` (interface) and
`10.7.0.1/32` (peer), matching `10.7.0.1:49152` for device services. It manages only
profiles for this app's extension. User-editable routes and control of unrelated
VPN profiles are not part of the integration.

Blocking FFI work runs off the main thread. VPN loss, record changes, or revoking
the Developer Mode confirmation invalidates readiness. Generation/operation
checks prevent stale results from marking a changed connection ready. Other than
the cancellable pairing session, blocking native operations are not forcibly
interrupted: an expired background task reports failure while retaining ownership
until the worker returns. Background time and the debugger heartbeat do not
provide unlimited background execution.

## Source provenance

- StikJIT starting point: `32287268fa5824f9edce4cb359f5833ce0cf7b00`.
- StikDebug upstream main: `4bdfc92aa7cebd7a534f1e1ef56415f5727402de` (3.1.13),
  checked during this integration on 2026-10-01. Exact scripts and adapted service
  behavior are detailed in [ThirdParty/StikDebug/PROVENANCE.md](ThirdParty/StikDebug/PROVENANCE.md).
- LocalDevVPN: `af3fd697803ada4ac2b8d518358f5ab0a534844c`. Endpoints, CIDR validation,
  packet reflection, integration adaptations, and retained licenses are detailed
  in [ThirdParty/LocalDevVPN/PROVENANCE.md](ThirdParty/LocalDevVPN/PROVENANCE.md).
- The user's local `codex/pikmin-helper` pairing guide informed the seven-step
  presentation and readiness UX. Its unrelated product workflows were not merged.
