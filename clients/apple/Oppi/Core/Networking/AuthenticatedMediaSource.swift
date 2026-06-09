import CryptoKit
import Foundation

/// Bearer-authenticated media endpoint for AVFoundation resource loading.
///
/// The auth token stays in the `Authorization` header. It is never embedded in
/// the media URL that AVPlayer sees.
struct AuthenticatedMediaSource: Sendable {
    let url: URL
    let authorizationHeaderValue: String
    let tlsCertFingerprint: String?
    let contentTypeHint: String?
    let sourceFileExtension: String?

    var identity: String {
        [
            url.absoluteString,
            authorizationIdentity,
            tlsCertFingerprint ?? "",
            contentTypeHint ?? "",
            sourceFileExtension ?? ""
        ].joined(separator: "|")
    }

    private var authorizationIdentity: String {
        let digest = SHA256.hash(data: Data(authorizationHeaderValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
