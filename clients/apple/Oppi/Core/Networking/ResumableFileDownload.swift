import CryptoKit
import Foundation
import UIKit

/// One file download from the server's current-file route to disk, which
/// survives a dropped connection and the app leaving the screen.
///
/// Every byte goes straight to a `.part` file beside the destination as it
/// arrives; nothing is held in memory. When the connection drops, the next
/// attempt asks for the rest (`Range: bytes=<have>-`) with the version the
/// first answer named (`If-Range: <ETag>`): the server sends the rest while
/// the file is unchanged, else the whole new file as a 200, which starts the
/// `.part` over. An attempt that fails while the app is in the background
/// waits for it to come back. Each attempt resolves a fresh bearer and checks
/// the pinned server certificate like every other request to that server.
///
/// When the server sends the whole file's SHA-256 (`X-Oppi-File-Digest`), the
/// finished file is hashed from disk and must match before it is moved into
/// place; otherwise the `.part` is deleted and `FileDownloadError.digestMismatch`
/// thrown. A text-like file may arrive Brotli or gzip coded; URLSession decodes
/// it, so the `.part` always holds the file's own bytes and a resume's offset
/// is an offset into them.
///
/// Why not a background URLSession: a server reached over the tailnet goes
/// through the app's own SOCKS proxy (`TailnetTransportRoute`), which stops
/// when the app is suspended, so the system's download daemon could not reach
/// it; and a background task's partial bytes come back only as resume data
/// that replays the first request's bearer, which the device session may have
/// refreshed by then. The app asks for background time instead
/// (`FileSharePresenter.download`) and resumes from the `.part` on return.
struct ResumableFileDownload: Sendable {
    let url: URL
    let authorizationProvider: @Sendable () async throws -> String
    let pinnedLeafFingerprint: String?
    let expectedServerName: String?
    let configuration: URLSessionConfiguration
    /// Waits between attempts after an interruption; one attempt per entry.
    var retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// Returns once the app is in the foreground.
    var waitUntilActive: @Sendable () async -> Void = { await Self.waitForForeground() }

    /// The request header that asks for the whole file's digest, and the answer's.
    static let digestRequestHeader = "X-Oppi-Want-File-Digest"
    static let digestResponseHeader = "X-Oppi-File-Digest"

