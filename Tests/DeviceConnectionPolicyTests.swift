import Foundation

@main
enum DeviceConnectionPolicyTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            count += 1
        }

        check(DeviceConnectionMode(persistedValue: nil) == .builtIn, "New installations retain built-in VPN mode")
        for value in ["", "invalid", "EXTERNAL", " external", "external ", "connected"] {
            check(DeviceConnectionMode(persistedValue: value) == .builtIn,
                  "Unknown stored values cannot silently select external mode")
        }
        for mode in DeviceConnectionMode.allCases {
            check(DeviceConnectionMode(persistedValue: mode.rawValue) == mode, "Explicit mode selection survives persistence")
        }

        var validation = ExternalConnectionValidation()
        check(!DeviceConnectionPolicy.canAttempt(mode: .builtIn, builtInConnected: false),
              "Built-in operations still require the owned VPN connection")
        check(DeviceConnectionPolicy.canAttempt(mode: .builtIn, builtInConnected: true),
              "Connected built-in mode admits an operation")
        check(DeviceConnectionPolicy.canAttempt(mode: .external, builtInConnected: false),
              "An unverified external route permits the actual device check")
        check(!DeviceConnectionPolicy.isReady(mode: .external, builtInConnected: true, external: validation),
              "An unrelated owned VPN status cannot verify an external route")
        check(!DeviceConnectionPolicy.isReady(mode: .external, builtInConnected: false, external: validation),
              "External mode selection alone cannot claim a connection")

        let first = validation.beginChecking()
        check(validation.phase == .checking, "Checking is distinct from readiness")
        check(!DeviceConnectionPolicy.isReady(mode: .external, builtInConnected: true, external: validation),
              "Beginning a check never grants readiness")
        check(!validation.recordPairedDeviceResponse(for: UUID()), "An unrelated callback cannot validate this check")
        check(validation.phase == .checking, "Rejected callback leaves the current check pending")
        check(validation.recordPairedDeviceResponse(for: first), "Current paired-device response verifies the connection")
        check(DeviceConnectionPolicy.isReady(mode: .external, builtInConnected: false, external: validation),
              "Actual external validation works without the owned VPN")
        check(validation.isCurrent(first), "Verified ticket remains current through website authorization and device work")
        check(!validation.recordPairedDeviceResponse(for: first), "A duplicate response cannot restart a completed check")
        check(!DeviceConnectionPolicy.isReady(mode: .builtIn, builtInConnected: false, external: validation),
              "External verification cannot authorize a disconnected built-in route")

        // Network/foreground/pairing/mode invalidations all discard outstanding
        // tickets. A delayed native call is allowed to return but not revalidate.
        validation.invalidate()
        check(validation.phase == .unverified && !validation.isCurrent(first),
              "Invalidation removes both visible readiness and its receipt")
        check(!validation.recordPairedDeviceResponse(for: first), "Late success cannot undo invalidation")
        let second = validation.beginChecking()
        check(second != first, "Retry uses a fresh ticket")
        check(!validation.recordPairedDeviceResponse(for: first), "Previous operation cannot verify a retry")
        check(validation.phase == .checking && validation.isCurrent(second), "Stale completion preserves the newer check")
        validation.invalidate()
        check(!validation.recordPairedDeviceResponse(for: second), "Path invalidation during native work rejects its late success")
        check(DeviceConnectionPolicy.canAttempt(mode: .external, builtInConnected: false),
              "Failed external verification must still allow retry and location recovery")

        let recovered = validation.beginChecking()
        check(validation.recordPairedDeviceResponse(for: recovered), "A new check can recover after failure")
        let refresh = validation.beginChecking()
        check(!DeviceConnectionPolicy.isReady(mode: .external, builtInConnected: false, external: validation),
              "A new device request does not display an old verified result while checking")
        check(!validation.isCurrent(recovered) && validation.isCurrent(refresh),
              "An older website authorization cannot complete against the refreshed route")
        validation.invalidate()
        validation.invalidate()
        check(validation.phase == .unverified && !validation.isCurrent(refresh), "Repeated failure invalidation is idempotent")
        check(DeviceConnectionPolicy.isReady(mode: .builtIn, builtInConnected: true, external: validation),
              "External validation lifecycle does not change built-in readiness")

        print("\(count) device connection policy tests passed. Native pairing, third-party VPN ownership, and website authorization are not simulated.")
    }
}
