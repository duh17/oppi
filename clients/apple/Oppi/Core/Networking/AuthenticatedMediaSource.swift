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
    /// as they arrive, resuming after a dropped connection and verifying the
    /// server's digest (`ResumableFileDownload`). Nothing is held in memory,
    /// so a long video costs disk only. Cancelling the task stops the transfer
    /// and leaves no file. A refused request throws `FileDownloadError.rejected`
    /// with the server's status and words.
    func downloadFile(
        to destination: URL,
        configuration: URLSessionConfiguration,
        onProgress: @escaping @Sendable (FileDownloadProgress) -> Void
    ) async throws {
        try await resumableDownload(configuration: configuration).run(to: destination, onProgress: onProgress)
    }

    /// This file's download, through the same bearer and pinned certificate as playback.
    func resumableDownload(configuration: URLSessionConfiguration) -> ResumableFileDownload {
        let endpoint = downloadEndpoint(configuration: configuration)
        return ResumableFileDownload { endpoint }
    }

    /// Where a download of this file goes, for one attempt.
    func downloadEndpoint(configuration: URLSessionConfiguration) -> ResumableFileDownload.Endpoint {
        ResumableFileDownload.Endpoint(
            url: url,
            authorizationProvider: authorizationProvider,
            pinnedLeafFingerprint: tlsCertFingerprint,
            expectedServerName: tlsServerName,
            configuration: configuration
        )
    }

    /// What a HEAD says about the file: its size and when it last changed.
    /// A refused request throws `FileDownloadError.rejected` with its status.
    func loadFileHead(configuration: URLSessionConfiguration) async throws -> RemoteFileHead {
        let authorization = try await authorizationProvider()
        guard !authorization.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let delegate = AuthenticatedMediaFileDownloadDelegate(
            pinnedLeafFingerprint: tlsCertFingerprint,
            expectedServerName: tlsServerName
        )
        TailnetTransportRoute.apply(to: configuration)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw FileDownloadError.rejected(status: http.statusCode, message: nil)
        }
        return RemoteFileHead(response: http)
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
/// states no length. `reconnecting` while the connection dropped and the
/// download waits to resume from `received`.
struct FileDownloadProgress: Sendable, Equatable {
    let received: Int64
    let expected: Int64?
    var reconnecting = false
}

/// A file's size and modification time, from the headers of a HEAD.
struct RemoteFileHead: Sendable, Equatable {
    let byteCount: Int64?
    let modifiedAt: Date?

    init(byteCount: Int64?, modifiedAt: Date?) {
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }

    init(response: HTTPURLResponse) {
        let length = response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        byteCount = length.flatMap { $0 >= 0 ? $0 : nil }
        modifiedAt = response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
    }

    /// An HTTP date (`Wed, 04 Mar 2026 05:06:07 GMT`, RFC 9110).
    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

enum FileDownloadError: Error, Equatable {
    /// The server answered with a status that is not success: 413 for a file
    /// over its size limit for the kind. `message` is its JSON `error`, when
    /// it sent one.
    case rejected(status: Int, message: String?)
    /// The finished file's SHA-256 is not the one the server sent: it
    /// changed or was damaged in transfer. Nothing is kept.
    case digestMismatch
}

/// `durationSeconds` alone, for a body whose `format` or `tags` section does not
/// decode: the length the player needs is a field of its own.
private struct MediaInfoDuration: Decodable {
    let durationSeconds: Double?
}
