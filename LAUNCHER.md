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

## Current release: 2.0.7 (18)

Authorization starts after **Start setup** on the ordinary home screen. Device
registration remains independent of VIP membership. Native per-device packages
precheck their candidate UDID before pairing/VPN setup, then bind a signed permit
after matching the actual device. Requests use app-shop.cn with wow-app.store as
fallback and allow a previously bound permit for up to seven days during network
failures. Public/self-signed packages without a unique candidate identify the
actual device after setup. See the authorization contract below.

## Connection and import changes retained from 2.0.6 (17)

Setup and Settings now offer **Built-in VPN** and **External VPN** connection
modes. External mode accepts a working LocalDevVPN default connection or another
compatible loopback VPN at the same device endpoint. It does not require this
app’s tunnel extension to report connected and never starts the built-in VPN.
Device communication and signed registration checks still run before protected
operations. External status describes the last successful paired-device check,
not another app’s VPN profile status.

Pairing files now use system copy import, bounded snapshot reads, and explicit
failure feedback without replacing the last valid record on error. On iOS/iPadOS
26 and other supported versions below 27, setup leads with computer USB pairing
and the idevice_pair download link. On-device pairing remains an iOS/iPadOS 27+
feature. See the import section below for the workflow and signing limitations.

The DDI fixes introduced in 2.0.3 remain in place. Downloads now show bytes and percentage, use a versioned Qiniu mirror
with a fixed upstream fallback, and reject incomplete or mismatched files before
publishing a complete cache. Settings provides **Download developer image again**
without removing pairing. The DDI download and cache contract is described below.

