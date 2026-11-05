import SwiftUI
import UIKit

@main final class PreviewApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        if ProcessInfo.processInfo.arguments.contains("--interactive") {
            let setupEntry = ProcessInfo.processInfo.arguments.contains("--setup-entry")
            let session = WalkingSessionController()
            let health = HealthStepService()
            if setupEntry {
                session.phase = .idle
                session.isActive = false
                session.progress = nil
                health.todayTotalSteps = 0
                health.todayAppSteps = 0
            }
            let content = setupEntry ? passiveHome() : AnyView(PreviewTabs(content: AnyView(RouteLayoutFixture()), route: true))
            let root = content
                .environmentObject(session)
                .environmentObject(EnvironmentPreflightService())
                .environmentObject(PermissionChecklistService())
                .environmentObject(health)
                .environmentObject(OnDevicePairingService())
                .environmentObject(EmbeddedVPNService())
                .environment(\.deviceSetupEnabled, !setupEntry)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--large-type") ? .accessibility5 : .large)
                .tint(PikminUI.green)
            window.rootViewController = UIHostingController(rootView: root)
            return true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            await captureAll()
        }
        return true
    }

    @MainActor private func passiveHome() -> AnyView {
        AnyView(VStack(spacing: 0) {
            DeviceSetupPrompt()
                .frame(maxWidth: 780, alignment: .leading)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            PreviewTabs(content: AnyView(TodayDashboardView(selectedTab: .constant(.home))), route: false)
        })
    }

    @MainActor func captureAll() async {
        let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: out.appendingPathComponent("complete.txt"))
        let ddiOnly = ProcessInfo.processInfo.arguments.contains("--ddi")
        let vipOnly = ProcessInfo.processInfo.arguments.contains("--vip")
        let setupEntryOnly = ProcessInfo.processInfo.arguments.contains("--setup-entry")
        UserDefaults.standard.set(AppearancePreference.system.rawValue, forKey: AppearancePreference.storageKey)
        let allCases: [(String, String, CGFloat, CGFloat, DynamicTypeSize, ColorScheme)] = [
            ("setup-entry-small", "setup-entry", 375, 667, .large, .light),
            ("setup-entry-accessibility", "setup-entry", 320, 667, .accessibility5, .light),
            ("setup-entry-vip-close", "vip-close", 375, 667, .large, .light),
            ("vip-small", "vip", 375, 667, .large, .light),
            ("vip-accessibility", "vip", 320, 667, .accessibility5, .light),
            ("vip-dark", "vip", 430, 932, .large, .dark),
            ("vip-missing-identity", "vip-missing", 375, 667, .large, .light),
            ("vip-network-retry", "vip-retry", 375, 667, .large, .light),
            ("vip-network-accessibility", "vip-retry", 320, 667, .accessibility5, .light),
            ("vip-checking", "vip-checking", 375, 667, .large, .light),
            ("vip-revoked", "vip-revoked", 375, 667, .large, .light),
            ("ddi-small", "ddi", 375, 667, .large, .light),
            ("ddi-accessibility", "ddi", 320, 667, .accessibility5, .light),
            ("ddi-ipad", "ddi", 1024, 768, .large, .light),
            ("ddi-landscape", "ddi", 667, 375, .large, .light),
            ("ddi-downloading-dark", "ddi-downloading", 430, 932, .large, .dark),
            ("ddi-failed", "ddi-failed", 375, 667, .large, .light),
            ("ddi-entry", "ddi-entry", 375, 667, .large, .light),
            ("home-small", "home", 375, 667, .large, .light),
            ("home-large", "home", 430, 932, .large, .light),
            ("home-ipad", "home", 1024, 768, .large, .light),
            ("home-accessibility", "home", 375, 667, .accessibility3, .light),
            ("route-small", "route", 375, 667, .large, .light),
            ("route-large", "route", 430, 932, .large, .light),
            ("route-ipad", "route", 1024, 768, .large, .light),
            ("route-split", "route", 320, 768, .large, .light),
            ("route-landscape", "route", 667, 375, .large, .light),
            ("route-accessibility", "route", 375, 667, .accessibility3, .light),
            ("route-largest-type", "route", 320, 667, .accessibility5, .light),
            ("route-dark", "route", 430, 932, .large, .dark),
            ("joystick-accessibility", "joystick", 375, 667, .accessibility3, .light),
            ("pairing-small", "pairing", 375, 667, .large, .light),
            ("pairing-accessibility", "pairing", 375, 667, .accessibility3, .light),
            ("pairing-ipad", "pairing", 1024, 768, .large, .light),
            ("pin-dark", "pin", 430, 932, .large, .dark)
        ]
        let cases = setupEntryOnly ? allCases.filter { $0.0.hasPrefix("setup-entry") }
            : vipOnly ? allCases.filter { $0.0.hasPrefix("vip") }
            : ddiOnly ? allCases.filter { $0.0.hasPrefix("ddi") } : allCases
        for (name, page, width, height, type, scheme) in cases {
            let pairing = OnDevicePairingService()
            let session = WalkingSessionController()
            let preflight = EnvironmentPreflightService()
            let permissions = PermissionChecklistService()
            let health = HealthStepService()
            if page == "setup-entry" {
                session.phase = .idle
                session.isActive = false
                session.progress = nil
                health.todayTotalSteps = 0
                health.todayAppSteps = 0
                preflight.items = PreflightKind.allCases.map { PreflightItem(kind: $0, status: .unknown) }
                permissions.items = Array(repeating: FixtureItem(status: FixtureStatus(isReady: false)), count: 4)
            }
            if page == "pin" { pairing.phase = .awaitingPIN }
            let content: AnyView
            switch page {
            case "vip", "vip-missing", "vip-retry", "vip-checking", "vip-revoked", "vip-close":
                let state: VipAuthorizationService.State = page == "vip-missing" ? .missingIdentity
                    : page == "vip-retry" ? .networkRetry : page == "vip-checking" ? .checking
                    : page == "vip-revoked" ? .revoked : .idle
                content = AnyView(VipSetupView(authorization: VipAuthorizationService(state: state),
                    restoreLocation: page == "vip-revoked" ? { nil } : nil,
                    close: page == "vip-close" ? {} : nil))
            case "ddi", "ddi-downloading", "ddi-failed":
                let installer = DDIInstallationController.preview(failing: page == "ddi-failed")
                if page != "ddi" { installer.start() }
                content = AnyView(DDIInstallationView(installer: installer))
            case "ddi-entry":
                content = AnyView(ScrollView { PreflightChecklistView(service: .shared, compact: true).padding() })
            case "home", "setup-entry": content = AnyView(TodayDashboardView(selectedTab: .constant(.home)))
            case "pairing", "pin": content = AnyView(OnDevicePairingView())
            default: content = AnyView(RouteLayoutFixture(active: page == "joystick", joystick: page == "joystick"))
            }
            let wrapped: AnyView
            if page == "setup-entry" {
                wrapped = passiveHome()
            } else {
                wrapped = (page == "pairing" || page == "pin" || page.hasPrefix("ddi") || page.hasPrefix("vip")) ? content : AnyView(PreviewTabs(content: content, route: page != "home"))
            }
            let root = wrapped
                .environmentObject(session)
                .environmentObject(preflight)
                .environmentObject(permissions)
                .environmentObject(health)
                .environmentObject(pairing)
                .environmentObject(EmbeddedVPNService())
                .environment(\.deviceSetupEnabled, page != "setup-entry")
                .environment(\.dynamicTypeSize, type)
                .environment(\.horizontalSizeClass, width >= 760 ? .regular : .compact)
                .environment(\.verticalSizeClass, height < 420 ? .compact : .regular)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .environment(\.colorScheme, scheme)
                .tint(PikminUI.green)
            let host = UIHostingController(rootView: root)
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let parent = window!.rootViewController!
            parent.addChild(host)
            parent.view.addSubview(host.view)
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.didMove(toParent: parent)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(450))
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try! image.pngData()!.write(to: out.appendingPathComponent(name + ".png"))
            if name.hasPrefix("vip") || name.hasPrefix("setup-entry") || name == "joystick-accessibility" || name == "route-largest-type" || ["ddi-accessibility", "ddi-landscape", "ddi-failed"].contains(name) {
                var scrollMetrics: [[String: CGFloat]] = []
                func scrollToBottom(_ view: UIView) {
                    if let scroll = view as? UIScrollView {
                        let top = -scroll.adjustedContentInset.top
                        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                        if bottom > top + 1 {
                            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                            scrollMetrics.append([
                                "viewportHeight": scroll.bounds.height, "contentHeight": scroll.contentSize.height,
                                "topOffset": top, "bottomOffset": bottom, "actualOffset": scroll.contentOffset.y
                            ])
                        }
                    }
                    view.subviews.forEach(scrollToBottom)
                }
                scrollToBottom(host.view)
                try? await Task.sleep(for: .milliseconds(300))
                if page == "setup-entry" {
                    // Lazy dashboard rows settle their actual heights after the first scroll.
                    // Recompute the bottom offset so the last setup action is captured in full.
                    host.view.layoutIfNeeded()
                    scrollMetrics.removeAll()
                    scrollToBottom(host.view)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                let bottom = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                try! bottom.pngData()!.write(to: out.appendingPathComponent(name + "-scrolled.png"))
                if name.hasPrefix("vip") || name.hasPrefix("setup-entry") {
                    let metrics = try! JSONSerialization.data(withJSONObject: scrollMetrics, options: [.prettyPrinted, .sortedKeys])
                    try! metrics.write(to: out.appendingPathComponent(name + "-scroll.json"))
                }
                if name == "vip-accessibility" || name == "vip-network-accessibility" {
                    func showActions(_ view: UIView) {
                        if let scroll = view as? UIScrollView {
                            let offset = max(-scroll.adjustedContentInset.top,
                                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom - 280)
                            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                        }
                        view.subviews.forEach(showActions)
                    }
                    showActions(host.view)
                    try? await Task.sleep(for: .milliseconds(200))
                    let actions = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
                        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    try! actions.pngData()!.write(to: out.appendingPathComponent(name + "-actions.png"))
                }
            }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        try! Data("Rendered \(cases.count) native layouts\n".utf8).write(to: out.appendingPathComponent("complete.txt"))
    }
}
