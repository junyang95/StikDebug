import Combine
import Foundation

@MainActor
struct DDIInstallationDependencies {
    var prepare: () async throws -> Void
    var download: (Bool, @escaping @Sendable (Double, String) -> Void) async throws -> Void
    var mount: () async throws -> Void
    var finish: () async -> Void
}

@MainActor
final class DDIInstallationController: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, downloading, mounting, cancelling, completed, cancelled, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var downloadDetail = ""
    private let dependencies: DDIInstallationDependencies
    private var task: Task<Void, Never>?
    private var runID = UUID()

    init(dependencies: DDIInstallationDependencies) { self.dependencies = dependencies }

    var canCancel: Bool { isRunning && (phase == .preparing || phase == .downloading) }

    func start(redownload: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        phase = .preparing
        downloadProgress = 0
        downloadDetail = ""
        let id = UUID()
        runID = id
        task = Task {
            var result: Phase
            do {
                try await dependencies.prepare()
                try Task.checkCancellation()
                phase = .downloading
                try await dependencies.download(redownload) { [weak self] progress, detail in
                    Task { @MainActor in
                        guard let self, self.runID == id, self.phase == .downloading else { return }
                        self.downloadProgress = min(1, max(0, progress))
                        self.downloadDetail = detail
                    }
                }
                try Task.checkCancellation()
                phase = .mounting
                // The native mount cannot safely be interrupted. Closing the sheet is fine.
                try await dependencies.mount()
                result = .completed
            } catch {
                result = Task.isCancelled || error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            await dependencies.finish()
            phase = result
            isRunning = false
            task = nil
        }
    }

    func cancel() {
        guard canCancel else { return }
        phase = .cancelling
        task?.cancel()
    }
}
