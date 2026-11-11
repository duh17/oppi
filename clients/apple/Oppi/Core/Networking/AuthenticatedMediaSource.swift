import Foundation

/// Bearer-authenticated media endpoint for AVFoundation resource loading.
///
/// The auth token stays in the `Authorization` header. It is never embedded in
/// the media URL that AVPlayer sees. The loader resolves a fresh bearer via
/// `authorizationProvider` on every range request, so long playback outlives a
/// short-lived access token.
struct AuthenticatedMediaSource: Sendable {
    let url: URL
    /// Returns the full `Authorization` header value (`Bearer …`), resolved per
    /// request so media playback refreshes instead of snapshotting one bearer.
    let authorizationProvider: @Sendable () async throws -> String
    let tlsCertFingerprint: String?
    let tlsServerName: String?
    let contentTypeHint: String?
    let sourceFileExtension: String?
    /// `/files/current/media-info` for the same file. Nil for sources the
    /// server cannot describe (session attachments).
    let mediaInfoURL: URL?

    init(
        url: URL,
        authorizationProvider: @escaping @Sendable () async throws -> String,
        tlsCertFingerprint: String?,
        tlsServerName: String? = nil,
        contentTypeHint: String?,
        sourceFileExtension: String?,
        mediaInfoURL: URL? = nil
    ) {
        self.url = url
        self.authorizationProvider = authorizationProvider
        self.tlsCertFingerprint = tlsCertFingerprint
        self.tlsServerName = tlsServerName
        self.contentTypeHint = contentTypeHint
        self.sourceFileExtension = sourceFileExtension
        self.mediaInfoURL = mediaInfoURL
    }

    /// Convenience for tests and static-credential callers.
    init(
        url: URL,
        authorizationHeaderValue: String,
        tlsCertFingerprint: String?,
        tlsServerName: String? = nil,
        contentTypeHint: String?,
        sourceFileExtension: String?,
        mediaInfoURL: URL? = nil
    ) {
        self.init(
            url: url,
            authorizationProvider: { authorizationHeaderValue },
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension,
            mediaInfoURL: mediaInfoURL
        )
    }

    var identity: String {
        [
            url.absoluteString,
            tlsCertFingerprint ?? "",
            tlsServerName ?? "",
            contentTypeHint ?? "",
            sourceFileExtension ?? ""
        ].joined(separator: "|")
    }

    /// Fetch the complete media file only for an explicit export/share action.
    /// Playback continues to use range requests through the AV resource loader.
    func loadFileData(configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        try await authenticatedGET(url, configuration: configuration)
    }

    /// Downloads the complete file to `destination` for Share, reporting bytes
    /// as they arrive. Nothing is held in memory, so a long video costs disk
    /// only. Cancelling the task stops the transfer. A refused request throws
    /// `FileDownloadError.rejected` with the server's status and words.
    func downloadFile(
        to destination: URL,
        configuration: URLSessionConfiguration,
        onProgress: @escaping @Sendable (FileDownloadProgress) -> Void
    ) async throws {
        let authorization = try await authorizationProvider()
        guard !authorization.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let delegate = AuthenticatedFileDownloadTaskDelegate(
            pinnedLeafFingerprint: tlsCertFingerprint,
            expectedServerName: tlsServerName,
            destination: destination,
            onProgress: onProgress
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Header-derived length, without downloading audio bytes. Nil when the
    /// source has no media-info route or the server could not read a length.
    func loadDurationSeconds(
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> TimeInterval? {
        guard let mediaInfoURL else { return nil }
        let data = try await authenticatedGET(mediaInfoURL, configuration: configuration)
        // A `format` or `tags` section this app cannot decode costs those fields,
        // not the length the body states.
        let decoder = JSONDecoder()
        guard
            let duration =
                (try? decoder.decode(MediaInfo.self, from: data))?.durationSeconds
                ?? (try? decoder.decode(MediaInfoDuration.self, from: data))?.durationSeconds,
            duration.isFinite,
            duration >= 0
        else { return nil }
        return duration
    }

    private func authenticatedGET(
        _ url: URL,
        configuration: URLSessionConfiguration
    ) async throws -> Data {
        let authorization = try await authorizationProvider()
        guard !authorization.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let delegate = AuthenticatedMediaFileDownloadDelegate(
            pinnedLeafFingerprint: tlsCertFingerprint,
            expectedServerName: tlsServerName
        )
        TailnetTransportRoute.apply(to: configuration)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Keeps file sharing on the same TLS trust boundary as range playback and
/// refuses redirects so an Authorization header cannot be replayed elsewhere.
class AuthenticatedMediaFileDownloadDelegate: NSObject, @unchecked Sendable,
    URLSessionDelegate, URLSessionTaskDelegate {
    private let trustDelegate: PinnedServerTrustDelegate

    init(pinnedLeafFingerprint: String?, expectedServerName: String?) {
        trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: pinnedLeafFingerprint,
            expectedServerName: expectedServerName
        )
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trustDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trustDelegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Bytes of a file download so far. `expected` is nil when the response
/// states no length.
struct FileDownloadProgress: Sendable, Equatable {
    let received: Int64
    let expected: Int64?
}

enum FileDownloadError: Error, Equatable {
    /// The server answered with a status that is not success: 413 for a file
    /// over its size limit for the kind. `message` is its JSON `error`, when
    /// it sent one.
    case rejected(status: Int, message: String?)
}

/// One download task's delegate: progress while bytes arrive, then the file
/// moved into place, or the reason there is none.
private final class AuthenticatedFileDownloadTaskDelegate: AuthenticatedMediaFileDownloadDelegate,
    URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (FileDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// What `didFinishDownloadingTo` made of the response; the task's
    /// completion resumes with it.
    private var failure: Error?

    init(
        pinnedLeafFingerprint: String?,
        expectedServerName: String?,
        destination: URL,
        onProgress: @escaping @Sendable (FileDownloadProgress) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        super.init(pinnedLeafFingerprint: pinnedLeafFingerprint, expectedServerName: expectedServerName)
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // An error body is not the file: its bytes are not progress.
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        onProgress(FileDownloadProgress(
            received: totalBytesWritten,
            expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        ))
    }

    /// The temporary file is gone when this returns, so it is moved or read here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result: Error?
        if let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: location, to: destination)
                result = nil
            } catch {
                result = error
            }
        } else {
            struct Body: Decodable { let error: String }
            let body = try? Data(contentsOf: location)
            result = FileDownloadError.rejected(
                status: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0,
                message: body.flatMap { try? JSONDecoder().decode(Body.self, from: $0).error }
            )
        }
        lock.withLock { failure = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.failure)
        }
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            continuation?.resume(throwing: cancelled ? CancellationError() : error)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}

/// `durationSeconds` alone, for a body whose `format` or `tags` section does not
/// decode: the length the player needs is a field of its own.
private struct MediaInfoDuration: Decodable {
    let durationSeconds: Double?
}
