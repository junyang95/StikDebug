import Foundation
import idevice
import UIKit
import UserNotifications

/// iOS 27+ device-initiated pairing. The blocking Rust accept loop stays on a
/// dedicated thread while Settings connects through `PairableHostAdvertiser`.
@MainActor
final class OnDevicePairingService: ObservableObject {
    static let shared = OnDevicePairingService()

    enum Phase: Equatable {
        case idle
        case advertising
        case deviceConnected
        case awaitingPIN(String)
        case installing
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var debugPort: UInt16?

    private var worker: Thread?
    private let callbackBox = OnDevicePairingCallbackBox()
    private let advertiser = PairableHostAdvertiser()
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private init() {}

    var isSupported: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .advertising, .deviceConnected, .awaitingPIN, .installing:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    var pin: String? {
        if case .awaitingPIN(let value) = phase { return value }
        return nil
    }

    func start() {
        guard isSupported else {
            phase = .failed("本机配对需要 iOS 27 或更高版本。".localized)
            return
        }
        guard worker == nil, !isBusy else { return }

        phase = .advertising
        debugPort = nil
        callbackBox.owner = self
        requestNotificationPermission()
        beginKeepAlive()

        let box = callbackBox
        let thread = Thread {
            autoreleasepool {
                Self.runBlockingAccept(box: box)
            }
        }
        thread.name = "pikmin-helper.pairable-host"
        thread.qualityOfService = .userInitiated
        worker = thread
        thread.start()
        LogManager.shared.addInfoLog("iOS 27 本机配对已启动")
    }

    /// The underlying accept call cannot be cancelled safely. Reset is only
    /// offered after it returns, so dismissing the guide never corrupts state.
    func reset() {
        guard !isBusy else { return }
        phase = .idle
        debugPort = nil
    }

    fileprivate func handleListening(
        port: UInt16,
        serviceIdentifier: String,
        name: String,
        model: String,
        authTag: String,
        version: String,
        minimumVersion: String
    ) {
        debugPort = port
        advertiser.publish(
            port: port,
            serviceIdentifier: serviceIdentifier,
            name: name,
            model: model,
            authTag: authTag,
            version: version,
            minimumVersion: minimumVersion
        )
        phase = .advertising
    }

    fileprivate func handleConnected() {
        phase = .deviceConnected
        Self.postNotification(
            identifier: "pikmin.pairing.connected",
            title: "StikDebug 已连接".localized,
            body: "正在生成本机配对码…".localized
        )
    }

    fileprivate func handlePIN(_ value: String) {
        phase = .awaitingPIN(value)
        Self.postPINNotification(value)
        Haptic.success()
    }

    fileprivate func handleInstalling() {
        phase = .installing
    }

    fileprivate func handleSuccess() {
        worker = nil
        phase = .succeeded
        teardown()
        Haptic.success()
        LogManager.shared.addInfoLog("本机配对完成，pairing file 已安全写入")
        Self.postNotification(
            identifier: "pikmin.pairing.succeeded",
            title: "本机配对完成".localized,
            body: "配对文件已安装。回到 StikDebug 连接本地隧道。".localized
        )
        Task { await EnvironmentPreflightService.shared.refresh() }
    }

