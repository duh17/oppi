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

    init(
        url: URL,
        authorizationProvider: @escaping @Sendable () async throws -> String,
        tlsCertFingerprint: String?,
        tlsServerName: String? = nil,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) {
        self.url = url
        self.authorizationProvider = authorizationProvider
        self.tlsCertFingerprint = tlsCertFingerprint
        self.tlsServerName = tlsServerName
        self.contentTypeHint = contentTypeHint
        self.sourceFileExtension = sourceFileExtension
    }

    /// Convenience for tests and static-credential callers.
    init(
        url: URL,
        authorizationHeaderValue: String,
        tlsCertFingerprint: String?,
        tlsServerName: String? = nil,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) {
        self.init(
            url: url,
            authorizationProvider: { authorizationHeaderValue },
            tlsCertFingerprint: tlsCertFingerprint,
            tlsServerName: tlsServerName,
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
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
final class AuthenticatedMediaFileDownloadDelegate: NSObject, @unchecked Sendable,
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
