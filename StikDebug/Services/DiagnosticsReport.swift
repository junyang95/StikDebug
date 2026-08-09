import Foundation
import Network
import NetworkExtension
import UIKit
import idevice

/// 一键生成「核心状态快照」，给用户导出后发给开发者排查。
///
/// 只收集诊断需要的状态（VPN、网络、路由探测、配对/DDI 是否就位、最近日志），
/// 不包含 pairing file 内容、坐标等敏感数据。
enum DiagnosticsReport {

    @MainActor
    static func generate() async -> String {
        var lines: [String] = []
        func section(_ title: String) { lines.append(""); lines.append("== \(title) ==") }
        func row(_ key: String, _ value: String) { lines.append("\(key): \(value)") }

        lines.append("Pikmin Helper 诊断日志")
        lines.append(ISO8601DateFormatter().string(from: Date()))

        // MARK: App / 设备
        section("App / 设备")
        let info = Bundle.main.infoDictionary
        row("版本", "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        row("Bundle ID", Bundle.main.bundleIdentifier ?? "?")
        row("设备型号", deviceModelIdentifier())
        row("系统版本", "iOS \(UIDevice.current.systemVersion)")
        row("低电量模式", ProcessInfo.processInfo.isLowPowerModeEnabled ? "开启（可能影响后台）" : "关闭")

        // MARK: 内置 VPN（PikminTunnel）
        section("内置 VPN（PikminTunnel）")
        row("App 记录的状态", EmbeddedVPNService.shared.status.title)
        let providerID = (Bundle.main.bundleIdentifier ?? "com.jy.stikdebug.pikmin") + ".networkextension"
        row("期望的 Extension", providerID)
        await appendTunnelManagers(into: &lines, expectedProvider: providerID)

        // MARK: 系统 VPN 迹象
        section("系统 VPN 迹象（仅用于发现「另外开了全局 VPN」）")
        let vpnInterfaces = activeVPNInterfaces()
        if vpnInterfaces.isEmpty {
            row("全局 VPN 接口", "无")
            lines.append("说明：本 App 隧道是只路由 10.7.0.x 的回环隧道，故意不接管默认流量，")
            lines.append("正常情况下不会出现在这里。「无」不代表 PikminTunnel 没连——")
            lines.append("请以上一节「内置 VPN」的连接状态为准。")
        } else {
            row("全局 VPN 接口", vpnInterfaces.joined(separator: ", "))
            lines.append("注意：检测到全局 VPN 接口。本 App 的回环隧道通常不会在此出现，")
            lines.append("所以这更可能是另一个 VPN App。iOS 同时只允许一个隧道，它可能挤掉了 PikminTunnel。")
        }

        // MARK: 网络
        section("网络")
        lines.append(await networkSnapshot())

        // MARK: 关键路由探测
        section("关键路由探测")
        let target = DeviceConnectionContext.targetIPAddress
        let probe = await probeTCP(host: target, port: 49152, timeout: 3)
        row("\(target):49152（内置 VPN 路由判定依据）", probe)
        lines.append("说明：App 判定「内置 VPN 路由」是否就绪，靠的就是能否连上这个地址，")
        lines.append("而不是系统 VPN 开关。这个地址由内置隧道映射到设备本地开发服务，")
        lines.append("正常不经过 Wi‑Fi 路由器。探测失败通常是：开的不是本 App 的 VPN、")
        lines.append("或配对/开发者模式/DDI 尚未就绪导致设备端服务没起来。")

        // MARK: 配对与 DDI
        section("配对与 DDI")
        let pairingURL = PairingFileStore.prepareURL()
        let pairingExists = FileManager.default.fileExists(atPath: pairingURL.path)
        row("pairing file 是否存在", pairingExists ? "是" : "否（未导入）")
        if pairingExists {
            row("pairing file 可解析", pairingFileParseable(pairingURL) ? "是" : "否（内容无效）")
        }
        row("DDI 缺失文件", ddiMissingFiles().isEmpty ? "无（3 个文件齐全）" : ddiMissingFiles().joined(separator: ", "))

        // MARK: 环境检查清单
        section("环境检查清单（当前 UI 状态）")
        for item in EnvironmentPreflightService.shared.items {
            row(item.kind.title, item.status.message)
        }

        // MARK: 最近日志
        section("最近日志（最多 60 条）")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let recent = LogManager.shared.logs.suffix(60)
        if recent.isEmpty {
            lines.append("（无）")
        } else {
            for entry in recent {
                lines.append("[\(formatter.string(from: entry.timestamp))] \(entry.type.rawValue) \(entry.message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 采集辅助

    private static func appendTunnelManagers(into lines: inout [String], expectedProvider: String) async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if managers.isEmpty {
                lines.append("本 App 的 VPN 配置：未找到（可能从未成功保存过配置）")
                return
            }
            lines.append("本 App 名下的 VPN 配置（共 \(managers.count) 个）：")
            for manager in managers {
                let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
                let provider = proto?.providerBundleIdentifier ?? "?"
                let isOurs = provider == expectedProvider
                lines.append(
                    "  - \(manager.localizedDescription ?? "未命名")"
                    + " | provider=\(provider)\(isOurs ? "（本 App）" : "（非本 App）")"
                    + " | 启用=\(manager.isEnabled ? "是" : "否")"
                    + " | 连接状态=\(vpnStatusText(manager.connection.status))"
                )
            }
        } catch {
            lines.append("读取 VPN 配置失败：\(error.localizedDescription)")
        }
    }

    private static func networkSnapshot() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.pikminhelper.diagnostics.path")
            var resumed = false
            monitor.pathUpdateHandler = { path in
                guard !resumed else { return }
                resumed = true
                let text = describe(path)
                monitor.cancel()
                continuation.resume(returning: text)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                guard !resumed else { return }
                resumed = true
                monitor.cancel()
                continuation.resume(returning: "网络状态：2 秒内未返回")
            }
        }
    }

    private static func describe(_ path: Network.NWPath) -> String {
        var parts: [String] = []
        parts.append("总体状态: \(path.status)")
        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("Wi‑Fi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("蜂窝") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("有线") }
        if path.usesInterfaceType(.other) { interfaces.append("其它/VPN 隧道") }
        if path.usesInterfaceType(.loopback) { interfaces.append("环回") }
        parts.append("使用的接口: \(interfaces.isEmpty ? "无" : interfaces.joined(separator: ", "))")
        parts.append("可用接口: " + path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", "))
        parts.append("按流量计费: \(path.isExpensive)")
        parts.append("受限: \(path.isConstrained)")
        return parts.joined(separator: "\n")
    }

    /// 用系统代理设置里的 __SCOPED__ 键探测是否存在活动 VPN 隧道接口。
    private static func activeVPNInterfaces() -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else {
            return []
        }
        let vpnPrefixes = ["tap", "tun", "ppp", "ipsec", "utun"]
        return scoped.keys
            .filter { key in vpnPrefixes.contains { key.hasPrefix($0) } }
            .sorted()
    }

