# Native layout preview

This standalone iOS Simulator app compiles the production `PikminUI`, `AdaptiveLayout`, `TodayDashboardView`, `OnDevicePairingView`, `PreflightChecklistView`, `DDIInstallationView`, `DDIInstallationController`, and `VipSetupView` sources directly. `AppearancePreference` comes from the production `MovementProfile.swift` source. It uses in-memory service fixtures. The route canvas, status header, and option content are fixtures around the production map workspace and action bar. Permission diagnostics on the home page are placeholders; the environment checklist uses its production view and fixture service.

The preview never connects a VPN, pairs a device, writes HealthKit data, or calls the authorization server. It is not a full-app integration test.

## Run

```sh
Tools/LayoutPreview/build.sh
xcrun simctl install <booted-device-id> /tmp/pikmin-layout-preview/PikminLayoutPreview.app
xcrun simctl launch <booted-device-id> store.wow-app.pikmin-layout-preview -AppleLanguages '(zh-Hans)'
xcrun simctl get_app_container <booted-device-id> store.wow-app.pikmin-layout-preview data
```

`Documents` contains 35 layout snapshots and 16 scrolled snapshots when `complete.txt` appears. Launch with `--ddi` to capture only the 7 DDI scenarios and 3 scrolled states. DDI dependencies are fixtures: downloads, mounting and failures are simulated. Launch with `--vip` to capture only the 8 VIP setup scenarios and their bottom-scrolled states: 375-point width, 320-point width with maximum accessibility text, dark appearance, missing signing identity, network retry at regular and maximum text sizes, verification in progress, and revoked authorization with a fixture-only restore-location callback. The VIP service is a pure layout fixture; it never imports the live authorization service. Each VIP capture includes scroll metrics in `*-scroll.json` so the accessibility case can be checked against its actual bottom offset, including safe-area insets. Widths range from 320 to 1024 points and include portrait, landscape, regular/maximum accessibility type, and dark appearance. The host view uses explicit dimensions and size-class overrides on one simulator; these are layout previews, not separate physical-device runs.

Launch with `--setup-entry` for 3 scenarios and their bottom-scrolled states: the passive home screen at 375 points, the same home screen at 320 points with maximum accessibility text, and the VIP page with its production close button. The home cases set `deviceSetupEnabled=false`, use idle/empty service fixtures, and place the production `DeviceSetupPrompt` above the tabs in a `VStack`, using the same 780-point maximum width, padding and material as `MainTabView`. The prompt occupies its own layout space so it cannot cover the home title. The close callback is a no-op: these captures check layout, not modal presentation or dismissal. Each scenario writes scroll metrics alongside its PNGs; passive home captures scroll again after lazy content finishes laying out.

Launch with `--interactive` for a tappable route fixture, or `--interactive --large-type` for the largest accessibility size. Start and stop update only the fixture state. The same production action bar invokes those callbacks.

The two VIP maximum-text cases also produce `*-actions.png` captures positioned above the bottom, making multiline network/purchase links inspectable alongside the primary action.

The build script requires Xcode 16.2+ and an installed iOS Simulator runtime on an Apple silicon Mac. Its output is under `/tmp` and is separate from the production IPA.
