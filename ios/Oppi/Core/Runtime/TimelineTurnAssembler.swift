import Foundation

@MainActor
enum TimelineTurnAssembler {
    static func isWhitespaceOnly(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func makeAssistantItem(id: String, text: String, timestamp: Date) -> ChatItem {
        .assistantMessage(id: id, text: text, timestamp: timestamp)
    }

    static func makeThinkingItem(id: String, preview: String, hasMore: Bool, isDone: Bool = false) -> ChatItem {
        .thinking(id: id, preview: preview, hasMore: hasMore, isDone: isDone)
    }

    static func shouldSuppressDuplicateMessageEnd(
        content: String,
        turnInProgress: Bool,
        currentAssistantID: String?,
        lastItem: ChatItem?
    ) -> Bool {
        guard !turnInProgress, currentAssistantID == nil else { return false }
        guard let lastItem,
              case .assistantMessage(_, let existingText, _) = lastItem else {
            return false
        }

        return existingText.trimmingCharacters(in: .whitespacesAndNewlines)
            == content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
