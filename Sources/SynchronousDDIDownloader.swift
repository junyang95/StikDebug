import Foundation

enum SynchronousDDIDownloader {
    static func download(to paths: DDIPaths, progress: @escaping (Double, String) -> Void,
                         cancellationCheck: @escaping () throws -> Void = {}) throws {
        try DDIDownloadRunner.download(to: paths, catalog: DDIAssetCatalog.load(), cancellationCheck: cancellationCheck, progress: progress)
    }
}
