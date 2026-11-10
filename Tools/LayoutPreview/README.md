# Pikmin native layout previews

This standalone iOS Simulator app compiles the production `PikminUI`, `AdaptiveLayout`, `TodayDashboardView`, `OnDevicePairingView`, `PreflightChecklistView`, `DDIInstallationView`, `DDIInstallationController`, and `DeviceSetupPrompt` sources directly. `AppearancePreference` comes from `MovementProfile.swift`. In-memory fixtures keep device connections, HealthKit and mounting inactive. The route canvas, status header and option content use layout fixtures.

Build with `bash Tools/LayoutPreview/build.sh`. The output defaults to `/tmp/pikmin-layout-preview/PikminLayoutPreview.app`; set `PIKMIN_LAYOUT_BUILD` to choose another temporary build directory. Install and launch the app on an iOS simulator to capture the cases in `Capture.swift`.

The app writes PNGs to its Documents directory and creates `complete.txt` when all selected cases are rendered. Cases cover 320–1024 point widths, portrait and landscape, light and dark appearance, and standard or large accessibility text. These are layout previews, not physical-device validation.

- Launch with `--ddi` for the bundled DDI installation page, local preparation progress, failure recovery and checklist entry. Installation and mounting use fixtures.
- Launch with `--coordinate-paste` for the production batch coordinate form with 19 points, invalid rows, single-point compatibility, dark appearance, iPad and accessibility text.
- Launch with `--setup-entry` for the passive home setup prompt at regular and maximum accessibility text sizes. The prompt occupies its own layout space above the tabs. Setup is now a direct device-settings action; there is no account-verification page.
- Launch with `--interactive --setup-entry` to inspect the passive home layout, or use `--interactive --route` for the route fixture. Add `--large-type` to inspect accessibility text.

Selected cases also produce bottom-scrolled images. Passive home captures include `*-scroll.json` geometry and scroll again after lazy rows settle so the last setup action is visible.
