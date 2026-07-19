import CryptoKit
import Foundation
import Security

/// URLSession delegate that optionally pins the leaf certificate fingerprint.
///
/// When no fingerprint is configured, the delegate falls back to default
/// system trust handling.
final class PinnedServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let pinnedLeafFingerprint: String?

    init(pinnedLeafFingerprint: String?) {
        self.pinnedLeafFingerprint = Self.normalizeFingerprint(pinnedLeafFingerprint)
        super.init()
    }

    // Session-level challenge handler.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    // Task-level challenge handler — some iOS versions dispatch here
    // instead of the session-level method, especially in Release builds.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
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
        } else if Self.allowsPublicCATrustFallback(
            forHost: challenge.protectionSpace.host,
            pinnedLeafFingerprint: pinnedLeafFingerprint
        ) {
            completionHandler(.performDefaultHandling, nil)
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

    static func allowsPublicCATrustFallback(
        forHost host: String,
        pinnedLeafFingerprint: String? = nil
    ) -> Bool {
        // A configured pin is authoritative. Public-CA trust is only the
        // no-pin mode used by rotating Tailscale certificates.
        guard normalizeFingerprint(pinnedLeafFingerprint) == nil else { return false }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(".ts.net") || normalized.hasSuffix(".beta.tailscale.net")
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
