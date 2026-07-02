import Foundation

/// URLSession delegate for Mac-owned local server connections.
///
/// The Mac app owns or explicitly attaches to the same-machine server process,
/// which currently serves HTTPS with a self-signed certificate. This delegate is
/// intentionally local-only; remote server connections must use pinned trust or
/// the shared trust path instead of this adapter.
final class LocalServerTrustDelegate: NSObject, URLSessionDelegate, Sendable {

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
            return (.useCredential, URLCredential(trust: serverTrust))
        }

        return (.performDefaultHandling, nil)
    }
}
