import Foundation

struct MessageQueueComposerRestorePlan: Sendable {
    let text: String
    let pendingAttachments: [PendingAttachment]
    let restoredCount: Int
}

extension MessageQueueComposerRestore {
    static func plan(
        queue: MessageQueueState,
        currentText: String,
        currentPendingAttachments: [PendingAttachment] = []
    ) -> MessageQueueComposerRestorePlan? {
        guard let content = content(queue: queue, currentText: currentText) else { return nil }
        let pendingAttachments = content.attachments.map { PendingAttachment.uploaded($0) }
        let seenAttachmentIDs = Set(content.attachments.map(\.id))
        let allAttachments = pendingAttachments + currentPendingAttachments.filter {
            !seenAttachmentIDs.contains($0.id)
        }
        return MessageQueueComposerRestorePlan(
            text: content.text,
            pendingAttachments: allAttachments,
            restoredCount: content.restoredCount
        )
    }

}
