import Testing
import UIKit
@testable import Oppi

@Suite("Composer attachment strip uploads")
@MainActor
struct ComposerAttachmentStripUploadTests {
    private func video(_ id: String) -> PendingAttachment {
        PendingAttachment.localFile(
            name: "\(id).mp4",
            fileURL: URL(fileURLWithPath: "/tmp/\(id).mp4"),
            mimeType: "video/mp4",
            sizeBytes: 1_000,
            id: id
        )
    }

    private func button(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier, !button.isHidden {
            return button
        }
        for subview in view.subviews {
            if let found = button(identifier, in: subview) { return found }
        }
        return nil
    }

    /// Progress redraws the strip every percent; a finger on Cancel must keep its button.
    @Test func progressAloneKeepsTheSameCancelButton() {
        var uploads = AttachmentUploadBatch([(id: "a", name: "a.mp4", totalBytes: 1_000)])
        uploads.apply(AttachmentUploadProgress(attachmentId: "a", name: "a.mp4", sentBytes: 100, totalBytes: 1_000, phase: .uploading))
        var cancelled = 0
        let strip = ComposerAttachmentStripView()
        let actions = { (batch: AttachmentUploadBatch) in
            ComposerAttachmentUploads(batch: batch, onCancel: { cancelled += 1 }, onRetry: {})
        }
        strip.apply(attachments: [video("a")], colors: .placeholder, allowsMutation: false, uploads: actions(uploads))
        let before = button("chat.attachment.cancel.a", in: strip)

        uploads.apply(AttachmentUploadProgress(attachmentId: "a", name: "a.mp4", sentBytes: 500, totalBytes: 1_000, phase: .uploading))
        strip.apply(attachments: [video("a")], colors: .placeholder, allowsMutation: false, uploads: actions(uploads))

        let after = button("chat.attachment.cancel.a", in: strip)
        #expect(before != nil)
        #expect(after === before)
        after?.sendActions(for: .touchUpInside)
        #expect(cancelled == 1)
    }

    @Test func aFileInFlightOffersCancelEvenMidSendAndAFailedOneRetryAndRemove() {
        var uploads = AttachmentUploadBatch([
            (id: "a", name: "a.mp4", totalBytes: 1_000),
            (id: "b", name: "b.mp4", totalBytes: 1_000),
        ])
        uploads.apply(AttachmentUploadProgress(attachmentId: "a", name: "a.mp4", sentBytes: 400, totalBytes: 1_000, phase: .uploading))
        var cancelled = 0
        var retried = 0
        var removed: [String] = []
        let strip = ComposerAttachmentStripView()
        strip.onRemove = { removed.append($0) }
        let actions = { (batch: AttachmentUploadBatch) in
            ComposerAttachmentUploads(batch: batch, onCancel: { cancelled += 1 }, onRetry: { retried += 1 })
        }

        // Mid-send: the draft cannot change, but the upload can be stopped.
        strip.apply(attachments: [video("a"), video("b")], colors: .placeholder, allowsMutation: false, uploads: actions(uploads))
        button("chat.attachment.cancel.a", in: strip)?.sendActions(for: .touchUpInside)
        #expect(cancelled == 1)
        #expect(button("chat.attachment.remove.a", in: strip) == nil)
        #expect(button("chat.attachment.retry.a", in: strip) == nil)

        // The send stopped on a failure: Retry and Remove on that file.
        uploads.apply(AttachmentUploadProgress(attachmentId: "a", name: "a.mp4", sentBytes: 400, totalBytes: 1_000, phase: .failed("the connection dropped")))
        uploads.fail("the connection dropped")
        strip.apply(attachments: [video("a"), video("b")], colors: .placeholder, allowsMutation: true, uploads: actions(uploads))
        button("chat.attachment.retry.a", in: strip)?.sendActions(for: .touchUpInside)
        button("chat.attachment.remove.a", in: strip)?.sendActions(for: .touchUpInside)
        #expect(retried == 1)
        #expect(removed == ["a"])
        #expect(button("chat.attachment.cancel.a", in: strip) == nil)
    }
}
