import Foundation

/// Serves one MP4 with bearer auth and HTTP 206 ranges, recording Range headers.
final class AuthenticatedRangeHTTPServer: @unchecked Sendable {
    struct RecordedRange: Equatable, Sendable {
        let method: String
        let header: String
        let start: Int64?
        let end: Int64?
        let servedBytes: Int
    }

    private let listenFD: Int32
    private let acceptQueue = DispatchQueue(label: "dev.chenda.oppi.tests.authenticated-range-http")
    private let lock = NSLock()
    private let body: Data
    private let token: String
    private let redirectLocation: String?
    private var stopped = false
    private var clientFDs: [Int32] = []
    private var recordedRangesStorage: [String] = []
    private var recordedParsedStorage: [RecordedRange] = []
    let url: URL

    init(
        body: Data,
        token: String,
        filename: String = "known-good-h264.mp4",
        redirectLocation: String? = nil
    ) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }

        var reuse: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
        }

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLen)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        guard nameResult == 0,
              port > 0,
              let url = URL(string: "http://127.0.0.1:\(port)/\(filename)") else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
        }

        listenFD = fd
        self.body = body
        self.token = token
        self.redirectLocation = redirectLocation
        self.url = url
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func snapshotRanges() -> [String] {
        lock.withLock { recordedRangesStorage }
    }

    func snapshotParsedRanges() -> [RecordedRange] {
        lock.withLock { recordedParsedStorage }
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let clients = clientFDs
        clientFDs.removeAll()
        lock.unlock()
        guard !alreadyStopped else { return }
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        for client in clients {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
    }

    deinit {
        stop()
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            lock.lock()
            if stopped {
                lock.unlock()
                if client >= 0 {
                    Darwin.close(client)
                }
                return
            }
            if client < 0 {
                lock.unlock()
                return
            }
            clientFDs.append(client)
            lock.unlock()
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { closeClient(client) }
        guard let raw = readHeaders(from: client) else { return }
        let lines = raw.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        var authorization = ""
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("authorization:") {
                authorization = String(line.dropFirst("authorization:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("range:") {
                rangeHeader = String(line.dropFirst("range:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        let parsed = Self.parseRange(rangeHeader, total: Int64(body.count))
        lock.lock()
        recordedRangesStorage.append("\(method) \(rangeHeader ?? "none")")
        recordedParsedStorage.append(
            RecordedRange(
                method: method,
                header: rangeHeader ?? "none",
                start: parsed?.start,
                end: parsed?.end,
                servedBytes: 0
            )
        )
        let recordedIndex = recordedParsedStorage.count - 1
        lock.unlock()

        if let redirectLocation {
            write(
                client,
                status: "302 Found",
                headers: [
                    "Location": redirectLocation,
                    "Content-Length": "0",
                ],
                body: Data()
            )
            return
        }

        guard authorization == token else {
            write(client, status: "401 Unauthorized", headers: ["Content-Length": "0"], body: Data())
            return
        }

        let total = Int64(body.count)
        if method == "HEAD" || method == "GET" {
            if let bounds = parsed {
                let start = Int(bounds.start)
                let end = Int(bounds.end)
                let slice = body.subdata(in: start..<(end + 1))
                recordServedBytes(index: recordedIndex, count: method == "HEAD" ? 0 : slice.count)
                write(
                    client,
                    status: "206 Partial Content",
                    headers: [
                        "Content-Type": "video/mp4",
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes \(bounds.start)-\(bounds.end)/\(total)",
                        "Content-Length": "\(slice.count)",
                    ],
                    body: method == "HEAD" ? Data() : slice
                )
            } else {
                recordServedBytes(index: recordedIndex, count: method == "HEAD" ? 0 : body.count)
                write(
                    client,
                    status: "200 OK",
                    headers: [
                        "Content-Type": "video/mp4",
                        "Accept-Ranges": "bytes",
                        "Content-Length": "\(body.count)",
                    ],
                    body: method == "HEAD" ? Data() : body
                )
            }
        } else {
            write(client, status: "405 Method Not Allowed", headers: ["Content-Length": "0"], body: Data())
        }
    }

    private func recordServedBytes(index: Int, count: Int) {
        lock.lock()
        if recordedParsedStorage.indices.contains(index) {
            let current = recordedParsedStorage[index]
            recordedParsedStorage[index] = RecordedRange(
                method: current.method,
                header: current.header,
                start: current.start,
                end: current.end,
                servedBytes: count
            )
        }
        lock.unlock()
    }

    private func closeClient(_ client: Int32) {
        lock.lock()
        let shouldClose = clientFDs.contains(client)
        clientFDs.removeAll { $0 == client }
        lock.unlock()
        guard shouldClose else { return }
        Darwin.close(client)
    }

    static func parseRange(_ header: String?, total: Int64) -> (start: Int64, end: Int64)? {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(header.dropFirst("bytes=".count))
        let bounds = spec.split(separator: "-", maxSplits: 1)
        guard let start = bounds.first.flatMap({ Int64($0) }) else { return nil }
        let end: Int64
        if bounds.count == 2, !bounds[1].isEmpty, let parsedEnd = Int64(bounds[1]) {
            end = parsedEnd
        } else {
            end = total - 1
        }
        guard start >= 0, start < total, end >= start else { return nil }
        return (start, min(end, total - 1))
    }

    private func readHeaders(from fd: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let marker = Data([13, 10, 13, 10])
        for _ in 0..<32 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if let range = data.range(of: marker) {
                return String(data: data.prefix(upTo: range.lowerBound), encoding: .utf8)
            }
            if data.count > 64 * 1024 { break }
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ fd: Int32, status: String, headers: [String: String], body: Data) {
        var header = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (key, value) in headers {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let n = Darwin.send(fd, base + sent, payload.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
