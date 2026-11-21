import UIKit

@MainActor
enum TimelineCellFactory {
    /// Which row the items of a snapshot ID draw as. The kind only selects the
    /// content configuration (`ChatTimelineController.configureCell`): every
    /// kind shares one cell registration, so a row that changes kind under its
    /// ID redraws without UIKit dequeuing it through another registration.
    enum Kind: Equatable {
        case assistant, user, thinking, tool, audio, system, compaction, error
        case missingItem, loadMore, working, quietWork, childTail
    }

    static func kind(
        itemID: String,
        itemByID: [String: ChatItem],
        isCompactionMessage: (String) -> Bool
    ) -> Kind {
        if itemID == ChatTimelineController.loadMoreID {
            return .loadMore
        }

        if itemID == ChatTimelineController.workingIndicatorID {
            return .working
        }

        if itemID.hasPrefix("quiet-work-line:") {
            return .quietWork
        }

        if itemID.hasPrefix(TimelineDisplayRow.childTailIDPrefix) {
            return .childTail
        }

        guard let item = itemByID[itemID] else {
            return .missingItem
        }

        switch item {
        case .assistantMessage:
            return .assistant
        case .userMessage, .agentMessage:
            return .user
        case .thinking:
            return .thinking
        case .toolCall:
            return .tool
        case .audioClip:
            return .audio
        case .systemEvent(_, let message):
            return isCompactionMessage(message) ? .compaction : .system
        case .cacheMiss, .notice:
            return .system
        case .customEvent(_, _, let presentation):
            return presentation.terminalOutput != nil ? .tool : .system
        case .error:
            return .error
        }
    }
}
