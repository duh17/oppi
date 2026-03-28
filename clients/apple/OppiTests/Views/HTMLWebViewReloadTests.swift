import Testing
@testable import Oppi

@Suite("HTMLWebView content reload")
@MainActor
struct HTMLWebViewReloadTests {

    // MARK: - Content change detection

    @Test func firstContentAlwaysNeedsLoad() {
        let tracker = HTMLContentTracker()
        #expect(tracker.needsReload(for: "<h1>Hello</h1>") == true)
    }

    @Test func sameContentDoesNotReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.needsReload(for: "<h1>Hello</h1>")
        tracker.markLoaded()
        #expect(tracker.needsReload(for: "<h1>Hello</h1>") == false)
    }

    @Test func differentContentTriggersReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.needsReload(for: "<h1>Hello</h1>")
        tracker.markLoaded()
        #expect(tracker.needsReload(for: "<h1>World</h1>") == true)
    }

    // MARK: - Process termination recovery

    @Test func processTerminationForcesReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.needsReload(for: "<h1>Hello</h1>")
        tracker.markLoaded()

        // Same content, but process died — must reload
        tracker.markProcessTerminated()
        #expect(tracker.needsReload(for: "<h1>Hello</h1>") == true)
    }

    @Test func processTerminationResetsAfterReload() {
        let tracker = HTMLContentTracker()
        _ = tracker.needsReload(for: "<h1>Hello</h1>")
        tracker.markLoaded()

        tracker.markProcessTerminated()
        _ = tracker.needsReload(for: "<h1>Hello</h1>")
        tracker.markLoaded()

        // After successful reload, same content should not trigger again
        #expect(tracker.needsReload(for: "<h1>Hello</h1>") == false)
    }

    // MARK: - Empty content

    @Test func emptyContentStillTracked() {
        let tracker = HTMLContentTracker()
        #expect(tracker.needsReload(for: "") == true)
        tracker.markLoaded()
        #expect(tracker.needsReload(for: "") == false)
        #expect(tracker.needsReload(for: "<p>Now has content</p>") == true)
    }
}
