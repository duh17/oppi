import Foundation

struct MessageQueueComposerRestorePlan: Sendable {
    let text: String
    let pendingAttachments: [PendingAttachment]
    let restoredCount: Int
    let clearedQueue: MessageQueueState
}

enum MessageQueueComposerRestore {
    static func plan(
        queue: MessageQueueState,
        currentText: String,
        currentPendingAttachments: [PendingAttachment] = []
    ) -> MessageQueueComposerRestorePlan? {
        let queuedItems = queue.steering + queue.followUp
        guard !queuedItems.isEmpty else { return nil }

        let queuedText = queuedItems
            .map(restorableText)
            .joined(separator: "\n\n")
        var seenAttachmentIDs = Set<String>()
        let pendingAttachments = queuedItems
            .flatMap { $0.attachments ?? [] }
            .compactMap { attachment -> PendingAttachment? in
                guard seenAttachmentIDs.insert(attachment.id).inserted else { return nil }
                return .uploaded(attachment)
            }
        let allAttachments = pendingAttachments + currentPendingAttachments.filter {
            !seenAttachmentIDs.contains($0.id)
        }
        let combinedText = [queuedText, currentText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return MessageQueueComposerRestorePlan(
            text: combinedText,
            pendingAttachments: allAttachments,
            restoredCount: queuedItems.count,
            clearedQueue: MessageQueueState(
                version: queue.version + 1,
                steering: [],
                followUp: []
            )
        )
    }

    private static func restorableText(for item: MessageQueueItem) -> String {
        item.message
    }
}
