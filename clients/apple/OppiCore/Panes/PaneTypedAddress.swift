import Foundation

/// An address typed into a browser pane's field, read as Safari's field reads
/// it: http or https with a host. Text with no scheme (`mac-mini`,
/// `mac-mini:8080`, `example.com/docs`) loads over https; if that connection
/// cannot be made securely, or at all, it is tried once more over http, the
/// same host, port and path. Anything else never changes scheme: a typed
/// `https://`, a link, a redirect, and a page that has begun to load.
///
/// The pane owns one per typed load and drops it when the page commits or
/// anything else loads. The pane's navigation policy (a paired server's own
/// origin) sees the http load as it sees every load, and no certificate
/// check is skipped.
struct PaneTypedAddress: Equatable {
    /// The address being loaded: the typed one, then the http one if it was
    /// tried.
    private(set) var url: URL
    /// What the first load opens.
    private let first: URL
    /// The http address to try once if the first load cannot be made
    /// securely; nil for a typed scheme.
    private let http: URL?
    /// Why the https load failed, once http was tried after it.
    private(set) var secureError: NSError?

    /// Connection failures that http can answer: no TLS there, a certificate
    /// for another name, expired or untrusted, or nothing answering on the
    /// secure port.
    static let secureConnectionErrors: Set<Int> = [
        NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]

    /// Whether `error` is one a secure connection reports: the pane words
    /// these as a certificate problem.
    static func isSecureConnectionError(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && secureConnectionErrors.contains(error.code)
    }

    /// Nil when `text` is not an address.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let typedScheme = trimmed.contains("://")
        guard let url = URL(string: typedScheme ? trimmed : "https://" + trimmed), PaneWebAddress.isHTTP(url),
              url.host(percentEncoded: false)?.isEmpty == false else { return nil }
        self.url = url
        first = url
        if typedScheme {
            http = nil
        } else {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "http"
            http = components?.url
        }
    }

    /// The http address to load now that the https load of `url` failed with
    /// `error` before any of the page arrived, or nil: the address was typed
    /// with its scheme, http was already tried, the failure is not one http can
    /// answer, or it is a redirect's failure (the failing address is not the
    /// typed one, or not known). Asking once consumes the retry.
    mutating func retry(after error: NSError) -> URL? {
        guard let http, url == first else { return nil }
        guard error.domain == NSURLErrorDomain,
              Self.isSecureConnectionError(error) || error.code == NSURLErrorCannotConnectToHost
              || error.code == NSURLErrorTimedOut,
              let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
              Self.sameOrigin(failing, first)
        else { return nil }
        secureError = error
        url = http
        return http
    }

    /// Back to the first load, for a person who taps Retry after both failed.
    mutating func restart() -> URL {
        url = first
        secureError = nil
        return first
    }

    /// Whether http was tried after https failed.
    var triedInsecure: Bool { secureError != nil }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ url: URL) -> [String?] {
            [url.scheme?.lowercased(), url.host(percentEncoded: false)?.lowercased(), (url.port ?? 443).description]
        }
        return origin(a) == origin(b)
    }
}