    private static func probeTCP(host: String, port: UInt16, timeout: TimeInterval) async -> String {
        let start = Date()
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let queue = DispatchQueue(label: "com.pikminhelper.diagnostics.probe")
            var resumed = false
            func finish(_ text: String) {
                guard !resumed else { return }
                resumed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: text)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    finish("可达（\(ms) ms）")
                case .failed(let error):
                    finish("不可达：\(error.localizedDescription)")
                case .cancelled:
                    finish("已取消")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish("超时（>\(Int(timeout)) 秒未连通）")
            }
        }
    }

    private static func pairingFileParseable(_ url: URL) -> Bool {
        var handle: OpaquePointer?
        let error = url.path.withCString { rp_pairing_file_read($0, &handle) }
        if let error {
            idevice_error_free(error)
            return false
        }
        guard let handle else { return false }
        rp_pairing_file_free(handle)
        return true
    }

    private static func ddiMissingFiles() -> [String] {
        ["Image.dmg", "Image.dmg.trustcache", "BuildManifest.plist"].filter { name in
            !FileManager.default.fileExists(
                atPath: URL.documentsDirectory.appendingPathComponent("DDI").appendingPathComponent(name).path
            )
        }
    }

    private static func vpnStatusText(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: "invalid（无效/未配置）"
        case .disconnected: "disconnected（未连接）"
        case .connecting: "connecting（连接中）"
        case .connected: "connected（已连接）"
        case .reasserting: "reasserting（重连中）"
        case .disconnecting: "disconnecting（断开中）"
        @unknown default: "未知"
        }
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "未知" : identifier
    }
}
