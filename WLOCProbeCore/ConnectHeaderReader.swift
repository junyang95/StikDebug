import Foundation

/// Interprets a single receive callback without depending on TCP packet boundaries.
/// Transport errors must be handled by the caller before passing content here.
struct ConnectHeaderReader {
    enum Outcome: Equatable {
        case needMore
        case endBeforeRequest
        case connect(ConnectRequest, clientReadClosed: Bool)
    }

    private var parser = ConnectRequestParser()

    mutating func receive(_ data: Data?, eof: Bool) throws -> Outcome {
        if let data, let request = try parser.append(data) {
            // FIN closes only this read direction, not the client's ability to receive.
            return .connect(request, clientReadClosed: eof)
        }
        return eof ? .endBeforeRequest : .needMore
    }
}
