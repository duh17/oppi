import UIKit

@MainActor
enum TimelineSnapshotApplier {
    typealias DataSource = UICollectionViewDiffableDataSource<Int, String>

    static func applySnapshot(
        dataSource: DataSource?,
        nextIDs: [String],
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem],
        hiddenCount: Int,
        previousHiddenCount: Int,
        streamingAssistantID: String?,
        previousStreamingAssistantID: String?,
        themeID: ThemeID,
        previousThemeID: ThemeID?
    ) {
        ChatTimelinePerf.beginTimelineApplyCycle(itemCount: nextIDs.count, changedCount: 0)
        ChatTimelinePerf.beginSnapshotBuildPhase()

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextIDs)

        var changedIDs = changedItemIDs(
            nextItemByID: nextItemByID,
            previousItemByID: previousItemByID
        )

        if hiddenCount != previousHiddenCount,
           nextIDs.contains(ChatTimelineCollectionHost.loadMoreID) {
            changedIDs.append(ChatTimelineCollectionHost.loadMoreID)
        }

        if let streamingAssistantID {
            changedIDs.append(streamingAssistantID)
        }

        if let previousStreamingAssistantID,
           previousStreamingAssistantID != streamingAssistantID {
            changedIDs.append(previousStreamingAssistantID)
        }

        if previousThemeID != themeID {
            changedIDs.append(contentsOf: nextIDs)
        }

        let dedupedChangedIDs = Array(Set(changedIDs)).filter { nextIDs.contains($0) }
        if !dedupedChangedIDs.isEmpty {
            snapshot.reconfigureItems(dedupedChangedIDs)
        }
        ChatTimelinePerf.endSnapshotBuildPhase()
        ChatTimelinePerf.updateTimelineApplyCycle(
            itemCount: nextIDs.count,
            changedCount: dedupedChangedIDs.count
        )

        let applyToken = ChatTimelinePerf.beginCollectionApply(
            itemCount: nextIDs.count,
            changedCount: dedupedChangedIDs.count
        )
        dataSource?.apply(snapshot, animatingDifferences: false)
        ChatTimelinePerf.endCollectionApply(applyToken)
    }

    static func reconfigureItems(
        _ itemIDs: [String],
        dataSource: DataSource?,
        collectionView: UICollectionView,
        currentIDs: [String]
    ) {
        guard let dataSource else { return }

        var snapshot = dataSource.snapshot()
        let existing = itemIDs.filter { snapshot.indexOfItem($0) != nil }
        guard !existing.isEmpty else { return }

        snapshot.reconfigureItems(existing)

        let applyToken = ChatTimelinePerf.beginCollectionApply(
            itemCount: currentIDs.count,
            changedCount: existing.count
        )
        dataSource.apply(snapshot, animatingDifferences: false)
        ChatTimelinePerf.endCollectionApply(applyToken)

        let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: currentIDs.count)
        collectionView.layoutIfNeeded()
        ChatTimelinePerf.endLayoutPass(layoutToken)
    }

    private static func changedItemIDs(
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem]
    ) -> [String] {
        var changed: [String] = []
        changed.reserveCapacity(nextItemByID.count)

        for (id, nextItem) in nextItemByID {
            guard let previous = previousItemByID[id] else { continue }
            if previous != nextItem {
                changed.append(id)
            }
        }

        return changed
    }
}
