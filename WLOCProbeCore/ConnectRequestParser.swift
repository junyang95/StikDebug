import Foundation

struct ConnectRequest: Equatable {
    let host: String
    let initialPayload: Data
}

enum ConnectRequestError: Error, Equatable {
    case malformed
    case forbidden
    case headerTooLarge

    var response: Data {
        let status: String
        switch self {
        case .malformed: status = "400 Bad Request"
        case .forbidden: status = "403 Forbidden"
        case .headerTooLarge: status = "431 Request Header Fields Too Large"
        }
        return Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
    }
}

struct ConnectRequestParser {
    private var buffer = Data()
    private let terminator = Data([13, 10, 13, 10])

    mutating func append(_ data: Data) throws -> ConnectRequest? {
        buffer.append(data)
        guard let range = buffer.range(of: terminator) else {
            guard buffer.count <= WLOCProbePolicy.maximumHeaderBytes else {
                throw ConnectRequestError.headerTooLarge
            }
            return nil
        }
        guard range.upperBound <= WLOCProbePolicy.maximumHeaderBytes else {
            throw ConnectRequestError.headerTooLarge
        }
        let header = buffer[..<range.lowerBound]
        guard header.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: header, encoding: .ascii) else {
            throw ConnectRequestError.malformed
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[0] == "CONNECT",
              ["HTTP/1.0", "HTTP/1.1"].contains(String(requestLine[2])) else {
            throw ConnectRequestError.malformed
        }
        // An exact authority check rejects userinfo, alternate ports, IP literals and suffix tricks.
        let authority = requestLine[1].lowercased()
        guard let host = WLOCProbePolicy.hosts.first(where: { authority == "\($0):443" }) else {
            throw ConnectRequestError.forbidden
        }
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw ConnectRequestError.malformed
            }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            // No HTTP request bodies, pipelining or alternate authority interpretation.
            if name == "transfer-encoding" || (name == "content-length" && value != "0") {
                throw ConnectRequestError.malformed
            }
            if name == "host" && value.lowercased() != authority {
                throw ConnectRequestError.malformed
            }
        }
        let payload = Data(buffer[range.upperBound...])
        buffer.removeAll(keepingCapacity: false)
        return ConnectRequest(host: host, initialPayload: payload)
    }
}
