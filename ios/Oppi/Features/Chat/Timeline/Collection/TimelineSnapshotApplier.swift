import UIKit

@MainActor
enum TimelineSnapshotApplier {
    typealias DataSource = UICollectionViewDiffableDataSource<Int, String>

    static func applySnapshot(
        dataSource: DataSource?,
        nextIDs: [String],
        previousIDs: [String],
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem],
        hiddenCount: Int,
        previousHiddenCount: Int,
        streamingAssistantID: String?,
        previousStreamingAssistantID: String?,
        themeID: ThemeID,
        previousThemeID: ThemeID?,
        isBusy: Bool = false
    ) {
        // Fast path: when no previous items exist (cold start), skip change
        // detection entirely — everything is new.
        guard !previousItemByID.isEmpty else {
            ChatTimelinePerf.beginTimelineApplyCycle(itemCount: nextIDs.count, changedCount: 0)
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

        // Fast path: when the ID list is structurally unchanged, skip Set
        // construction for reconfigureItemIDs and avoid the full snapshot
        // rebuild. Compare previousIDs (caller-supplied) instead of querying
        // UIKit's snapshot which allocates an array copy.
        let idsUnchanged = previousIDs.count == nextIDs.count && previousIDs == nextIDs
            && previousThemeID == themeID

        if idsUnchanged {
            // Minimal perf tracking for the streaming fast path.
            let changedIDs = changedItemIDsForReconfigure(
                nextIDs: nextIDs,
                nextItemByID: nextItemByID,
                previousItemByID: previousItemByID,
                hiddenCount: hiddenCount,
                previousHiddenCount: previousHiddenCount,
                streamingAssistantID: streamingAssistantID,
                previousStreamingAssistantID: previousStreamingAssistantID
            )
            ChatTimelinePerf.beginTimelineApplyCycle(
                itemCount: nextIDs.count,
                changedCount: changedIDs.count
            )
            if let dataSource, !changedIDs.isEmpty {
                var snapshot = dataSource.snapshot()
                let validIDs = changedIDs.filter {
                    snapshot.indexOfItem($0) != nil
                }
                if !validIDs.isEmpty {
                    snapshot.reconfigureItems(validIDs)
                    let applyToken = ChatTimelinePerf.beginCollectionApply(
                        itemCount: nextIDs.count,
                        changedCount: validIDs.count
                    )
                    dataSource.apply(snapshot, animatingDifferences: false)
                    ChatTimelinePerf.endCollectionApply(applyToken)
                }
            }
            return
        }

        ChatTimelinePerf.beginTimelineApplyCycle(itemCount: nextIDs.count, changedCount: 0)
        ChatTimelinePerf.beginSnapshotBuildPhase()

        let dedupedChangedIDs: [String]
        do {
            let nextIDSet = Set(nextIDs)
            dedupedChangedIDs = reconfigureItemIDs(
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
        }

        ChatTimelinePerf.endSnapshotBuildPhase()
        ChatTimelinePerf.updateTimelineApplyCycle(
            itemCount: nextIDs.count,
            changedCount: dedupedChangedIDs.count
        )

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextIDs)

        if !dedupedChangedIDs.isEmpty {
            snapshot.reconfigureItems(dedupedChangedIDs)
        }

        // Structural change: IDs changed (new rows inserted or removed).
        // Animate during busy sessions so new tool/system rows slide in
        // smoothly instead of popping. Skip animation on idle transitions
        // (working indicator removed, session ended) to avoid layout
        // settlement issues that leave content behind the input bar.
        let shouldAnimate = isBusy
        let applyToken = ChatTimelinePerf.beginCollectionApply(
            itemCount: nextIDs.count,
            changedCount: dedupedChangedIDs.count
        )
        if shouldAnimate {
            FrameBudgetMonitor.shared.beginSection("structural_apply")
        }
        dataSource?.apply(snapshot, animatingDifferences: shouldAnimate)
        if shouldAnimate {
            FrameBudgetMonitor.shared.endSection()
        }
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

    /// Optimized change detection for the common case where IDs are unchanged.
    /// Skips Set<String> construction for the common case.
    private static func changedItemIDsForReconfigure(
        nextIDs: [String],
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem],
        hiddenCount: Int,
        previousHiddenCount: Int,
        streamingAssistantID: String?,
        previousStreamingAssistantID: String?
    ) -> [String] {
        var changed = changedItemIDs(
            nextIDs: nextIDs,
            nextItemByID: nextItemByID,
            previousItemByID: previousItemByID,
            streamingAssistantID: streamingAssistantID
        )

        if hiddenCount != previousHiddenCount,
           nextIDs.first == ChatTimelineCollectionHost.loadMoreID {
            changed.append(ChatTimelineCollectionHost.loadMoreID)
        }

        if let streamingAssistantID,
           shouldReconfigureStreamingAssistant(
               id: streamingAssistantID,
               nextItemByID: nextItemByID,
               previousItemByID: previousItemByID
           ) {
            changed.append(streamingAssistantID)
        }

        if let previousStreamingAssistantID,
           previousStreamingAssistantID != streamingAssistantID {
            changed.append(previousStreamingAssistantID)
        }

        // Dedup is required: streaming/previousStreaming IDs may duplicate
        // entries from changedItemIDs when streaming state transitions.
        guard changed.count > 1 else { return changed }
        var seen = Set<String>(minimumCapacity: changed.count)
        return changed.filter { seen.insert($0).inserted }
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
        case .permission, .permissionResolved, .systemEvent:
            return true
        case .userMessage(_, _, let images, _):
            return !images.isEmpty
        // Assistant messages are handled separately via
        // shouldReconfigureStreamingAssistant — only the actively streaming
        // one needs reconfiguration. Past assistants never change in-flight.
        case .assistantMessage, .audioClip, .error:
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