    func run(to destination: URL, onProgress: @escaping @Sendable (FileDownloadProgress) -> Void) async throws {
        let partial = destination.appendingPathExtension("part")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: partial.path) {
            fileManager.createFile(atPath: partial.path, contents: nil)
        }
        var version = Version()
        var interruptions = 0
        do {
            while true {
                try Task.checkCancellation()
                do {
                    try await attempt(partial: partial, version: &version, onProgress: onProgress)
                    break
                } catch let error where Self.isInterruption(error) && interruptions < retryDelays.count {
                    await waitUntilActive()
                    try await Task.sleep(for: retryDelays[interruptions])
                    interruptions += 1
                }
            }
            if let digest = version.digest {
                let actual = try await Self.sha256(of: partial)
                guard actual == digest else { throw FileDownloadError.digestMismatch }
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    /// What the server said about the file: the version a resume must match,
    /// the whole file's digest, and its size.
    struct Version: Sendable {
        var etag: String?
        var digest: String?
        var total: Int64?
    }

    /// One request for the bytes the `.part` does not have yet; throws when
    /// the attempt ends early. `version` takes what this answer said, also
    /// when it dropped: the next attempt resumes against that version.
    private func attempt(
        partial: URL,
        version: inout Version,
        onProgress: @escaping @Sendable (FileDownloadProgress) -> Void
    ) async throws {
        let have = Int64((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let authorization = try await authorizationProvider()
        guard !authorization.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // Ranged even from the first byte: the server caps only whole reads,
        // which a viewer holds in memory.
        request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
        if have > 0, let etag = version.etag {
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }
        request.setValue("sha-256", forHTTPHeaderField: Self.digestRequestHeader)

        let delegate = StreamingFileDelegate(
            partial: partial,
            have: have,
            version: version,
            pinnedLeafFingerprint: pinnedLeafFingerprint,
            expectedServerName: expectedServerName,
            onProgress: onProgress
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        defer { version = delegate.currentVersion }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// A transfer that ended because the connection did, not because the
    /// server refused: worth resuming.
    static func isInterruption(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
            .callIsActive, .backgroundSessionWasDisconnected, .resourceUnavailable,
        ].contains(urlError.code)
    }

    /// Base64 SHA-256 of a file, read in 1 MiB pieces off the main thread.
    static func sha256(of file: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize()).base64EncodedString()
        }.value
    }

    @MainActor
    static func waitForForeground() async {
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

/// One attempt's delegate: decides from the status whether the bytes extend
/// the `.part` (206 from where it ends) or replace it (200), writes them as
/// they arrive, and reports progress over the whole file.
private final class StreamingFileDelegate: AuthenticatedMediaFileDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let have: Int64
    private let onProgress: @Sendable (FileDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResumableFileDownload.Version, Error>?
    private var version: ResumableFileDownload.Version
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var startOffset: Int64 = 0
    /// Why the attempt ended other than by the connection: a refusal, a write failure.
    private var failure: Error?
    /// The file was already whole: a 416 naming the size the `.part` has.
    private var alreadyComplete = false
    /// A refusal's JSON body, at most 64 KB of it.
    private var errorBody: Data?
    private var errorStatus = 0

    init(
        partial: URL,
        have: Int64,
        version: ResumableFileDownload.Version,
        pinnedLeafFingerprint: String?,
        expectedServerName: String?,
        onProgress: @escaping @Sendable (FileDownloadProgress) -> Void
    ) {
        self.partial = partial
        self.have = have
        self.version = version
        self.onProgress = onProgress
        super.init(pinnedLeafFingerprint: pinnedLeafFingerprint, expectedServerName: expectedServerName)
    }

    func start(_ continuation: CheckedContinuation<ResumableFileDownload.Version, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// What the server has said so far about the file, however the attempt ended.
    var currentVersion: ResumableFileDownload.Version { lock.withLock { version } }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(URLError(.badServerResponse), completionHandler)
            return
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(ContentRange.init)
        lock.withLock {
            if let etag = http.value(forHTTPHeaderField: "ETag") { version.etag = etag }
            if let digest = http.value(forHTTPHeaderField: ResumableFileDownload.digestResponseHeader) {
                version.digest = Self.base64Digest(digest)
            }
        }
        switch http.statusCode {
        case 206:
            guard let contentRange, contentRange.start == have else {
                fail(URLError(.badServerResponse), completionHandler)
                return
            }
            open(from: have, total: contentRange.total, completionHandler)
        case 200:
            // A whole file: the first answer, or the file changed since the
            // `.part` began. Its length is unknown when it arrives coded.
            let coded = http.value(forHTTPHeaderField: "Content-Encoding") != nil
            open(from: 0, total: coded ? nil : (http.expectedContentLength >= 0 ? http.expectedContentLength : nil), completionHandler)
        case 416 where contentRange?.unsatisfiedTotal == have:
            // Nothing past what the `.part` holds: an empty file, or a drop
            // after the last byte.
            lock.withLock {
                alreadyComplete = true
                version.total = have
            }
            completionHandler(.cancel)
        default:
            lock.withLock {
                errorStatus = http.statusCode
                errorBody = Data()
            }
            completionHandler(.allow)
        }
    }

    private func open(
        from offset: Int64,
        total: Int64?,
        _ completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seekToEnd()
            lock.withLock {
                self.handle = handle
                startOffset = offset
                if let total { version.total = total }
            }
            completionHandler(.allow)
        } catch {
            fail(error, completionHandler)
        }
    }

    private func fail(_ error: Error, _ completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { failure = error }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let progress: FileDownloadProgress? = lock.withLock {
            if errorBody != nil {
                if (errorBody?.count ?? 0) < 65_536 { errorBody?.append(data) }
                return nil
            }
            guard let handle, failure == nil else { return nil }
            do {
                try handle.write(contentsOf: data)
            } catch {
                failure = error
                return nil
            }
            written += Int64(data.count)
            return FileDownloadProgress(received: startOffset + written, expected: version.total)
        }
        if let progress {
            onProgress(progress)
        } else if lock.withLock({ failure != nil }) {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<ResumableFileDownload.Version, Error>?, Result<ResumableFileDownload.Version, Error>) in
            try? handle?.close()
            handle = nil
            defer { self.continuation = nil }
            if alreadyComplete { return (self.continuation, .success(version)) }
            if let failure { return (self.continuation, .failure(failure)) }
            if let errorBody {
                struct Body: Decodable { let error: String }
                let message = (try? JSONDecoder().decode(Body.self, from: errorBody))?.error
                return (self.continuation, .failure(FileDownloadError.rejected(status: errorStatus, message: message)))
            }
            if let error {
                let cancelled = (error as? URLError)?.code == .cancelled
                return (self.continuation, .failure(cancelled ? CancellationError() : error))
            }
            // A stated size the bytes fell short of is a dropped connection.
            if let total = version.total, startOffset + written != total {
                return (self.continuation, .failure(URLError(.networkConnectionLost)))
            }
            return (self.continuation, .success(version))
        }
        continuation?.resume(with: result)
    }

    /// `sha-256=:<base64>:` to its base64.
    private static func base64Digest(_ header: String) -> String? {
        let prefix = "sha-256=:"
        guard header.hasPrefix(prefix), header.hasSuffix(":"), header.count > prefix.count + 1 else { return nil }
        return String(header.dropFirst(prefix.count).dropLast())
    }
}

/// `Content-Range: bytes <start>-<end>/<total>`, or `bytes */<total>` on a 416.
private struct ContentRange {
    var start: Int64?
    var total: Int64?
    var unsatisfiedTotal: Int64?

    init?(_ header: String) {
        guard header.hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst("bytes ".count)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let total = Int64(parts[1])
        if parts[0] == "*" {
            unsatisfiedTotal = total
            return
        }
        guard let first = parts[0].split(separator: "-").first, let start = Int64(first) else { return nil }
        self.start = start
        self.total = total
    }
}
