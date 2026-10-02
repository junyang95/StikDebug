# Native layout preview

This standalone iOS Simulator app compiles the production `PikminUI`, `AdaptiveLayout`, `TodayDashboardView`, `OnDevicePairingView`, `PreflightChecklistView`, `DDIInstallationView`, and `DDIInstallationController` sources directly. It uses in-memory service fixtures. The route canvas, status header, and option content are fixtures around the production map workspace and action bar. Permission diagnostics on the home page are placeholders; the environment checklist uses its production view and fixture service.

The preview never connects a VPN, pairs a device, writes HealthKit data, or calls the authorization server. It is not a full-app integration test.

## Run

```sh
Tools/LayoutPreview/build.sh
xcrun simctl install <booted-device-id> /tmp/pikmin-layout-preview/PikminLayoutPreview.app
xcrun simctl launch <booted-device-id> store.wow-app.pikmin-layout-preview -AppleLanguages '(zh-Hans)'
xcrun simctl get_app_container <booted-device-id> store.wow-app.pikmin-layout-preview data
```

`Documents` contains 24 layout snapshots and five scrolled snapshots when `complete.txt` appears. Launch with `--ddi` to capture only the 7 DDI scenarios and 3 scrolled states. DDI dependencies are fixtures: downloads, mounting and failures are simulated. Widths range from 320 to 1024 points and include portrait, landscape, regular/maximum accessibility type, and dark appearance. The host view uses explicit dimensions and size-class overrides on one simulator; these are layout previews, not separate physical-device runs.

Launch with `--interactive` for a tappable route fixture, or `--interactive --large-type` for the largest accessibility size. Start and stop update only the fixture state. The same production action bar invokes those callbacks.

The build script requires Xcode 16.2+ and an installed iOS Simulator runtime on an Apple silicon Mac. Its output is under `/tmp` and is separate from the production IPA.
