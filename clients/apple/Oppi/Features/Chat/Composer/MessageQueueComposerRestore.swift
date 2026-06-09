import Foundation

struct MessageQueueComposerRestorePlan: Equatable, Sendable {
    let text: String
    let restoredCount: Int
    let clearedQueue: MessageQueueState
}

enum MessageQueueComposerRestore {
    static func plan(
        queue: MessageQueueState,
        currentText: String
    ) -> MessageQueueComposerRestorePlan? {
        let queuedItems = queue.steering + queue.followUp
        guard !queuedItems.isEmpty else { return nil }

        let queuedText = queuedItems
            .map(restorableText)
            .joined(separator: "\n\n")
        let combinedText = [queuedText, currentText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return MessageQueueComposerRestorePlan(
            text: combinedText,
            restoredCount: queuedItems.count,
            clearedQueue: MessageQueueState(
                version: queue.version + 1,
                steering: [],
                followUp: []
            )
        )
    }

    private static func restorableText(for item: MessageQueueItem) -> String {
        guard let attachments = item.attachments, !attachments.isEmpty else {
            return item.message
        }
        return UserMessageAttachmentPresentation.appendAttachedFilesBlock(
            to: item.message,
            attachments: attachments
        )
    }
}
