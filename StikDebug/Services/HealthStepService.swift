import Foundation
import HealthKit

@MainActor
final class HealthStepService: ObservableObject {
    static let shared = HealthStepService()

    enum WriteState: Equatable {
        case idle
        case unavailable
        case needsAuthorization
        case ready
        case writing
        case failed(String)
    }

    /// 皮克敏官方规定：盆栽花苗每天最多反映 5 万步，超过后当天不再计入花苗成长。
    /// 见 https://niantic.helpshift.com/hc/en/23-pikmin-bloom/faq/3343-faq-about-seedlings/
    static let dailySeedlingStepCap = 50_000
    /// 接近上限时先提醒，留一点余量给真实步数。
    static let dailyCapWarnThreshold = 45_000

    /// 每日花苗上限提醒的阶段，数值越大越紧迫。
    enum DailyCapStage: Int {
        case approaching = 1
        case reached = 2
    }

    @Published private(set) var writeState: WriteState = .idle
    @Published private(set) var todayTotalSteps = 0
    @Published private(set) var todayAppSteps = 0
    /// 待展示的花苗上限提醒；UI 消费后置回 nil。同一天同一阶段只提醒一次。
    @Published var pendingCapNotice: DailyCapStage?

    private let store = HKHealthStore()
    private let stepType = HKQuantityType(.stepCount)

    private init() {
        writeState = HKHealthStore.isHealthDataAvailable() ? .needsAuthorization : .unavailable
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            writeState = .unavailable
            return false
        }

        do {
            try await store.requestAuthorization(toShare: [stepType], read: [stepType])
            guard store.authorizationStatus(for: stepType) == .sharingAuthorized else {
                writeState = .needsAuthorization
                return false
            }
            writeState = .ready
            await refreshToday()
            return true
        } catch {
            writeState = .failed(error.localizedDescription)
            return false
        }
    }

    func writeSteps(
        _ count: Int,
        from startDate: Date,
        to endDate: Date,
        sessionID: UUID
    ) async -> Bool {
        guard count > 0 else { return true }
        guard store.authorizationStatus(for: stepType) == .sharingAuthorized else {
            writeState = .needsAuthorization
            return false
        }

        writeState = .writing
        let quantity = HKQuantity(unit: .count(), doubleValue: Double(count))
        let metadata: [String: Any] = [
            "com.pikminhelper.session-id": sessionID.uuidString,
            HKMetadataKeySyncIdentifier: "pikminhelper-\(sessionID.uuidString)-\(startDate.timeIntervalSince1970)",
            HKMetadataKeySyncVersion: 1
        ]
        let sample = HKQuantitySample(
            type: stepType,
            quantity: quantity,
            start: startDate,
            end: max(startDate, endDate),
            metadata: metadata
        )

        do {
            try await store.save(sample)
            writeState = .ready
            await refreshToday()
            return true
        } catch {
            writeState = .failed(error.localizedDescription)
            return false
        }
    }

    func refreshToday() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        do {
            let samples = try await samples(matching: predicate)
            todayTotalSteps = try await cumulativeSteps(matching: predicate)
            let bundleIdentifier = Bundle.main.bundleIdentifier
            todayAppSteps = samples
                .filter { $0.sourceRevision.source.bundleIdentifier == bundleIdentifier }
                .reduce(0) { partial, sample in
                    partial + Int(sample.quantity.doubleValue(for: .count()))
                }
            evaluateDailyCap()
        } catch {
            writeState = .failed(error.localizedDescription)
        }
    }

    /// 步数刷新后检查是否跨过每日花苗上限的提醒阈值。
    /// 同一天里，同一或更低的阶段不重复弹；升级到更高阶段（接近→已达）会再弹一次。
    private func evaluateDailyCap() {
        let stage: DailyCapStage?
        if todayTotalSteps >= Self.dailySeedlingStepCap {
            stage = .reached
        } else if todayTotalSteps >= Self.dailyCapWarnThreshold {
            stage = .approaching
        } else {
            stage = nil
        }
        guard let stage else { return }

        let dayKey = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let defaults = UserDefaults.standard
        let shownStage = defaults.integer(forKey: "dailyCapNoticeDay") == dayKey
            ? defaults.integer(forKey: "dailyCapNoticeStage")
            : 0

        guard stage.rawValue > shownStage else { return }
        defaults.set(dayKey, forKey: "dailyCapNoticeDay")
        defaults.set(stage.rawValue, forKey: "dailyCapNoticeStage")
        pendingCapNotice = stage
    }

    func deleteAppWrittenSteps() async -> Bool {
        let predicate = HKQuery.predicateForSamples(withStart: .distantPast, end: Date(), options: [])
        do {
            let bundleIdentifier = Bundle.main.bundleIdentifier
            let ownSamples = try await samples(matching: predicate)
                .filter { $0.sourceRevision.source.bundleIdentifier == bundleIdentifier }
            try await store.delete(ownSamples)
            await refreshToday()
            return true
        } catch {
            writeState = .failed(error.localizedDescription)
            return false
        }
    }

    private func cumulativeSteps(matching predicate: NSPredicate) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(value))
            }
            store.execute(query)
        }
    }

    private func samples(matching predicate: NSPredicate) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: stepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }
}
