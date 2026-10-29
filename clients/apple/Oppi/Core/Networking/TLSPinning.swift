import Foundation
import Security

/// URLSession delegate that optionally pins the leaf certificate fingerprint.
///
/// When no fingerprint is configured, the delegate falls back to default
/// system trust handling.
final class PinnedServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let pinnedLeafFingerprint: String?
    let expectedServerName: String?
    private let followsRedirects: Bool
    private let rejectionLock = NSLock()
    private var rejections = 0

    /// What a rejected certificate says when it surfaces as an error.
    static let rejectionMessage = "The server's certificate doesn't match the paired one."

    /// How many server-trust challenges this delegate has rejected. URLSession
    /// reports each one as a cancelled request, so a caller that sees
    /// `URLError.cancelled` reads this before and after to tell the two apart.
    var rejectionCount: Int { rejectionLock.withLock { rejections } }

    private func reject(_ completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        rejectionLock.withLock { rejections += 1 }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    init(pinnedLeafFingerprint: String?, expectedServerName: String? = nil, followsRedirects: Bool = true) {
        self.pinnedLeafFingerprint = Self.normalizeFingerprint(pinnedLeafFingerprint)
        self.expectedServerName = expectedServerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.followsRedirects = followsRedirects
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(followsRedirects ? request : nil)
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
            reject(completionHandler)
            return
        }

        guard let pinnedLeafFingerprint else {
            guard let expectedServerName,
                  !expectedServerName.isEmpty,
                  ServerTLSTrustPolicy.allowsUnpinnedLANShortcut(forHost: expectedServerName) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            // URLSession connected to a discovered LAN IP. Re-evaluate the
            // server's public certificate against the exact hostname carried
            // in signed pairing metadata instead of the IP protection space.
            let policy = SecPolicyCreateSSL(true, expectedServerName as CFString)
            guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else {
                reject(completionHandler)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leafCertificate = chain.first else {
            reject(completionHandler)
            return
        }

        let certData = SecCertificateCopyData(leafCertificate) as Data
        let fingerprint = certData.sha256Fingerprint

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
            reject(completionHandler)
        }
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
