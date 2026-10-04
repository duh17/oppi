import Foundation

struct MessageQueueComposerContent: Sendable {
    let text: String
    let attachments: [ChatAttachmentRef]
    let restoredCount: Int
}

enum MessageQueueComposerRestore {
    /// A failed withdrawal must leave Stop retryable, not discard the inbox.
    /// Restore into the composer before abort, just like Pi's own Stop path.
    @MainActor
    static func stopAfterRestoring(
        restore: @MainActor () async throws -> Void,
        abort: @MainActor () async -> Void,
        onError: @MainActor (Error) -> Void
    ) async {
        do {
            try await restore()
        } catch {
            onError(error)
            return
        }
        await abort()
    }

    /// Input must be the items actually withdrawn, not a pre-command snapshot.
    static func content(queue: MessageQueueState, currentText: String) -> MessageQueueComposerContent? {
        let items = queue.steering + queue.followUp
        guard !items.isEmpty else { return nil }
        let queuedText = items.map(\.message).joined(separator: "\n\n")
        let text = [queuedText, currentText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        var seen = Set<String>()
        let attachments = items.flatMap { $0.attachments ?? [] }.filter { seen.insert($0.id).inserted }
        return MessageQueueComposerContent(text: text, attachments: attachments, restoredCount: items.count)
    }
}
