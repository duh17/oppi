import CryptoKit
import Darwin
import Foundation

/// Owner Unix-socket path used by the local CLI and the Mac app.
///
/// Matches `server/src/local-api-socket.ts`: prefer `$dataDir/run/oppi.sock`
/// when that path fits the portable sockaddr limit; otherwise use a hashed
/// path under `/tmp`. The owner `sk_` token is accepted only on this socket.
enum MacLocalAPISocket {
    static let maxPathBytes = 100
    static let runtimeDirectory = "run"
    static let socketName = "oppi.sock"

    static func path(dataDir: String) -> String {
        let preferred = URL(fileURLWithPath: dataDir)
            .appendingPathComponent(runtimeDirectory, isDirectory: true)
            .appendingPathComponent(socketName, isDirectory: false)
            .path
        if utf8ByteCount(preferred) <= maxPathBytes {
            return preferred
        }

        let resolved = (dataDir as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(resolved.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let fallback = "/tmp/oppi-\(getuid())/\(hash).sock"
        return fallback
    }

    private static func utf8ByteCount(_ path: String) -> Int {
        path.lengthOfBytes(using: .utf8)
    }
}

struct MacLocalHTTPRequest: Sendable, Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?

    init(method: String, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

struct MacLocalHTTPResponse: Sendable, Equatable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

protocol MacLocalHTTPPerforming: Sendable {
    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse
}

enum MacLocalHTTPError: Error, Equatable, LocalizedError {
    case timeout
    case connectionFailed(String)
    case invalidResponse
    case incompleteResponse

    var errorDescription: String? {
        switch self {
        case .timeout:
            "Local server request timed out."
        case .connectionFailed(let message):
            "Could not connect to the local Oppi socket: \(message)"
        case .invalidResponse:
            "Local server returned an invalid HTTP response."
        case .incompleteResponse:
            "Local server closed the connection before the HTTP response finished."
        }
    }
}

enum MacLocalHTTPCodec {
    static func encode(_ request: MacLocalHTTPRequest) -> Data {
        var headerLines = [
            "\(request.method) \(request.path) HTTP/1.1",
            "Host: localhost",
            "Connection: close",
        ]
        var headers = request.headers
        if let body = request.body {
            headers["Content-Length"] = String(body.count)
        } else if request.method != "GET" && request.method != "HEAD" && request.method != "DELETE" {
            headers["Content-Length"] = "0"
        }
        for key in headers.keys.sorted() {
            headerLines.append("\(key): \(headers[key] ?? "")")
        }
        var data = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body = request.body {
            data.append(body)
        }
        return data
    }

    static func parse(_ buffer: Data, connectionClosed: Bool) throws -> MacLocalHTTPResponse? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            if connectionClosed { throw MacLocalHTTPError.invalidResponse }
            return nil
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw MacLocalHTTPError.invalidResponse
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { throw MacLocalHTTPError.invalidResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1]) else {
            throw MacLocalHTTPError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        let bodyStart = headerRange.upperBound
        let availableBody = buffer.subdata(in: bodyStart..<buffer.endIndex)
        if headers["transfer-encoding"]?.localizedCaseInsensitiveContains("chunked") == true {
            guard let body = decodeChunked(availableBody) else {
                if connectionClosed { throw MacLocalHTTPError.incompleteResponse }
                return nil
            }
            return MacLocalHTTPResponse(statusCode: statusCode, headers: headers, body: body)
        }
        if let lengthValue = headers["content-length"], let length = Int(lengthValue) {
            if availableBody.count < length {
                if connectionClosed { throw MacLocalHTTPError.incompleteResponse }
                return nil
            }
            let body = availableBody.prefix(length)
            return MacLocalHTTPResponse(statusCode: statusCode, headers: headers, body: Data(body))
        }

        if connectionClosed {
            return MacLocalHTTPResponse(statusCode: statusCode, headers: headers, body: availableBody)
        }
        return nil
    }

    /// Decode HTTP/1.1 chunked bodies. Returns nil until the terminating 0-size chunk arrives.
    static func decodeChunked(_ data: Data) -> Data? {
        let crlf = Data("\r\n".utf8)
        var index = data.startIndex
        var body = Data()
        while true {
            guard let lineEnd = data[index...].range(of: crlf) else { return nil }
            let sizeLine = data[index..<lineEnd.lowerBound]
            guard let sizeText = String(data: Data(sizeLine), encoding: .utf8) else { return nil }
            let hex = sizeText.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(hex, radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 {
                return body
            }
            let remaining = data.distance(from: index, to: data.endIndex)
            guard remaining >= size + crlf.count else { return nil }
            let chunkEnd = data.index(index, offsetBy: size)
            body.append(data[index..<chunkEnd])
            index = chunkEnd
            guard data[index...].starts(with: crlf) else { return nil }
            index = data.index(index, offsetBy: crlf.count)
        }
    }
}

func macLocalAuthenticatedRequest(
    method: String,
    path: String,
    token: String,
    body: Data? = nil,
    contentType: String? = nil
) -> MacLocalHTTPRequest {
    var headers = ["Authorization": "Bearer \(token)"]
    if let contentType {
        headers["Content-Type"] = contentType
    }
    return MacLocalHTTPRequest(method: method, path: path, headers: headers, body: body)
}
