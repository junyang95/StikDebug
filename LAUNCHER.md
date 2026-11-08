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

## Current release: 2.0.9 (20)

Version 2.0.9 binds the package to one device with a signed offline credential.
Each new paired tunnel verifies that credential and compares its device identifier
with `UniqueDeviceID` read from that same connection's lockdown service, before
performing protected device operations. Pairing setup and normal browsing remain
available. Missing credentials, invalid signatures and wrong devices fail closed
with English, Simplified Chinese and Traditional Chinese explanations.
There is no website authorization request, VIP interface, persistent access grant
or license deadline. Both DDI families remain included in the IPA.

## Connection and import changes retained from 2.0.6 (17)

Setup and Settings now offer **Built-in VPN** and **External VPN** connection
modes. External mode accepts a working LocalDevVPN default connection or another
compatible loopback VPN at the same device endpoint. It does not require this
app’s tunnel extension to report connected and never starts the built-in VPN.
Paired-device communication is checked before device operations. External status
describes the last successful paired-device check, not another app’s VPN profile
status.

Pairing files now use system copy import, bounded snapshot reads, and explicit
failure feedback without replacing the last valid record on error. On iOS/iPadOS
26 and other supported versions below 27, setup leads with computer USB pairing
and the idevice_pair download link. On-device pairing remains an iOS/iPadOS 27+
feature. See the import section below for the workflow and signing limitations.

The developer images now ship inside the IPA. Preparation shows local copy and
verification progress, and Settings provides **Restore bundled developer image**
without removing pairing. The bundled asset and cache contract is described below.

