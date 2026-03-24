import UIKit

@MainActor
enum TimelineCellFactory {
    typealias CellDequeuer = (_ collectionView: UICollectionView, _ indexPath: IndexPath, _ itemID: String) -> UICollectionViewCell

    struct Registrations {
        let assistant: CellDequeuer
        let user: CellDequeuer
        let thinking: CellDequeuer
        let tool: CellDequeuer
        let audio: CellDequeuer
        let permission: CellDequeuer
        let system: CellDequeuer
        let compaction: CellDequeuer
        let error: CellDequeuer
        let missingItem: CellDequeuer
        let loadMore: CellDequeuer
        let working: CellDequeuer
    }

    static func dequeueCell(
        collectionView: UICollectionView,
        indexPath: IndexPath,
        itemID: String,
        itemByID: [String: ChatItem],
        registrations: Registrations,
        isCompactionMessage: (String) -> Bool
    ) -> UICollectionViewCell {
        if itemID == ChatTimelineCollectionHost.loadMoreID {
            return registrations.loadMore(collectionView, indexPath, itemID)
        }

        if itemID == ChatTimelineCollectionHost.workingIndicatorID {
            return registrations.working(collectionView, indexPath, itemID)
        }

        guard let item = itemByID[itemID] else {
            return registrations.missingItem(collectionView, indexPath, itemID)
        }

        switch item {
        case .assistantMessage:
            return registrations.assistant(collectionView, indexPath, itemID)
        case .userMessage:
            return registrations.user(collectionView, indexPath, itemID)
        case .thinking:
            return registrations.thinking(collectionView, indexPath, itemID)
        case .toolCall:
            return registrations.tool(collectionView, indexPath, itemID)
        case .audioClip:
            return registrations.audio(collectionView, indexPath, itemID)
        case .permission, .permissionResolved:
            return registrations.permission(collectionView, indexPath, itemID)
        case .systemEvent(_, let message):
            let dequeuer = isCompactionMessage(message)
                ? registrations.compaction
                : registrations.system
            return dequeuer(collectionView, indexPath, itemID)
        case .error:
            return registrations.error(collectionView, indexPath, itemID)
        }
    }
}
