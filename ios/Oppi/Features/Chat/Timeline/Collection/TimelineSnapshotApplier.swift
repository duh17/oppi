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

        let nextIDSet = Set(nextIDs)
        let dedupedChangedIDs = reconfigureItemIDs(
            nextIDs: nextIDs,
            nextIDSet: nextIDSet,
            nextItemByID: nextItemByID,
            previousItemByID: previousItemByID,
            hiddenCount: hiddenCount,
            previousHiddenCount: previousHiddenCount,
            streamingAssistantID: streamingAssistantID,
            previousStreamingAssistantID: previousStreamingAssistantID,
            themeChanged: previousThemeID != themeID
        )

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

    static func reconfigureItemIDs(
        nextIDs: [String],
        nextIDSet: Set<String>,
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem],
        hiddenCount: Int,
        previousHiddenCount: Int,
        streamingAssistantID: String?,
        previousStreamingAssistantID: String?,
        themeChanged: Bool
    ) -> [String] {
        var changedIDs = changedItemIDs(
            nextIDs: nextIDs,
            nextItemByID: nextItemByID,
            previousItemByID: previousItemByID
        )

        if hiddenCount != previousHiddenCount,
           nextIDSet.contains(ChatTimelineCollectionHost.loadMoreID) {
            changedIDs.append(ChatTimelineCollectionHost.loadMoreID)
        }

        if let streamingAssistantID {
            changedIDs.append(streamingAssistantID)
        }

        if let previousStreamingAssistantID,
           previousStreamingAssistantID != streamingAssistantID {
            changedIDs.append(previousStreamingAssistantID)
        }

        if themeChanged {
            changedIDs.append(contentsOf: nextIDs)
        }

        return dedupeVisibleChangedIDs(changedIDs, nextIDSet: nextIDSet)
    }

    private static func changedItemIDs(
        nextIDs: [String],
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem]
    ) -> [String] {
        var changed: [String] = []
        changed.reserveCapacity(nextIDs.count)

        for id in nextIDs {
            guard let nextItem = nextItemByID[id],
                  let previous = previousItemByID[id] else {
                continue
            }

            if previous != nextItem {
                changed.append(id)
            }
        }

        return changed
    }

    private static func dedupeVisibleChangedIDs(
        _ changedIDs: [String],
        nextIDSet: Set<String>
    ) -> [String] {
        var seen: Set<String> = []
        seen.reserveCapacity(changedIDs.count)

        var deduped: [String] = []
        deduped.reserveCapacity(min(changedIDs.count, nextIDSet.count))

        for id in changedIDs {
            guard nextIDSet.contains(id) else { continue }
            if seen.insert(id).inserted {
                deduped.append(id)
            }
        }

        return deduped
    }
}