Cryptex mounting uses the relevant FFI and mounting core from pinned StikDebug
3.1.13. The [3.1.11 release notes](https://github.com/StikDebug/StikDebug/releases/tag/3.1.11)
describe cryptex mounting for the iPhone 18 Pro series and persistence across
reboots on iOS 26.4 and later. The package change does not establish successful
mounting or JIT on a physical device.

## Application icons (retained from 2.0.2)

The Applications tab now shows only device-reported debuggable targets, loads
their real icons through SpringBoard services, and excludes the launcher itself.
The application-list compatibility fix below remains included. Device commands
use the local paired connection without a website registration check.

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
| Applications / 应用 | Show debuggable apps with device icons, search names and Bundle IDs, keep favorites/recent launches, choose an app-specific script, launch an app, or launch and enable JIT. |
| Setup / 配对引导 | Follow the seven pairing steps, view/copy the actual pairing PIN, import a remote pairing record when needed, choose the embedded or an external VPN, and check/prepare the developer disk image (DDI). |
| Tools / 工具 | Manage scripts; inspect/terminate processes or enable JIT by PID; view JIT and system logs; read device metadata; inspect/import/export/remove provisioning profiles; simulate or restore device location. |
| Settings / 设置 | Choose a connection mode, control the built-in VPN or check the external connection, restore the bundled developer image, inspect/remove the pairing record, return to setup, open this app's system settings for language/permissions, and read upstream attribution/licenses. |

Every launch opens Applications without automatically starting pairing or VPN
preparation. Open Setup to begin. An existing pairing record does not imply that
the connection or JIT preparation is ready. Complete
connection/preparation before launching a target or accepting an external JIT
request. No separate StikDebug, StikPair, or LocalDevVPN
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
Clipboard. The seven instructions do not claim that manual Settings actions were
completed. Wi-Fi readiness is shown separately from the observed network path.
Pairing completion means the handshake succeeded
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

On iOS/iPadOS 26 and other supported systems below 27, the setup page shows the
computer pairing guide and import button directly. On iOS/iPadOS 27, use the
secondary **Import pairing file** section when preferred. The app links to the
[idevice_pair download page](https://app-shop.cn/app/106); open that page on your
computer to download the tool. Connect the unlocked device by USB, trust the
computer, and follow the [upstream USB guide](https://github.com/jkcoxson/idevice_pair#over-usb).
Choose **Remote pairing / RPPairing**, create/save the record, then transfer it
through Files or AirDrop. Legacy Lockdown pairing records are not accepted by this
framework. A record must belong to the device being used. After importing, enable
Developer Mode, connect the local VPN, and prepare JIT.

The system picker uses `asCopy: true`. Its temporary local copy is consumed while
the delegate callback is active, read into a bounded snapshot (with coordination for external URLs), and
validated before an atomic replacement in private Application Support. Cancelling
the picker leaves the existing record unchanged. Busy operations and read,
validation, or save errors are shown explicitly; diagnostic text contains error
codes rather than private paths or record contents.

Copy import is not a sandbox or signing bypass. When comparing re-signing options,
check each final app/extension identity and profile, and test the same file on the
same device while idle. Build and host tests do not establish physical-device
acceptance of mismatched signatures.

### Connect and prepare

Connect to a Wi-Fi network before starting pairing or preparing the device.
The launcher monitors `NWPathMonitor(requiredInterfaceType: .wifi)` and admits new
operations only when the path is satisfied and uses Wi-Fi. Turning on the radio
without a usable connection, cellular-only access, and a VPN alone do not meet
this prerequisite. The public API checks availability, not the Wi-Fi switch,
SSID, or internet-server reachability; no location permission is requested.
Unknown state blocks new actions until the first current path update. Foreground
entry discards stale path state. Losing Wi-Fi invalidates preparation, cancels
pairing and pending work, and reports an actionable connection message.
Already-entered native calls must unwind before a new operation can begin.
Existing verified DDI caches are retained. Disconnecting the VPN, importing a
record, and restoring real
location through an existing local connection remain available for recovery.

After pairing, confirm Developer Mode and choose a connection mode in Setup or
Settings:

- **Built-in VPN** (default): tap **Connect VPN and prepare JIT** and approve the
  system VPN configuration prompt. Preparation waits for the owned tunnel to
  connect. If it is already connected, use **Check and prepare JIT**.
- **External VPN**: first connect LocalDevVPN with its default configuration (or
  another compatible loopback VPN), return to the launcher, select External VPN,
  then tap **Check and prepare JIT**. Settings also provides an external connection
  check. This mode does not create, start, or disconnect VPN profiles.

The external route must expose the paired device at `10.7.0.1:49152`; arbitrary
internet VPNs and custom LocalDevVPN peer addresses are not supported by this
release. The app cannot read another app’s VPN status. A successful paired
device-service handshake validates the connection; a TCP connection alone is not
proof. The check also verifies the offline credential against the actual target's
lockdown UDID, without contacting a website. A status check never authorizes a
later independent tunnel: each actual operation's new tunnel checks again.
Failed device communication clears external readiness and asks the user to check the external
VPN and pairing record. Switching connection mode or
returning from the background invalidates external readiness for a fresh check.
The readiness section separately reports the saved record, connection status,
and verified device/DDI readiness.

Preparation checks the paired device connection, installs the selected bundled
DDI when its local cache is missing or invalid, mounts it when needed, and verifies
the result. Keep the app in the foreground. Apple's device personalization or
mounting protocol may still need network access. A connected VPN alone does not
prove that device services or JIT are ready. If an unrelated VPN prevents the
selected loopback connection from working, switch that VPN off and retry.

After preparation, the app refreshes the installed-app catalog. Select a target
in Applications, then use **Launch and enable JIT** or **Launch app**. The launcher
starts the selected Bundle ID and obtains its actual PID. Manual PID entry and
running-process selection remain available under Tools → Processes; refresh after
an app restarts because its PID changes. Invalid PIDs and the launcher's own
process are rejected.

### Bundled DDI installation and recovery

`Resources/DDIAssets.json` pins the DDI release to
`doronz88/DeveloperDiskImage` commit
`6eae353ae694bda1c421d4a3eee5459ae59c99a1`, build `27A5228h`. It contains the
revision, family directories, expected byte counts and SHA-256 hashes; it has no
remote download addresses.

The framework bundles the complete `Resources/DDI` directory, preserving these
two subdirectories:

| Running system | Bundled directory | Required files |
| --- | --- | --- |
| iOS/iPadOS 17.4–26.3 | `Xcode_iOS_DDI_Personalized` | `BuildManifest.plist`, `Image.dmg`, `Image.dmg.trustcache` |
| iOS/iPadOS 26.4 and later | `Xcode_iOS_DDI_Cryptex` | The same three names plus `Image.dmg.cryptex_info` and `Image.dmg.root_hash` |

The eight files total 33,239,188 bytes (about 31.7 MiB before IPA compression).
Normal preparation first checks whether the system already has a mounted DDI.
When mounting is needed, it reuses a valid local cache or copies the selected
family from the framework bundle into a temporary directory. Every file must
match the catalog's size and hash before cache replacement begins. A completion
receipt is written last. Cache reuse checks the receipt, revision, family and all
file hashes, so incomplete, mixed or stale groups cannot be reported ready.

Copying and verification support cancellation. Once cache replacement starts, it
finishes as one transaction; a failed commit restores the previous cache. A missing
or corrupt bundled resource produces an explicit installation error; there is no
network download
or fallback source. The image can be restored only from the installed package.
Keep the previous valid cache until the new group has passed verification.

To rebuild the cache, connect the selected loopback VPN and choose **Settings →
Developer image → Restore bundled developer image**. Pairing and Developer Mode
must be ready. This copies and verifies the bundled group even if the system
already has a mounted DDI, then checks/prepares the device. It preserves pairing
and does not forcibly unmount the system's existing DDI.

The file installation step uses no network. Apple's personalization or mounting
protocol may still need network access, and pairing, Developer Mode, Wi-Fi and a
working loopback connection remain required. Bundling files does not establish
successful physical-device mounting or target JIT operation.

A DDI update requires replacing both packaged families and their matching catalog,
then rebuilding the app. Before distribution, inspect the archived framework and
IPA for all eight files with the recorded sizes and hashes. Preserve the directory
structure and third-party notices. If the installed package itself is incomplete
or corrupt, install a verified replacement package rather than retrying a remote
source.

## Offline device binding and distribution

The main app's `Info.plist` declares `WowOfflineDeviceBinding`:

```plist
{ schema: 1, product: "jit-launcher",
  keyId: "9a6a40f263ac458839e9a4fe6973cee315e10111e1ffd30425788491deefe607" }
```

The marker describes the signing contract. The verifier uses the compiled P-256
public key and the hardcoded product `jit-launcher`; changing Info.plist cannot
replace the trust anchor or change the product accepted by the client. The
private key stays on the signing service.

The signer adds a main-app resource named `wowdevice.plist`. It contains exactly
`payload` and `sig` strings. `payload` is base64 of the exact signed UTF-8 JSON;
`sig` is base64 of a DER-encoded P-256/SHA-256 ECDSA signature over those bytes.
The JSON fields are:

```json
{"schema":1,"purpose":"wow.offline-device-binding","product":"jit-launcher","udid":"00008110-000a010203040506"}
```

The example identifier is illustrative. A credential's UDID must be lowercase;
actual device identifiers are normalized locally before comparison. Do not
reformat the JSON between signing and verification. Other products, malformed
credentials, invalid signatures and unsupported schemas are rejected.

The unsigned source IPA intentionally has the marker but no credential; the
signing service must issue one for the intended device before the protected
functions are usable. A missing credential does not unlock a development mode.
A single shared enterprise-signed package cannot satisfy this per-device
binding for multiple devices. Keep old `WowNativeDeviceAccess`, `PikminNativeVIP`,
WowVipGuard injection, online authorization requests and legacy license hints
out of these packages. The server must validate the marker's schema, product and
key ID before signing, and must fail on a key mismatch. This source change does
not itself deploy the server.

Device identity comes from **the actual connected target**, not the local
pairing record or the launcher host's identifier. `DeviceTunnelFactory` opens the
paired tunnel, verifies the credential, reads only lockdown `UniqueDeviceID` over
that same adapter/handshake, compares the IDs, and returns the connection only on
success. JIT, scripts, application launch/listing, process commands, DDI checks and
mounts, logs, profiles and new location sessions all pass through this gate.
The deprecated no-DDI JIT entry point follows the same connection gate. The
optional script heartbeat cannot silently ignore a binding rejection.

No global success flag or persistent permit cache grants access to later
connections. A live location session can reuse its already-checked connection;
its pairing-content digest and endpoint identify that connection. Replacing the
record or reconnecting requires another check. Recovery connections are internal
and restricted to the public **resume process (SIGCONT only)** and **clear
simulated location** operations. Clearing location closes its recovery connection,
so it cannot be reused to set a new simulated location. Debugger detach/cleanup
on an existing connection does not require a new credential check.

Pairing-file validation/import, on-device pairing, VPN setup, local DDI cache
restoration and browsing remain available. Pairing, Developer Mode, Wi-Fi, the
selected loopback VPN and required DDI mounting are still technical prerequisites.
The binding check itself is local and sends no UDID or license request to a
website. Apple's pairing, personalization or mounting protocols retain their
existing behavior. Cancellation and operation-generation checks remain in force.
Shortcut and URL actions still require confirmation.

This is application-level device binding. It does not claim to resist a modified
binary, a patched verifier or compromised device services. Verify a signed package
on its intended physical device and verify denial on a different connected device
before claiming end-to-end acceptance. The simulator preview never invokes the
real device framework.

Run `scripts/test-offline-device-binding.sh` for the shared cryptographic format
checks and `scripts/test-device-binding.sh` for the actual connection factory,
typed lockdown reader, fail-closed errors, per-connection checks, cancellation,
handle cleanup and public recovery APIs. The latter uses a temporary test key and
simulated transport with real CryptoKit/libplist; it does not use the production
private key or establish physical-device JIT success.

## Application and script compatibility

The application list fetches real icons from the connected device's SpringBoard
services as rows or details become visible. Loading runs off the main thread,
produces bounded thumbnails, and uses a bounded in-memory cache. A missing,
invalid, or unreadable icon falls back to a generic symbol without failing the
catalog. This is separate from the launcher's own bundled Home Screen icon.

The catalog reads `get-task-allow` from device-reported app entitlements. The
Applications tab includes only apps with that entitlement and excludes this
launcher; both ordinary launch and launch-with-JIT are available for those
targets. Having the entitlement is necessary but does not guarantee that every
app supports JIT on every iOS/device combination. On TXM/SPTM devices,
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
JIT mode considers both TXM and the target application's protocol. TXM devices
run the selected script. Ordinary non-TXM targets use acknowledged attach/detach.
On iOS 26 and newer, Amethyst and the remastered Air build instead require the
selected Universal JIT script even without TXM: their mirrored allocator calls
the debugger to prepare executable regions. The launcher recognizes Amethyst
names and Air's `com.air-devs.air` identity (including signing suffixes), maps
them to `universal.js`, and forwards that requirement with `forceScript`.
Explicit per-app script assignments still take precedence; choosing the global
default `universal.js` alone does not force every non-TXM app into a breakpoint
wait. Unknown TXM detection fails unless a target-specific script requirement
explicitly chooses the script path.

The PID entry uses a cached process name and an unambiguous application-name
match when available. A PID with no identifiable application retains the device
default policy; use the Applications tab for reliable Air/Amethyst identification.
The script connection remains open until the target's protocol explicitly
detaches. Cancellation is checked between debugger commands and fully drained
memory-write batches, with best-effort detach on failure. This does not grant
unlimited iOS background execution or interrupt an in-flight blocking FFI call.

Universal script stop parsing accepts thread fields in any position and queries
registers omitted by a stop reply. A stop returned by `vCont` is handled before
another continue. Injected extension lengths use hexadecimal RSP encoding, and
an invalid extension fails the operation instead of continuing with an incomplete
allocator protocol. Both app and framework copies receive these fixes.

The Amethyst requirement was checked against the remastered build's
[`70b8bea` source](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/blob/70b8bea76a0ac97483b3e86b54330dfef948cb07/Natives/JavaLauncher.m#L1019).
These checks confirm the observed protocol sequence, not successful execution of every target
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
  VPN is not a location-reset action. Restoration remains available as recovery
  through an existing local device connection. This feature is a coordinate
  simulator; the Pikmin branch's walking routes, step writing, HealthKit and
  subscription workflows are not included.
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
Run `scripts/test-device-connection.sh` for connection-mode admission, external
validation and invalidation checks. Run `scripts/test-device-connection-probe.sh`
for bounded endpoint prechecks, cancellation, and ensuring TCP success alone
cannot substitute for paired-device validation (host tunnel boundary is stubbed).
Run `scripts/test-wifi-requirement.sh` for Wi-Fi/cellular/VPN admission and
monitor refresh, stale-callback, disconnection and cancellation lifecycle checks.
Run `scripts/test-ddi-downloads.sh` for entirely local catalog/package completeness,
checksum/cache, family selection, cancellation and restoration checks. The retained
script name is historical; it also checks all eight actual bundled files.
Run `scripts/test-launcher.sh` for host-side storage/input/protocol checks.
`bash scripts/test-jit-mode.sh`, `bash scripts/test-script-library.sh`, and
`bash scripts/test-universal-protocol.sh` for automatic mode selection, Air/
Amethyst compatibility, and simulated bootstrap/extension/allocator handshakes.
The protocol test requires Node.js and does not replace physical-device JIT QA.
Run `scripts/test-launcher-operations.sh` for operation cancellation and stale
completion checks. These checks and successful builds do not establish
physical-device acceptance.

Physical-device verification remains required for VPN consent and extension
launch, Bonjour host visibility, real PIN notifications, pairing/expiry/cancellation,
DDI preparation, installed-app discovery/icons and launch, each target/script JIT
combination, logs, profile changes, and location restoration after connection
failures. Verify that setup remains available without a credential, protected
commands require the intended device's valid credential, and clearing location
or resuming a suspended process still works after a credential failure. Binding
must not send a website authorization request. The on-device pairing sequence specifically
needs an iOS/iPadOS 27+ device. Review all three languages, Dynamic Type,
light/dark appearance, and compact iPhone/iPad layouts as well.

## Storage and execution lifecycle

Pairing records live in protected Application Support, excluded from backup, with
owner-only permissions. Imports are bounded at 5 MiB, parsed with the actual
RPPairing validator, and replaced atomically. On-device host identity metadata is
stored with its record. Private pairing contents and PINs are not logged.

The embedded VPN keeps upstream endpoints `10.7.1.1/32` (interface) and
`10.7.0.1/32` (peer), matching `10.7.0.1:49152` for device services. It manages only
profiles for this app's extension. User-editable routes and control of unrelated
VPN profiles are not part of the integration.

Blocking FFI work runs off the main thread. Built-in VPN loss (in built-in mode), external connection failures, record changes, or revoking
the Developer Mode confirmation invalidates readiness. Generation/operation
checks prevent stale results from marking a changed connection ready. Pairing
sessions and bundled-DDI copying support cancellation; blocking native FFI
operations are not forcibly interrupted. An expired background task reports
failure while retaining ownership until the worker returns. Background time and
the debugger heartbeat do not
provide unlimited background execution.

## Source provenance

- StikJIT starting point: `32287268fa5824f9edce4cb359f5833ce0cf7b00`.
- StikDebug upstream main: `4bdfc92aa7cebd7a534f1e1ef56415f5727402de` (3.1.13),
  fetched during this integration on 2026-10-01 and reconfirmed against remote main
  with `git ls-remote` on 2026-10-02. Exact scripts and adapted service
  behavior are detailed in [ThirdParty/StikDebug/PROVENANCE.md](ThirdParty/StikDebug/PROVENANCE.md).
- LocalDevVPN: `af3fd697803ada4ac2b8d518358f5ab0a534844c`. Endpoints, CIDR validation,
  packet reflection, integration adaptations, and retained licenses are detailed
  in [ThirdParty/LocalDevVPN/PROVENANCE.md](ThirdParty/LocalDevVPN/PROVENANCE.md).
- The user's local `codex/pikmin-helper` pairing guide informed the seven-step
  presentation and readiness UX. The launcher no longer includes its signed-license
  implementation. Its HealthKit and walking/step-writing workflows were not merged.
