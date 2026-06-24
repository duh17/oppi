import Testing
@testable import Oppi

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
        #expect(tracker.setContent("") == "")
        #expect(tracker.setContent("") == nil)
        #expect(tracker.setContent("<p>Content</p>") == "<p>Content</p>")
    }
}
