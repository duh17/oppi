import Foundation
import Testing
@testable import Oppi

@Suite("Stopping a busy turn with queued messages")
struct MessageQueueComposerRestoreTests {
    @Test("Given steering and follow-up messages, when stop restores the queue, then every queued message moves into the composer")
    func queuedMessagesArePrependedToComposerText() {
        let queue = MessageQueueState(
            version: 12,
            steering: [
                MessageQueueItem(id: "s1", message: "first steer", createdAt: 1),
                MessageQueueItem(id: "s2", message: "second steer", createdAt: 2),
            ],
            followUp: [
                MessageQueueItem(id: "f1", message: "first follow-up", createdAt: 3),
            ]
        )

        let plan = MessageQueueComposerRestore.plan(
            queue: queue,
            currentText: "current draft"
        )

        #expect(plan?.restoredCount == 3)
        #expect(plan?.text == "first steer\n\nsecond steer\n\nfirst follow-up\n\ncurrent draft")
        #expect(plan?.clearedQueue.version == 13)
        #expect(plan?.clearedQueue.steering.isEmpty == true)
        #expect(plan?.clearedQueue.followUp.isEmpty == true)
    }

    @Test("Given queued messages and an empty composer, when stop restores the queue, then the composer contains only queued text")
    func emptyComposerDoesNotAddTrailingSpacing() {
        let queue = MessageQueueState(
            version: 1,
            steering: [
                MessageQueueItem(id: "s1", message: "retry this", createdAt: 1),
            ],
            followUp: []
        )

        let plan = MessageQueueComposerRestore.plan(
            queue: queue,
            currentText: "  \n"
        )

        #expect(plan?.restoredCount == 1)
        #expect(plan?.text == "retry this")
        #expect(plan?.clearedQueue.version == 2)
    }

    @Test("Given an empty queue, when stop asks for restore text, then no composer update is produced")
    func emptyQueueProducesNoRestorePlan() {
        let plan = MessageQueueComposerRestore.plan(
            queue: .empty,
            currentText: "current draft"
        )

        #expect(plan == nil)
    }

    @Test("Given queued uploaded files, when stop restores the queue, then attachments return to the composer")
    func uploadedFileReferencesReturnAsPendingAttachments() {
        let attachment = ChatAttachmentRef(
            type: "attachment",
            id: "att-1",
            source: .upload,
            name: "notes.txt",
            mimeType: "text/plain",
            sizeBytes: 42,
            sha256: nil,
            kind: nil,
            workspacePath: ".pi/attachments/s1/notes.txt"
        )
        let queue = MessageQueueState(
            version: 2,
            steering: [
                MessageQueueItem(
                    id: "s1",
                    message: "read this",
                    attachments: [attachment],
                    createdAt: 1
                ),
            ],
            followUp: []
        )

        let plan = MessageQueueComposerRestore.plan(
            queue: queue,
            currentText: ""
        )

        #expect(plan?.restoredCount == 1)
        #expect(plan?.text == "read this")
        #expect(plan?.pendingAttachments.map(\.id) == ["att-1"])
        if let source = plan?.pendingAttachments.first?.source,
           case .uploaded(let restored) = source {
            #expect(restored == attachment)
        } else {
            Issue.record("Queued attachment was not restored as an uploaded pending attachment")
        }
        #expect(plan?.clearedQueue.version == 3)
    }

    @Test("Given queued and current attachments, when stop restores the queue, then all attachments stay on the bar")
    func queuedAttachmentsJoinCurrentComposerAttachments() {
        let queued = ChatAttachmentRef(
            type: "attachment",
            id: "queued",
            source: .upload,
            name: "queued.txt",
            mimeType: "text/plain",
            sizeBytes: 4,
            sha256: nil,
            kind: .text,
            workspacePath: nil
        )
        let current = PendingAttachment.localFile(name: "current.txt", data: Data("now".utf8), mimeType: "text/plain")
        let plan = MessageQueueComposerRestore.plan(
            queue: MessageQueueState(
                version: 1,
                steering: [MessageQueueItem(id: "s1", message: "queued", attachments: [queued], createdAt: 1)],
                followUp: []
            ),
            currentText: "draft",
            currentPendingAttachments: [current]
        )

        #expect(plan?.text == "queued\n\ndraft")
        #expect(plan?.pendingAttachments.map(\.id) == ["queued", current.id])
    }
}
