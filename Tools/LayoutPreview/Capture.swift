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
            let root = PreviewTabs(content: AnyView(RouteLayoutFixture()), route: true)
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

    @MainActor func captureAll() async {
        let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ddiOnly = ProcessInfo.processInfo.arguments.contains("--ddi")
        let allCases: [(String, String, CGFloat, CGFloat, DynamicTypeSize, ColorScheme)] = [
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
        let cases = ddiOnly ? allCases.filter { $0.0.hasPrefix("ddi") } : allCases
        for (name, page, width, height, type, scheme) in cases {
            let pairing = OnDevicePairingService()
            if page == "pin" { pairing.phase = .awaitingPIN }
            let content: AnyView
            switch page {
            case "ddi", "ddi-downloading", "ddi-failed":
                let installer = DDIInstallationController.preview(failing: page == "ddi-failed")
                if page != "ddi" { installer.start() }
                content = AnyView(DDIInstallationView(installer: installer))
            case "ddi-entry":
                content = AnyView(ScrollView { PreflightChecklistView(service: .shared, compact: true).padding() })
            case "home": content = AnyView(TodayDashboardView(selectedTab: .constant(.home)))
            case "pairing", "pin": content = AnyView(OnDevicePairingView())
            default: content = AnyView(RouteLayoutFixture(active: page == "joystick", joystick: page == "joystick"))
            }
            let wrapped = (page == "pairing" || page == "pin" || page.hasPrefix("ddi")) ? content : AnyView(PreviewTabs(content: content, route: page != "home"))
            let root = wrapped
                .environmentObject(WalkingSessionController())
                .environmentObject(EnvironmentPreflightService())
                .environmentObject(PermissionChecklistService())
                .environmentObject(HealthStepService())
                .environmentObject(pairing)
                .environmentObject(EmbeddedVPNService())
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
            if name == "joystick-accessibility" || name == "route-largest-type" || ["ddi-accessibility", "ddi-landscape", "ddi-failed"].contains(name) {
                func scrollToBottom(_ view: UIView) {
                    if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 {
                        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
                    }
                    view.subviews.forEach(scrollToBottom)
                }
                scrollToBottom(host.view)
                try? await Task.sleep(for: .milliseconds(300))
                let bottom = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                try! bottom.pngData()!.write(to: out.appendingPathComponent(name + "-scrolled.png"))
            }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        try! Data("Rendered \(cases.count) native layouts\n".utf8).write(to: out.appendingPathComponent("complete.txt"))
    }
}
