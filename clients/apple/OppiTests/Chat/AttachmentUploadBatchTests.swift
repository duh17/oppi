import Foundation
import Testing
@testable import Oppi

@Suite("Attachment upload batch")
struct AttachmentUploadBatchTests {
    private static let mb: Int64 = 1_000_000

    private func batch() -> AttachmentUploadBatch {
        AttachmentUploadBatch([
            (id: "a", name: "one.mp4", totalBytes: 800 * Self.mb),
            (id: "b", name: "two.mp4", totalBytes: 200 * Self.mb),
        ])
    }

    private func progress(
        _ id: String,
        sent: Int64,
        total: Int64,
        _ phase: AttachmentUploadProgress.Phase = .uploading
    ) -> AttachmentUploadProgress {
        AttachmentUploadProgress(
            attachmentId: id,
            name: id == "a" ? "one.mp4" : "two.mp4",
            sentBytes: sent,
            totalBytes: total,
            phase: phase
        )
    }

    @Test func showsTheFileInFlightAndTheBatchProgress() {
        var uploads = batch()
        #expect(uploads.statusLine == "Preparing upload\u{2026}")
        #expect(uploads.badge(for: "b") == "Waiting")

        uploads.apply(progress("a", sent: 400 * Self.mb, total: 800 * Self.mb))

        #expect(uploads.item("a")?.state == .uploading)
        #expect(uploads.badge(for: "a") == "50%")
        #expect(uploads.fraction == 0.4)
        #expect(uploads.statusLine == "Uploading 1 of 2 \u{00B7} 400 MB of 1 GB (40%)")
    }

    @Test func aFinishedFileCountsInFullAndTheNextOneTakesTheLine() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 800 * Self.mb, total: 800 * Self.mb, .uploaded))
        uploads.apply(progress("b", sent: 100 * Self.mb, total: 200 * Self.mb))

        #expect(uploads.badge(for: "a") == "Uploaded")
        #expect(uploads.fraction == 0.9)
        #expect(uploads.current?.id == "b")
        #expect(uploads.statusLine == "Uploading 2 of 2 \u{00B7} 900 MB of 1 GB (90%)")
    }

    @Test func aByteCountLandingAfterTheOutcomeDoesNotUndoIt() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 800 * Self.mb, total: 800 * Self.mb, .uploaded))
        uploads.apply(progress("a", sent: 790 * Self.mb, total: 800 * Self.mb))

        #expect(uploads.item("a")?.state == .uploaded)
        #expect(uploads.item("a")?.fraction == 1)
    }

    @Test func aDroppedConnectionShowsTheRetryAndItsReason() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 0, total: 800 * Self.mb, .retrying(attempt: 2, maxAttempts: 5, reason: "the connection dropped")))

        #expect(uploads.badge(for: "a") == "Retrying")
        #expect(uploads.statusLine == "Retrying 1 of 2 \u{00B7} one.mp4 (try 2 of 5): the connection dropped")
        #expect(uploads.isActive)
    }

    @Test func pausedInTheBackgroundThenResumes() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 200 * Self.mb, total: 800 * Self.mb))

        uploads.isPaused = true
        #expect(uploads.statusLine == "Paused \u{2014} keep Oppi open to finish")
        #expect(uploads.badge(for: "a") == "Paused")
        #expect(uploads.badge(for: "b") == "Paused")

        uploads.isPaused = false
        uploads.apply(progress("a", sent: 300 * Self.mb, total: 800 * Self.mb))
        #expect(uploads.badge(for: "a") == "37%")
        #expect(uploads.statusLine?.hasPrefix("Uploading 1 of 2") == true)
    }

    @Test func cancelStopsTheFileInFlightAndReturnsTheRest() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 200 * Self.mb, total: 800 * Self.mb))
        uploads.isPaused = true

        uploads.cancel()

        #expect(uploads.item("a")?.state == .cancelled)
        #expect(uploads.item("b") == nil)
        #expect(uploads.badge(for: "a") == "Cancelled")
        #expect(!uploads.isActive)
        #expect(!uploads.isPaused)
        #expect(uploads.statusLine == nil)
    }

    @Test func aFailedFileKeepsItsReasonAndTheBatchLineGoes() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 800 * Self.mb, total: 800 * Self.mb, .uploaded))
        uploads.apply(progress("b", sent: 10 * Self.mb, total: 200 * Self.mb, .failed("not enough free disk space")))

        #expect(uploads.item("b")?.state == .failed("not enough free disk space"))
        #expect(uploads.badge(for: "b") == "Failed")
        #expect(uploads.item("a")?.state == .uploaded)
        #expect(uploads.statusLine == nil)
    }

    @Test func aSendThatStopsWithoutAFileReasonFailsTheFileInFlight() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 10 * Self.mb, total: 800 * Self.mb))

        uploads.fail("No server connection available")

        #expect(uploads.item("a")?.state == .failed("No server connection available"))
        #expect(uploads.item("b") == nil)
    }

    @Test func aRemovedAttachmentDropsOutOfTheBatch() {
        var uploads = batch()
        uploads.apply(progress("a", sent: 10 * Self.mb, total: 800 * Self.mb, .failed("the connection dropped")))

        uploads.keep(only: ["b"])

        #expect(uploads.item("a") == nil)
        #expect(uploads.order == ["b"])
        #expect(uploads.statusLine == "Preparing upload\u{2026}")
    }
}
