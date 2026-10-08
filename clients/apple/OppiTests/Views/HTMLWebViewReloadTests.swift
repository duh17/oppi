import Testing
import UIKit
import WebKit
@testable import Oppi

@MainActor
@Suite("HTML preview browser routing")
struct HTMLPreviewBrowserRoutingTests {
    @Test(arguments: ["http://example.com/html", "https://example.com/html"])
    func activatedWebLinkPostsBrowserNotificationAndCancelsEmbeddedNavigation(urlString: String) throws {
        let url = testUnwrap(URL(string: urlString))
        let view = HTMLRenderView(htmlString: "<p>Preview</p>")
        var received: [URL] = []
        let observer = NotificationCenter.default.addObserver(forName: .webLinkTapped, object: nil, queue: .main) {
            if $0.object as? URL == url { received.append(url) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var policy: WKNavigationActionPolicy?
        view.webView(view.webViewForTesting, decidePolicyFor: PreviewNavigationAction(url: url, type: .linkActivated)) {
            policy = $0
        }
        #expect(policy == .cancel)
        #expect(received == [url])

        // New-window links use the same browser route without creating a web view.
        let popup = view.webView(
            view.webViewForTesting, createWebViewWith: WKWebViewConfiguration(),
            for: PreviewNavigationAction(url: url, type: .linkActivated), windowFeatures: WKWindowFeatures()
        )
        #expect(popup == nil)
        #expect(received == [url, url])
    }

    @Test(arguments: [
        "https://example.com/automatic", "https://example.com/files/raw",
        "https://example.com/files/current", "https://example.com/files/current/sidecars",
        "mailto:preview@example.com",
    ])
    func automaticOrProtectedNavigationDoesNotOpenBrowser(urlString: String) throws {
        let url = testUnwrap(URL(string: urlString))
        let view = HTMLRenderView(htmlString: "<p>Preview</p>")
        var posted = false
        let observer = NotificationCenter.default.addObserver(forName: .webLinkTapped, object: nil, queue: .main) {
            if $0.object as? URL == url { posted = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var policy: WKNavigationActionPolicy?
        let type: WKNavigationType = url.path == "/automatic" ? .other : .linkActivated
        view.webView(view.webViewForTesting, decidePolicyFor: PreviewNavigationAction(url: url, type: type)) { policy = $0 }
        #expect(policy == .cancel)
        #expect(!posted)
    }
}

@MainActor
private final class PreviewNavigationAction: WKNavigationAction {
    private let requestedURL: URL
    private let type: WKNavigationType

    init(url: URL, type: WKNavigationType) {
        requestedURL = url
        self.type = type
        super.init()
    }

    override var request: URLRequest { URLRequest(url: requestedURL) }
    override var navigationType: WKNavigationType { type }
}

@Suite("HTMLContentTracker")
struct HTMLContentTrackerTests {

    // MARK: - Deferred loading (not ready)

    @Test func defersLoadBeforeReady() {
        let tracker = HTMLContentTracker()
        // Not ready (no window + no frame) — content is queued, not returned
        #expect(tracker.setContent("<h1>Hello</h1>") == nil)
    }

    @Test func loadsWhenMarkedReady() {
        let tracker = HTMLContentTracker()
        _ = tracker.setContent("<h1>Hello</h1>")
        // View gets window + non-zero frame → flush pending
        #expect(tracker.markReady() == "<h1>Hello</h1>")
    }

    @Test func nothingPendingOnReady() {
        let tracker = HTMLContentTracker()
        #expect(tracker.markReady() == nil)
    }

    @Test func lastContentWinsBeforeReady() {
        let tracker = HTMLContentTracker()
        _ = tracker.setContent("<h1>First</h1>")
        _ = tracker.setContent("<h1>Second</h1>")
        #expect(tracker.markReady() == "<h1>Second</h1>")
    }

    @Test func markReadyIdempotent() {
        let tracker = HTMLContentTracker()
        _ = tracker.setContent("<h1>Hello</h1>")
        _ = tracker.markReady()
        // Second call — nothing pending
        #expect(tracker.markReady() == nil)
    }

    // MARK: - Immediate loading (ready)

    @Test func loadsImmediatelyWhenReady() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        #expect(tracker.setContent("<h1>Hello</h1>") == "<h1>Hello</h1>")
    }

    @Test func sameContentDoesNotReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        _ = tracker.setContent("<h1>Hello</h1>")
        #expect(tracker.setContent("<h1>Hello</h1>") == nil)
    }

    @Test func resetLoadedContentAllowsSameContentToReloadWhileReady() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        _ = tracker.setContent("<h1>Hello</h1>")

        tracker.resetLoadedContent()

        #expect(tracker.setContent("<h1>Hello</h1>") == "<h1>Hello</h1>")
    }

    @Test func differentContentTriggersReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        _ = tracker.setContent("<h1>Hello</h1>")
        #expect(tracker.setContent("<h1>World</h1>") == "<h1>World</h1>")
    }

    // MARK: - Process termination recovery

    @Test func processTerminationForcesReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        _ = tracker.setContent("<h1>Hello</h1>")

        tracker.markProcessTerminated()
        #expect(tracker.setContent("<h1>Hello</h1>") == "<h1>Hello</h1>")
    }

    @Test func processTerminationClearsAfterReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        _ = tracker.setContent("<h1>Hello</h1>")

        tracker.markProcessTerminated()
        _ = tracker.setContent("<h1>Hello</h1>")
        #expect(tracker.setContent("<h1>Hello</h1>") == nil)
    }

    @Test func processTerminationWhileNotReady() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        _ = tracker.setContent("<h1>Hello</h1>")

        tracker.markNotReady()
        tracker.markProcessTerminated()
        // Reattach — should reload even though content hash matches
        #expect(tracker.markReady() == "<h1>Hello</h1>")
    }

    // MARK: - Detach / reattach

    @Test func notReadyThenReadyWithNewContent() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        _ = tracker.setContent("<h1>Hello</h1>")

        tracker.markNotReady()
        #expect(tracker.setContent("<h1>New</h1>") == nil)
        #expect(tracker.markReady() == "<h1>New</h1>")
    }

    // MARK: - Empty content

    @Test func emptyContentStillTracked() {
        let tracker = HTMLContentTracker()
        _ = tracker.markReady()
        #expect(tracker.setContent("")?.isEmpty == true)
        #expect(tracker.setContent("") == nil)
        #expect(tracker.setContent("<p>Content</p>") == "<p>Content</p>")
    }
}
