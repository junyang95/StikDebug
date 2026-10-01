# StikDebug integration provenance

Upstream project: <https://github.com/StikDebug/StikDebug>

Pinned commit: **`4bdfc92aa7cebd7a534f1e1ef56415f5727402de`** (3.1.13).
This is the configured `upstream/main` fetched and inspected from the user's
StikDebug repository on 2026-10-01. The upstream commit is dated 2026-09-28.
The full upstream GNU Affero General Public License v3.0 text is retained,
unmodified, in [LICENSE](LICENSE).

## Exact resources

These `App/ScriptResources` files are byte-identical to `StikDebug/Scripts` at the
pinned commit:

| Script | SHA-256 |
| --- | --- |
| `universal.js` | `e9828331a815c10c2077df6c66c2a974dfec235d03231aba4e50044c6015ea14` |
| `legacy.js` | `787df4678ca17fd100a1d002203bfac8771fae062175aa510da8d6af9f8167ec` |
| `Geode.js` | `6fa925200dd7916f3c670c913d409091cb687269d9efb8b18d35c2eaf73290af` |
| `maciOS.js` | `6ace44d6522eeadad3c30b189606e5a5fb803717b1a7a26ff7bc21f226b63de6` |

The app-name mapping in `App/Models/ScriptLibrary.swift` follows
`StikDebug/Support/AutoScriptAssignments.swift`. Explicit per-app assignments take
priority, followed by that mapping, then the selected default. Bundled scripts
remain read-only; custom scripts are stored separately.

## Adapted behavior

The application catalog, entitlement interpretation, app launch, process control,
device metadata, provisioning-profile operations, and location-service calls
follow the relevant operations in `StikDebug/Device/IdeviceFFIBridge.swift` and
`StikDebug/Device/JITEnableContext.swift`. They are adapted into
`Sources/DeviceTools.swift`, `Sources/DeviceMetadata.swift`, and framework API
models with scoped FFI ownership, checked results, and input validation.

`Sources/DebugHeartbeatSession.swift` follows StikDebug's debugger heartbeat
behavior. It owns its own tunnel/handles and uses a worker thread; cancellation
requests do not free a handle while that thread may still be using it.

The new SwiftUI application uses four tabs—Applications, Setup, Tools, and
Settings—to bring those services together with the existing StikJIT framework,
on-device pairing, and the embedded VPN. It is not the upstream StikDebug app
rebranded without changes, nor a claim of complete upstream UI/API compatibility.

## Pairing-guide reference

The guide takes design cues from the user's local **`codex/pikmin-helper`** branch,
particularly its current `Views/OnDevicePairingView.swift`,
`Core/PairingGuidePolicy.swift`, and preflight/DDI presentation. That working tree
contained uncommitted changes and was inspected without modifying or merging it.
The reference is the local working tree, not a claim that all guide changes belong
to a published upstream commit.

The integration preserves the requested seven-step order, the **StikDebug** host
name, a prominent real PIN, and actionable connection preparation. It retains
its own cancellable pairing session, atomic protected record storage, bounded
background lifetime, and notification cleanup. The app cannot observe or mark
manual Settings actions complete. The Pikmin branch's HealthKit, walking/step
writing, VIP/subscription, proxy, and authorization flows are not included.

## Compatibility boundaries

- The installed-app list currently uses placeholder icons. The framework icon
  service has not yet been connected to list loading. The launcher itself retains
  its bundled application icon.
- JIT eligibility is read from device metadata; target-app protocol compatibility
  still depends on the OS, hardware, and selected script.
- The script host supplies `get_pid`, `send_command`, `prepare_memory_region`,
  `log`, and device-capability-backed `hasTXM`. `resume_app()` and
  `take_screenshot()` explicitly report unsupported operations. Custom scripts
  cannot assume the full upstream scripting host is present.
- Script success requires acknowledged attachment, nonempty memory preparation,
  and explicit detachment. A no-op JavaScript return is not JIT success.
- Device syslog stopping remains cooperative because the bundled FFI has no
  interrupt for a pending log read. The app waits for that read to return before
  releasing handles or starting a replacement stream.
- Shortcuts and the `jitlauncher`/`stikpair` URL schemes require in-app confirmation
  and prior preparation. Arbitrary external scripts and upstream `stikdebug://`
  compatibility are not provided.
- This build needs signing with the app/extension VPN entitlements and physical
  device acceptance. Neither an unsigned archive nor a simulator preview verifies
  a real pairing, VPN, or target JIT session.

## Other integrated components and attribution

The application's Bundle ID remains **`com.stik.StikPair`**, with the
**`com.stik.StikPair.TunnelProv`** extension. Its display name remains JIT启动器 /
JIT啟動器. These integration identifiers do not imply official upstream branding.

The StikJIT starting point is `32287268fa5824f9edce4cb359f5833ce0cf7b00`.
LocalDevVPN is pinned separately at
`af3fd697803ada4ac2b8d518358f5ab0a534844c`; its provenance and retained licenses are
in `ThirdParty/LocalDevVPN`. Those components are not sourced from StikDebug.

The combined launcher application and StikDebug-derived additions are distributed
under AGPL-3.0. Pre-existing StikJIT files retain their MPL-2.0 notices, and
LocalDevVPN retains its included license notices. Preserve these source and
license files when distributing this integrated version. The app's About screen
credits the upstream projects and includes their retained license texts.
