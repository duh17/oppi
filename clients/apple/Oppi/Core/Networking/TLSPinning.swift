import CryptoKit
import Foundation
import Security

/// URLSession delegate that optionally pins the leaf certificate fingerprint.
///
/// When no fingerprint is configured, the delegate falls back to default
/// system trust handling.
final class PinnedServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let pinnedLeafFingerprint: String?
    private(set) var expectedServerName: String?

    init(pinnedLeafFingerprint: String?, expectedServerName: String? = nil) {
        self.pinnedLeafFingerprint = Self.normalizeFingerprint(pinnedLeafFingerprint)
        self.expectedServerName = expectedServerName?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            guard let expectedServerName,
                  !expectedServerName.isEmpty,
                  Self.allowsPublicCATrustFallback(forHost: expectedServerName) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            // URLSession connected to a discovered LAN IP. Re-evaluate the
            // server's public certificate against the exact hostname carried
            // in signed pairing metadata instead of the IP protection space.
            let policy = SecPolicyCreateSSL(true, expectedServerName as CFString)
            guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCertificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certData = SecCertificateCopyData(leafCertificate) as Data
        let fingerprint = Self.certFingerprint(for: certData)

        switch ServerTLSTrustPolicy.decision(
            pinnedLeafFingerprint: pinnedLeafFingerprint,
            presentedFingerprint: fingerprint,
            host: challenge.protectionSpace.host
        ) {
        case .pinMatch:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .publicCAFallback:
            completionHandler(.performDefaultHandling, nil)
        case .reject:
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
        ServerTLSTrustPolicy.allowsPublicCATrustFallback(
            forHost: host,
            pinnedLeafFingerprint: pinnedLeafFingerprint
        )
    }

    private static func normalizeFingerprint(_ value: String?) -> String? {
        ServerTLSTrustPolicy.normalizeFingerprint(value)
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
