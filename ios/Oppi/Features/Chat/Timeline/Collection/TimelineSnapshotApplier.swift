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

        // Fast path: when no previous items exist (cold start), skip change
        // detection entirely — everything is new.
        guard !previousItemByID.isEmpty else {
            ChatTimelinePerf.beginSnapshotBuildPhase()
            ChatTimelinePerf.endSnapshotBuildPhase()
            ChatTimelinePerf.updateTimelineApplyCycle(
                itemCount: nextIDs.count,
                changedCount: 0
            )

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(nextIDs)

            let applyToken = ChatTimelinePerf.beginCollectionApply(
                itemCount: nextIDs.count,
                changedCount: 0
            )
            dataSource?.apply(snapshot, animatingDifferences: false)
            ChatTimelinePerf.endCollectionApply(applyToken)
            return
        }

        ChatTimelinePerf.beginSnapshotBuildPhase()

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

        ChatTimelinePerf.endSnapshotBuildPhase()
        ChatTimelinePerf.updateTimelineApplyCycle(
            itemCount: nextIDs.count,
            changedCount: dedupedChangedIDs.count
        )

        // Fast path: when the ID list is structurally unchanged (same count,
        // same IDs), skip the full snapshot rebuild. Just reconfigure changed
        // items on the existing snapshot. This avoids UIKit's O(n) internal
        // diff for the common streaming case where only content mutates.
        if let dataSource,
           previousThemeID == themeID {
            let existingSnapshot = dataSource.snapshot()
            let existingIDs = existingSnapshot.itemIdentifiers
            if existingIDs.count == nextIDs.count, existingIDs == nextIDs {
                if !dedupedChangedIDs.isEmpty {
                    var snapshot = existingSnapshot
                    snapshot.reconfigureItems(dedupedChangedIDs)
                    let applyToken = ChatTimelinePerf.beginCollectionApply(
                        itemCount: nextIDs.count,
                        changedCount: dedupedChangedIDs.count
                    )
                    dataSource.apply(snapshot, animatingDifferences: false)
                    ChatTimelinePerf.endCollectionApply(applyToken)
                }
                return
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextIDs)

        if !dedupedChangedIDs.isEmpty {
            snapshot.reconfigureItems(dedupedChangedIDs)
        }

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
            previousItemByID: previousItemByID,
            streamingAssistantID: streamingAssistantID
        )

        if hiddenCount != previousHiddenCount,
           nextIDSet.contains(ChatTimelineCollectionHost.loadMoreID) {
            changedIDs.append(ChatTimelineCollectionHost.loadMoreID)
        }

        if let streamingAssistantID,
           shouldReconfigureStreamingAssistant(
               id: streamingAssistantID,
               nextItemByID: nextItemByID,
               previousItemByID: previousItemByID
           ) {
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

    /// Detect items whose content changed between snapshots.
    ///
    /// During streaming, the vast majority of timeline rows are immutable.
    /// Use a conservative candidate fast path so we only run `ChatItem`
    /// equality on rows that are expected to mutate in place:
    /// - assistant rows (the actively streaming one is handled separately by the caller)
    /// - in-flight tool rows
    /// - active thinking rows
    /// - mutable marker rows such as permission / compaction system events
    /// - user rows carrying images (memory-warning stripping can change them)
    private static func changedItemIDs(
        nextIDs: [String],
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem],
        streamingAssistantID: String? = nil
    ) -> [String] {
        guard !previousItemByID.isEmpty else { return [] }

        let candidateIDs: [String]
        if let streamingAssistantID {
            candidateIDs = nextIDs.filter { id in
                guard id != streamingAssistantID else { return false }
                return isStreamingMutableCandidate(
                    nextItem: nextItemByID[id],
                    previousItem: previousItemByID[id]
                )
            }
        } else {
            candidateIDs = nextIDs
        }

        var changed: [String] = []
        changed.reserveCapacity(candidateIDs.count)

        for id in candidateIDs {
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

    /// Only the active streaming assistant is allowed to change every tick.
    /// Reconfigure it only when the row payload actually changed.
    private static func shouldReconfigureStreamingAssistant(
        id: String,
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem]
    ) -> Bool {
        nextItemByID[id] != previousItemByID[id]
    }

    private static func isStreamingMutableCandidate(
        nextItem: ChatItem?,
        previousItem: ChatItem?
    ) -> Bool {
        isStreamingMutableItem(nextItem) || isStreamingMutableItem(previousItem)
    }

    private static func isStreamingMutableItem(_ item: ChatItem?) -> Bool {
        guard let item else { return false }

        switch item {
        case .toolCall(_, _, _, _, _, _, let isDone):
            return !isDone
        case .thinking(_, _, _, let isDone):
            return !isDone
        case .assistantMessage, .permission, .permissionResolved, .systemEvent:
            return true
        case .userMessage(_, _, let images, _):
            return !images.isEmpty
        case .audioClip, .error:
            return false
        }
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
