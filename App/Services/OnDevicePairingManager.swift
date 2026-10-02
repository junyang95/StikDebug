import Combine
import Foundation
import UIKit
import UserNotifications
#if !targetEnvironment(simulator)
import StikJIT
#endif

/// Coordinates a real pairable host with iOS notifications and background time.
/// A code is displayed only when the device-initiated handshake requests one.
@MainActor
final class OnDevicePairingManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var isRunning = false
    @Published private(set) var statusKey = "pairing.on_device.waiting"
    @Published private(set) var pinCode: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notificationMessage: String?

    var canStart: () -> Bool = { true }
    var connectionIsAvailable: () -> Bool = { true }
    var didComplete: ((URL, Data) throws -> Void)?

    var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 27, *) { return true }
        return false
        #endif
    }

    private let worker = DispatchQueue(label: "com.stik.JITLauncher.pairing", qos: .userInitiated)
    private let notifications = UNUserNotificationCenter.current()
    private var attemptID: UUID?
    private var acceptingEvents = false
    private var notificationAllowed = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var deadline: Task<Void, Never>?
    #if !targetEnvironment(simulator)
    private var session: SelfPairingSession?
    #endif

    override init() {
        super.init()
        notifications.delegate = self
    }

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        notificationMessage = nil
        pinCode = nil
        guard isSupported else {
            errorMessage = localized("pairing.on_device.unsupported")
            return
        }
        guard canStart() else {
            errorMessage = localized("pairing.on_device.busy")
            return
        }

        let id = UUID()
        attemptID = id
        acceptingEvents = true
        isRunning = true
        statusKey = "pairing.on_device.starting"
        let allowed: Bool
        do {
            allowed = try await notifications.requestAuthorization(options: [.alert, .sound])
        } catch {
            allowed = false
        }
        guard isCurrent(id) else { return }
        // Notification authorization may outlive the network that admitted it.
        guard connectionIsAvailable() else {
            errorMessage = localized("wifi.required")
            stop(expired: false)
            return
        }
        notificationAllowed = allowed
        if !notificationAllowed {
            notificationMessage = localized("pairing.on_device.notifications_unavailable")
        }

        #if !targetEnvironment(simulator)
        let output: URL
        do { output = try makePrivateOutput(id: id) }
        catch {
            finish(id: id, output: nil, error: error)
            return
        }

        let pairingSession = SelfPairingSession()
        session = pairingSession
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "On-device pairing") { [weak self] in
            // UIKit invokes expiration on the main thread; release its assertion
            // before returning, and never let an old callback stop a new attempt.
            MainActor.assumeIsolated {
                guard let self, self.isCurrent(id) else { return }
                self.stop(expired: true)
            }
        }
        // Also bound an unattended foreground advertisement. Background time is
        // controlled by iOS and may end sooner; no unlimited background mode is used.
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180 * 1_000_000_000) }
            catch { return }
            guard let self, self.isCurrent(id) else { return }
            self.stop(expired: true)
        }

        worker.async { [weak self] in
            do {
                let result = try pairingSession.run(outputURL: output) { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrent(id) else { return }
                        switch event {
                        case .ready: self.statusKey = "pairing.on_device.ready"
                        case .pin(let pin): self.receivePIN(pin, attempt: id)
                        @unknown default: break
                        }
                    }
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
                        return
                    }
                    if self.isCurrent(id) {
                        self.statusKey = "pairing.on_device.saving"
                        do {
                            guard let didComplete = self.didComplete else {
                                throw NSError(domain: "JITLauncher.Pairing", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: self.localized("pairing.on_device.save_failed")])
                            }
                            try didComplete(result.pairingFileURL, result.hostAltIRK)
                            self.statusKey = "pairing.on_device.complete"
                            self.finish(id: id, output: output, error: nil)
                        } catch {
                            self.finish(id: id, output: output, error: error,
                                        errorKey: "pairing.on_device.save_failed")
                        }
                    } else {
                        self.finish(id: id, output: output, error: nil)
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
                        return
                    }
                    self.finish(id: id, output: output, error: error)
                }
            }
        }
        #endif
    }

    func cancel() { stop(expired: false) }

    private func stop(expired: Bool) {
        guard let id = attemptID else { return }
        acceptingEvents = false
        pinCode = nil
        statusKey = "pairing.on_device.cancelled"
        if expired { errorMessage = localized("pairing.on_device.expired") }
        clearNotification(id)
        deadline?.cancel()
        deadline = nil
        #if !targetEnvironment(simulator)
        if let session {
            session.cancel()
            // Do not permit a new session until the blocking handshake has unwound.
        } else {
            attemptID = nil
            isRunning = false
        }
        #else
        attemptID = nil
        isRunning = false
        #endif
        endBackgroundTask()
    }

    private func receivePIN(_ pin: String, attempt id: UUID) {
        guard PairingPIN.isValid(pin) else {
            errorMessage = localized("pairing.on_device.invalid_pin")
            stop(expired: false)
            return
        }
        pinCode = pin
        statusKey = "pairing.on_device.pin_ready"
        guard notificationAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = localized("pairing.on_device.notification_title")
        content.body = String(format: localized("pairing.on_device.notification_body %@"), pin)
        content.sound = .default
        content.threadIdentifier = "jitlauncher.pairing"
        let request = UNNotificationRequest(identifier: notificationID(id), content: content, trigger: nil)
        notifications.add(request) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrent(id) else {
                    self.clearNotification(id)
                    return
                }
                if error != nil {
                    self.notificationMessage = self.localized("pairing.on_device.notifications_unavailable")
                }
            }
        }
    }

    private func finish(id: UUID, output: URL?, error: Error?, errorKey: String = "pairing.on_device.start_failed") {
        defer { if let output { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) } }
        guard attemptID == id else { return }
        if acceptingEvents, let error {
            errorMessage = localized(errorKey) + "\n" + error.localizedDescription
            statusKey = "pairing.on_device.waiting"
        }
        acceptingEvents = false
        clearNotification(id)
        pinCode = nil
        deadline?.cancel()
        deadline = nil
        endBackgroundTask()
        #if !targetEnvironment(simulator)
        session = nil
        #endif
        attemptID = nil
        isRunning = false
    }

    private func isCurrent(_ id: UUID) -> Bool { attemptID == id && acceptingEvents }

    private func makePrivateOutput(id: UUID) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JITLauncher/PairingSessions/\(id.uuidString)", isDirectory: true)
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700,
                                                            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let output = directory.appendingPathComponent("pairing.plist")
        try Data().write(to: output, options: .completeFileProtectionUntilFirstUserAuthentication)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        prepared = true
        return output
    }

    private func notificationID(_ id: UUID) -> String { "jitlauncher.pairing.\(id.uuidString)" }
    private func clearNotification(_ id: UUID) {
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationID(id)])
        notifications.removeDeliveredNotifications(withIdentifiers: [notificationID(id)])
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    private func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.attemptID, self.isCurrent(id),
                  notification.request.identifier == self.notificationID(id) else {
                completionHandler([])
                return
            }
            completionHandler([.banner, .sound])
        }
    }
}
