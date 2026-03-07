import CryptoKit
import Foundation
import Security

/// URLSession delegate that optionally pins the leaf certificate fingerprint.
///
/// When no fingerprint is configured, the delegate falls back to default
/// system trust handling.
final class PinnedServerTrustDelegate: NSObject, URLSessionDelegate {
    private let pinnedLeafFingerprint: String?

    init(pinnedLeafFingerprint: String?) {
        self.pinnedLeafFingerprint = Self.normalizeFingerprint(pinnedLeafFingerprint)
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let pinnedLeafFingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCertificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certData = SecCertificateCopyData(leafCertificate) as Data
        let fingerprint = Self.certFingerprint(for: certData)

        if fingerprint == pinnedLeafFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Compute the `sha256:<base64url>` fingerprint for raw DER certificate data.
    ///
    /// Exposed as `internal` so unit tests can exercise the fingerprint
    /// calculation without going through a live URLAuthenticationChallenge.
    static func certFingerprint(for certData: Data) -> String {
        let digest = Data(SHA256.hash(data: certData))
        return "sha256:\(digest.base64URLEncodedString())"
    }

    private static func normalizeFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