    fileprivate func handleFailure(_ message: String) {
        worker = nil
        phase = .failed(message)
        teardown()
        LogManager.shared.addErrorLog("本机配对失败：\(message)")
    }

    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true
        BackgroundLocationManager.shared.requestRequiredStart()
        BackgroundAudioManager.shared.requestRequiredStart()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pikmin-helper.pairable-host") { [weak self] in
            Task { @MainActor in self?.endKeepAlive() }
        }
    }

    private func teardown() {
        advertiser.stop()
        endKeepAlive()
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundLocationManager.shared.requestRequiredStop()
        BackgroundAudioManager.shared.requestRequiredStop()
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postPINNotification(_ pin: String) {
        let content = UNMutableNotificationContent()
        content.title = "StikDebug 配对码".localized
        content.body = pin
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "pikmin.pairing.pin",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func postNotification(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated private static func runBlockingAccept(box: OnDevicePairingCallbackBox) {
        var pairingFile: OpaquePointer?
        var alternateIRK = [UInt8](repeating: 0, count: 16)
        let error = "StikDebug".withCString { name in
            "Mac17,7".withCString { model in
                pikmin_pairable_host_accept(
                    name,
                    model,
                    0,
                    onDevicePairingPINCallback,
                    Unmanaged.passUnretained(box).toOpaque(),
                    onDevicePairingListeningCallback,
                    Unmanaged.passUnretained(box).toOpaque(),
                    onDevicePairingConnectedCallback,
                    Unmanaged.passUnretained(box).toOpaque(),
                    &alternateIRK,
                    &pairingFile
                )
            }
        }

        if let error {
            let message = error.pointee.message.map(String.init(cString:))
                ?? "未知配对错误（\(error.pointee.code)）"
            pikmin_pairing_error_free(error)
            DispatchQueue.main.async { box.owner?.handleFailure(message) }
            return
        }

        guard let pairingFile else {
            DispatchQueue.main.async {
                box.owner?.handleFailure("配对已结束，但没有返回 pairing file。".localized)
            }
            return
        }
        defer { pikmin_pairing_file_free(pairingFile) }

        DispatchQueue.main.async { box.owner?.handleInstalling() }
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pikmin-pairing-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let writeError = stagingURL.path.withCString { path in
            pikmin_pairing_file_write(pairingFile, path)
        }
        if let writeError {
            let message = writeError.pointee.message.map(String.init(cString:))
                ?? "无法写入 pairing file"
            pikmin_pairing_error_free(writeError)
            DispatchQueue.main.async {
                box.owner?.handleFailure("配对成功，但保存失败：\(message)")
            }
            return
        }

        do {
            try PairingFileStore.replace(with: stagingURL)
            DispatchQueue.main.async { box.owner?.handleSuccess() }
        } catch {
            DispatchQueue.main.async {
                box.owner?.handleFailure("配对成功，但校验安装失败：\(error.localizedDescription)")
            }
        }
    }
}

private final class OnDevicePairingCallbackBox: @unchecked Sendable {
    weak var owner: OnDevicePairingService?
}

private func onDevicePairingPINCallback(
    pin: UnsafePointer<CChar>?,
    context: UnsafeMutableRawPointer?
) {
    guard let pin, let context else { return }
    let value = String(cString: pin)
    let box = Unmanaged<OnDevicePairingCallbackBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.owner?.handlePIN(value) }
}

private func onDevicePairingListeningCallback(
    port: UInt16,
    serviceIdentifier: UnsafePointer<CChar>?,
    name: UnsafePointer<CChar>?,
    model: UnsafePointer<CChar>?,
    authTag: UnsafePointer<CChar>?,
    version: UnsafePointer<CChar>?,
    minimumVersion: UnsafePointer<CChar>?,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<OnDevicePairingCallbackBox>.fromOpaque(context).takeUnretainedValue()
    let values = (
        port,
        serviceIdentifier.map { String(cString: $0) } ?? "",
        name.map { String(cString: $0) } ?? "StikDebug",
        model.map { String(cString: $0) } ?? "Mac17,7",
        authTag.map { String(cString: $0) } ?? "",
        version.map { String(cString: $0) } ?? "26",
        minimumVersion.map { String(cString: $0) } ?? "17"
    )
    DispatchQueue.main.async {
        box.owner?.handleListening(
            port: values.0,
            serviceIdentifier: values.1,
            name: values.2,
            model: values.3,
            authTag: values.4,
            version: values.5,
            minimumVersion: values.6
        )
    }
}

private func onDevicePairingConnectedCallback(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<OnDevicePairingCallbackBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.owner?.handleConnected() }
}