Cryptex mounting was already integrated in 2.0.2; it was not omitted from that
release. Its relevant FFI and mounting core match the pinned StikDebug 3.1.13
implementation. Upstream main was reconfirmed as
`4bdfc92aa7cebd7a534f1e1ef56415f5727402de` on 2026-10-02. The
[3.1.11 release notes](https://github.com/StikDebug/StikDebug/releases/tag/3.1.11)
describe cryptex mounting for the iPhone 18 Pro series and persistence across
reboots on iOS 26.4 and later. This change repairs the earlier download stage;
it does not establish successful mounting or JIT on the reported physical device.

## Application icons and device access (2.0.2)

The Applications tab now shows only device-reported debuggable targets, loads
their real icons through SpringBoard services, and excludes the launcher itself.
New protected operations require signed device registration and non-ban
verification. The current fallback and offline policy is described below.
VIP membership is not required. The application-list
compatibility fix below remains included.

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
| Setup / 配对引导 | Follow the seven pairing steps, view/copy the actual pairing PIN, import a remote pairing record when needed, choose the embedded or an external VPN, verify device registration, and check/prepare the developer disk image (DDI). |
| Tools / 工具 | Manage scripts; inspect/terminate processes or enable JIT by PID; view JIT and system logs; read device metadata; inspect/import/export/remove provisioning profiles; simulate or restore device location. |
| Settings / 设置 | Choose a connection mode, control the built-in VPN or check the external connection, download the developer image again, inspect/remove the pairing record, check device verification, return to setup, open this app's system settings for language/permissions, and read upstream attribution/licenses. |

Every launch opens Applications without automatically starting authorization,
pairing, or VPN preparation. Choose **Start setup** to begin. An existing pairing
record does not imply that the connection or JIT preparation is ready. Complete
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
Existing verified DDI caches are retained. Download requests also disallow
cellular access. Disconnecting the VPN, importing a record, and restoring real
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
lockdown identity read validates the connection; a TCP connection alone is not
proof. Every protected operation then verifies device access under the online/offline
policy described below. Failed device communication clears external readiness and asks the user
to check the external VPN and pairing record. Switching connection mode or
returning from the background invalidates external readiness for a fresh check.
The readiness section separately reports the saved record, connection status,
and verified device/DDI readiness.

Preparation first checks bound device access, then checks the device connection,
downloads and mounts DDI when needed,
and verifies the result. The first download needs internet access and can take
several minutes; keep the app in the foreground. A connected VPN alone does not
prove that device services or JIT are ready. If an unrelated VPN prevents the
selected loopback connection from working, switch that VPN off and retry.

After preparation, the app refreshes the installed-app catalog. Select a target
in Applications, then use **Launch and enable JIT** or **Launch app**. The launcher
starts the selected Bundle ID and obtains its actual PID. Manual PID entry and
running-process selection remain available under Tools → Processes; refresh after
an app restarts because its PID changes. Invalid PIDs and the launcher's own
process are rejected.

### DDI downloads and recovery

`Resources/DDIAssets.json` fixes the DDI release to
`doronz88/DeveloperDiskImage` commit
`6eae353ae694bda1c421d4a3eee5459ae59c99a1`, build `27A5228h`. The selected mounting
method determines which complete group is required:

- Personalized: `BuildManifest.plist`, `Image.dmg`, and `Image.dmg.trustcache`.
- Cryptex: the same three names plus `Image.dmg.cryptex_info` and
  `Image.dmg.root_hash`, from the separate cryptex directory.

Each file is tried first under the immutable mirror prefix
`https://static.wow-app.store/Xcode_iOS_DDI_Personalized/releases/6eae353ae694bda1c421d4a3eee5459ae59c99a1`,
then under the upstream raw URL at that exact commit. Each source must supply the
catalog's expected byte count and SHA-256. A failure, mismatch, or timeout on the
mirror switches that file to the upstream fallback; failure of both sources
reports an error. The connection deadline is 15 seconds, an established transfer
with no activity is stopped after 20 seconds, and each file/source attempt has a
600-second total limit. Bytes are streamed to temporary files instead of holding
the disk image in memory. The UI shows the current file, transferred bytes,
source, and overall percentage, including source switches and verification.

Downloads support cancellation. The previous cached group remains untouched
during transfer and verification. Only after the entire new group passes checks
does replacement begin, and a completion receipt is written last. Cache reuse
requires a matching receipt plus the expected sizes and hashes; partial files,
mixed groups, and old caches without that receipt are not accepted as ready.

The app reads this catalog from its bundle, not a mutable remote `latest` file.
Publish new DDI versions under a new revision directory and keep previous
revision URLs available for installed app versions. Updating the bundled catalog
and shipping an app update is currently required to select a new revision or
change both download origins; uploading new server files alone does not do so.
A future remote catalog mechanism would need compatibility selection, validation,
and a verified fallback before replacing this pin. Never overwrite an old
revision with different bytes: the app will correctly reject its hash mismatch.

Normal preparation first checks whether the system already has a mounted DDI.
It downloads a verified group when mounting is needed and the cache is unusable;
it does not replace a DDI that is already mounted. To force a fresh cache download,
connect the selected loopback VPN, then use **Settings → Developer image → Download
developer image again**. Pairing and Developer Mode must already be ready, and
the action performs fresh device-access verification. It downloads even when the
system DDI is already mounted, then checks/prepares the device. It preserves
pairing and does not forcibly unmount the system's existing DDI.

The earlier backend upload script only covered the three-file personalized group,
and the 2.0.2 download client did not use that CDN prefix. Updating those server
objects alone therefore did not update the launcher's cryptex download path.
Before distributing a version that relies on the mirror, upload both catalogued
groups into their immutable versioned directories and verify every public URL,
size, and hash. Preparing files locally does not publish them. A future DDI
update requires reviewing and releasing the corresponding
bundled catalog with the app; the client does not fetch an unverified replacement
catalog in the background.

## Device registration and offline access

The access rule is unchanged: the actual device must be registered on the website
and not banned. VIP membership is not required; ordinary registered devices and
expired VIP remain eligible. Registration is not a current Safari session.

Opening the app shows the normal application library and does not begin an online
check, pairing or VPN setup. Choose **Start setup** to begin:

1. A per-device package may carry `wowvip.plist` with a UDID. A provisioning profile
   with exactly one valid device is another candidate source. The launcher checks
   that candidate before exposing pairing/VPN actions. No manual UDID entry is used.
2. Public unsigned/self-signed packages without a unique candidate continue to
   pairing and VPN with an explicit explanation. This grants setup access only;
   JIT and other protected operations remain blocked until real-device verification.
3. The existing device channel reads the actual UDID before every protected
   operation. It must match a pending setup candidate. Only then can the signed
   result become a permit bound to the UDID, pairing contents and connection mode.
4. A matching, still-valid setup result needs no second website request. Subsequent
   protected operations renew online; transport failures may use a valid bound
   offline permit. A different physical device never inherits that permit.

Requests go to `https://app-shop.cn/api/vip-license.action` first and
`https://wow-app.store/api/vip-license.action` second, under a bounded total deadline.
Each response must have a valid P-256 signature under the app's fixed key, matching
UDID and fresh nonce, valid signed time fields, `isRegistered: true`, and no ban.
`UNKNOWN` alone cannot establish registration. A signed denial is final and does
not trigger a search for a permissive response. Redirects are refused. A backend
that lacks the signed `isRegistered` field is incompatible and cannot issue an
implicit offline grant. The old `checkVipInfo.action` response is not cached as a
signed registration proof.

JIT permits expire seven days after their signed `ts`; VIP `expireAt` does not
shorten or extend them. The core has separate VIP and registered-device policies:
PikminHelper continues to require valid VIP and uses the earlier of VIP expiry and
seven days. The two apps share the same core source with a parity check, while
keeping separate Keychain namespaces and access rules.

Keychain storage uses device-only records and checked writes/readback. Persistent
clock high-water marks and monotonic deadlines prevent common rollback or app
restart extensions. Fresh nonce-bound server time can repair a wrong wall clock.
A request barrier prevents old grants returning after a signed denial even when
cache deletion fails. Normal device restarts keep unexpired permits; without a
hardware trusted clock, a malicious clock change across device reboots cannot be
completely measured offline. The seven-day allowance also bounds how late an
offline client can learn about a new ban.

The native signing marker is `WowNativeDeviceAccess: true`; the backend also keeps
support for PikminHelper's existing marker. It writes only the per-device UDID,
skips the old injection library and isolates each device's signed-package cache.
This route does not create enterprise shared packages. Public unsigned download
remains usable with the connected-device fallback.

Protected operations include preparation, catalog/process refresh, app launch and
JIT, process termination, device/profile tools, system logs, and starting/changing
simulated location. Shortcut/URL actions retain user confirmation and the same
checks. **Restore real location** remains available through an existing device
connection after a denial or network outage. A permission change cannot revoke
JIT already acquired by another app. Offline permission does not supply a missing
DDI, pairing record, Wi-Fi connection or working local device tunnel.

Deploy the additive backend field/marker support before distributing the updated
client. Existing PikminHelper clients remain compatible. Verify both a per-device
package and a publicly downloaded/self-signed package on physical devices before
claiming end-to-end installation/JIT compatibility.

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
  without a successful website check. This feature is a coordinate simulator;
  the Pikmin branch's walking routes, step writing, HealthKit, and VIP/subscription
  workflows are not included. The device-registration check is described above.
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
Run `scripts/test-ddi-downloads.sh` for host-side catalog, checksum/cache,
fallback, timeout, and cancellation checks with intercepted responses.
Run `scripts/test-launcher.sh` for host-side storage/input/protocol checks.
`bash scripts/test-jit-mode.sh`, `bash scripts/test-script-library.sh`, and
`bash scripts/test-universal-protocol.sh` for automatic mode selection, Air/
Amethyst compatibility, and simulated bootstrap/extension/allocator handshakes.
The protocol test requires Node.js and does not replace physical-device JIT QA.
Run `scripts/test-wow-device-access.sh` for registration/signature policy and bounded
network-client tests. The latter uses self-signed test fixtures and a local
URLProtocol interceptor; it does not send real UDIDs to the website. These checks
and successful builds do not establish physical-device acceptance.

Signed-device verification remains required for VPN consent and extension launch,
Bonjour host visibility, real PIN notifications, pairing/expiry/cancellation,
DDI preparation, installed-app discovery/icons and launch, website registration
and ban handling, each target/script JIT combination, logs, profile changes, and
location restoration after a failed access check. The on-device pairing
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

Blocking FFI work runs off the main thread. Built-in VPN loss (in built-in mode), external connection failures, record changes, or revoking
the Developer Mode confirmation invalidates readiness. Generation/operation
checks prevent stale results from marking a changed connection ready. Pairing
sessions and DDI network transfers support cancellation; blocking native FFI
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
  presentation and readiness UX. Its signed-license implementation informed the
  fixed-key verification contract; this launcher uses its own registration/non-ban
  policy without the VIP requirement, with a seven-day bound offline permit. Its HealthKit
  and walking/step-writing workflows were not merged.
