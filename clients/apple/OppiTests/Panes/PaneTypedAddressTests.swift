import Foundation
import Testing
import UIKit
import WebKit
@testable import Oppi

/// An address typed with no scheme gets https, then once http, as Safari's
/// field does; nothing else ever changes scheme.
@Suite("PaneTypedAddress")
struct PaneTypedAddressTests {
    private func failure(_ code: Int, of url: String) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: url) as Any])
    }

    @Test func aBareHostLoadsOverHTTPSAndMovesToHTTPOnASecureConnectionFailure() throws {
        for (text, https, http) in [
            ("mac-mini", "https://mac-mini", "http://mac-mini"),
            ("mac-mini:8080", "https://mac-mini:8080", "http://mac-mini:8080"),
            ("myhost.local/status?x=1", "https://myhost.local/status?x=1", "http://myhost.local/status?x=1"),
        ] {
            for code in [
                NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
            ] {
                var typed = try #require(PaneTypedAddress(text))
                #expect(typed.url == URL(string: https), "\(text)")
                #expect(typed.retry(after: failure(code, of: https)) == URL(string: http), "\(text) \(code)")
                #expect(typed.url == URL(string: http))
            }
        }
    }

    @Test func httpIsTriedOnceThenTheFailureStands() throws {
        var typed = try #require(PaneTypedAddress("mac-mini"))
        let retry = typed.retry(after: failure(NSURLErrorSecureConnectionFailed, of: "https://mac-mini/"))
        #expect(retry == URL(string: "http://mac-mini"))
        #expect(typed.triedInsecure)
        for code in [NSURLErrorCannotConnectToHost, NSURLErrorSecureConnectionFailed, NSURLErrorTimedOut] {
            #expect(typed.retry(after: failure(code, of: "http://mac-mini/")) == nil, "no loop")
            #expect(typed.retry(after: failure(code, of: "https://mac-mini/")) == nil, "no loop")
        }
        #expect(typed.url == URL(string: "http://mac-mini"))
    }

    @Test func aTypedSchemeNeverChanges() throws {
        for text in ["https://mac-mini", "HTTPS://mac-mini:8443/x", "http://mac-mini"] {
            var typed = try #require(PaneTypedAddress(text))
            let url = typed.url
            #expect(typed.retry(after: failure(NSURLErrorSecureConnectionFailed, of: url.absoluteString)) == nil, "\(text)")
            #expect(typed.url == url)
        }
    }

    @Test func onlyConnectionFailuresMoveToHTTP() throws {
        for code in [
            NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorBadServerResponse, NSURLErrorCancelled, NSURLErrorHTTPTooManyRedirects,
        ] {
            var typed = try #require(PaneTypedAddress("mac-mini"))
            #expect(typed.retry(after: failure(code, of: "https://mac-mini/")) == nil, "\(code)")
        }
        var typed = try #require(PaneTypedAddress("mac-mini"))
        let other = NSError(domain: "WebKitErrorDomain", code: NSURLErrorSecureConnectionFailed, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://mac-mini/") as Any])
        #expect(typed.retry(after: other) == nil, "another domain's code is not a URL error")
    }

    /// A redirect off the typed address, or a failure that does not say where
    /// it happened, is not the typed address failing.
    @Test func aRedirectsFailureIsNotRetried() throws {
        var typed = try #require(PaneTypedAddress("mac-mini"))
        #expect(typed.retry(after: failure(NSURLErrorSecureConnectionFailed, of: "https://login.example.com/")) == nil)
        #expect(typed.retry(after: failure(NSURLErrorSecureConnectionFailed, of: "https://mac-mini:8443/")) == nil)
        #expect(typed.retry(after: failure(NSURLErrorSecureConnectionFailed, of: "http://mac-mini/")) == nil)
        #expect(typed.retry(after: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)) == nil)
        #expect(typed.retry(after: failure(NSURLErrorSecureConnectionFailed, of: "https://MAC-MINI/x")) != nil, "the same origin, however spelled")
    }

    @Test func retryStartsOverFromHTTPS() throws {
        var typed = try #require(PaneTypedAddress("mac-mini"))
        _ = typed.retry(after: failure(NSURLErrorTimedOut, of: "https://mac-mini/"))
        #expect(typed.restart() == URL(string: "https://mac-mini"))
        #expect(!typed.triedInsecure)
        #expect(typed.retry(after: failure(NSURLErrorTimedOut, of: "https://mac-mini/")) == URL(string: "http://mac-mini"), "the fallback is back")
    }

    @Test func textThatIsNotAnAddressIsRefused() {
        for text in ["", "   ", "ftp://mac-mini", "javascript:alert(1)", "https://", "file:///etc/hosts", "oppi://browser"] {
            #expect(PaneTypedAddress(text) == nil, "\(text)")
        }
    }
}

/// The pane's side: what the navigation delegate does with the failure, so
/// the address field, the leaf's entry and the error follow the decision.
@MainActor
@Suite("Browser pane scheme fallback", .serialized)
struct BrowserPaneSchemeFallbackTests {
    private struct Fixture {
        let pane: BrowserPaneViewController
        let webView: WKWebView
        let navigated: Box
        final class Box {
            var urls: [URL] = []
            /// The schemes the leaf's entry went through, in order. The web
            /// view reports the same page again as `host/`, so repeats collapse.
            var schemes: [String] {
                urls.compactMap(\.scheme).reduce(into: []) { $1 == $0.last ? () : $0.append($1) }
            }
        }
    }

