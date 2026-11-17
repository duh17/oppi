import UIKit

@MainActor
enum TimelineCellFactory {
    typealias CellDequeuer = (_ collectionView: UICollectionView, _ indexPath: IndexPath, _ itemID: String) -> UICollectionViewCell

    /// Which registration a row's cell comes from. UIKit reconfigures an
    /// item's existing cell (a prefetched one too) only through the
    /// registration that made it, so a row whose kind changes under its ID
    /// is reloaded, not reconfigured (`ChatTimelineController.cellKindChanged`).
    enum Kind: Equatable {
        case assistant, user, thinking, tool, audio, system, compaction, error
        case missingItem, loadMore, working, quietWork, childTail
    }

    struct Registrations {
        let assistant: CellDequeuer
        let user: CellDequeuer
        let thinking: CellDequeuer
        let tool: CellDequeuer
        let audio: CellDequeuer
        let system: CellDequeuer
        let compaction: CellDequeuer
        let error: CellDequeuer
        let missingItem: CellDequeuer
        let loadMore: CellDequeuer
        let working: CellDequeuer
        let quietWork: CellDequeuer
        let childTail: CellDequeuer

        func dequeuer(for kind: Kind) -> CellDequeuer {
            switch kind {
            case .assistant: assistant
            case .user: user
            case .thinking: thinking
            case .tool: tool
            case .audio: audio
            case .system: system
            case .compaction: compaction
            case .error: error
            case .missingItem: missingItem
            case .loadMore: loadMore
            case .working: working
            case .quietWork: quietWork
            case .childTail: childTail
            }
        }
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
