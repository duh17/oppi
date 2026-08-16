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
}