    /// `url` is `string`, whether or not the web view added the root `/`.
    private func isPage(_ url: URL?, _ string: String) -> Bool {
        guard let url else { return false }
        return url.absoluteString == string || url.absoluteString == string + "/"
    }

    private func typedPane(_ text: String) throws -> Fixture {
        let pane = BrowserPaneViewController(url: nil, paused: false, root: nil)
        let navigated = Fixture.Box()
        pane.onNavigate = { navigated.urls.append($0) }
        pane.loadViewIfNeeded()
        pane.addressField.textField.text = text
        _ = pane.addressField.textFieldShouldReturn(pane.addressField.textField)
        return Fixture(pane: pane, webView: try #require(pane.webView), navigated: navigated)
    }

    private func fail(_ fixture: Fixture, _ code: Int, of url: String, provisional: Bool = true) {
        let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: url) as Any])
        if provisional {
            fixture.pane.webView(fixture.webView, didFailProvisionalNavigation: nil, withError: error)
        } else {
            fixture.pane.webView(fixture.webView, didFail: nil, withError: error)
        }
    }

    private func state(_ pane: BrowserPaneViewController) -> String? {
        pane.updateProperties()
        return pane.view.subviews.first { $0.accessibilityIdentifier == "browser.state" }?.accessibilityValue
    }

    @Test func aTypedBareHostMovesToHTTPAndTheFieldSaysSo() throws {
        let fixture = try typedPane("pane-browser.invalid:8080")
        #expect(isPage(fixture.pane.url, "https://pane-browser.invalid:8080"))
        fail(fixture, NSURLErrorSecureConnectionFailed, of: "https://pane-browser.invalid:8080/")
        #expect(isPage(fixture.pane.url, "http://pane-browser.invalid:8080"))
        #expect(fixture.navigated.schemes == ["https", "http"])
        #expect(fixture.pane.addressField.textField.leftViewMode == .unlessEditing, "the field marks the page not secure")
        #expect(fixture.pane.addressField.textField.text == "pane-browser.invalid:8080")
        #expect(state(fixture.pane) != "failed", "the retry is in flight, not an error")
    }

    @Test func aFailedHTTPRetryShowsTheErrorAndDoesNotLoop() throws {
        let fixture = try typedPane("pane-browser.invalid")
        fail(fixture, NSURLErrorServerCertificateUntrusted, of: "https://pane-browser.invalid/")
        fail(fixture, NSURLErrorCannotConnectToHost, of: "http://pane-browser.invalid/")
        #expect(isPage(fixture.pane.url, "http://pane-browser.invalid"))
        #expect(fixture.navigated.schemes == ["https", "http"], "https, then http once")
        #expect(state(fixture.pane) == "failed")
        fail(fixture, NSURLErrorTimedOut, of: "http://pane-browser.invalid/")
        #expect(fixture.navigated.schemes == ["https", "http"])
    }

    @Test func anExplicitHTTPSOrALinkOrAPageAlreadyLoadedNeverDowngrades() throws {
        let explicit = try typedPane("https://pane-browser.invalid")
        fail(explicit, NSURLErrorSecureConnectionFailed, of: "https://pane-browser.invalid/")
        #expect(isPage(explicit.pane.url, "https://pane-browser.invalid"))
        #expect(state(explicit.pane) == "failed")

        // A link (or an `oppi://browser?url=` link) opens through `open`, even over a typed address still loading.
        let linked = try typedPane("pane-browser.invalid")
        linked.pane.open(try #require(URL(string: "https://pane-browser.invalid/doc")))
        fail(linked, NSURLErrorSecureConnectionFailed, of: "https://pane-browser.invalid/doc")
        #expect(linked.pane.url == URL(string: "https://pane-browser.invalid/doc"))

        // A typed page that began to arrive over https stays there.
        let loaded = try typedPane("pane-browser.invalid")
        loaded.pane.webView(loaded.webView, didCommit: nil)
        fail(loaded, NSURLErrorSecureConnectionFailed, of: "https://pane-browser.invalid/")
        fail(loaded, NSURLErrorSecureConnectionFailed, of: "https://pane-browser.invalid/", provisional: false)
        #expect(isPage(loaded.pane.url, "https://pane-browser.invalid"))
        #expect(loaded.navigated.schemes == ["https"])

        // A redirect that fails is not the typed address.
        let redirected = try typedPane("pane-browser.invalid")
        fail(redirected, NSURLErrorSecureConnectionFailed, of: "https://login.pane-browser.invalid/")
        #expect(isPage(redirected.pane.url, "https://pane-browser.invalid"))
    }

    /// Both failed: the copy says what was tried, and no longer offers http://.
    @Test func theErrorCopyFitsBothAttemptsFailing() {
        let single = BrowserPaneViewController.certificateMessage(host: "mac-mini", triedHTTP: false)
        #expect(single.contains("http:// if it doesn\u{2019}t use HTTPS"))
        let both = BrowserPaneViewController.certificateMessage(host: "mac-mini", triedHTTP: true)
        #expect(both.contains("also tried http://"))
        #expect(!both.contains("if it doesn\u{2019}t use HTTPS"))
        #expect(both.contains("mac-mini.your-tailnet.ts.net"))
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."])
        #expect(BrowserPaneViewController.bothFailedMessage(refused) == "Could not connect to the server. Oppi tried https:// and then http://.")
    }
}
