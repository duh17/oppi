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
        streamingAssistantID: String?,
        previousStreamingAssistantID: String?,
        sessionId: String? = nil,
        themeChanged: Bool = false,
        isBusy: Bool = false,
        forceReconfigureIDs: [String] = [],
        cellKindChanged: (String) -> Bool,
        willReconfigure: ([String]) -> Void = { _ in }
    ) {
        // Fast path: when no previous items exist (cold start), skip change
        // detection entirely — everything is new.
        guard !previousItemByID.isEmpty else {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(nextIDs)

            let applyToken = ChatTimelinePerf.beginCollectionApply(
                itemCount: nextIDs.count,
                changedCount: 0,
                sessionId: sessionId
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
            && !themeChanged

        if idsUnchanged {
            // Minimal perf tracking for the streaming fast path.
            let changedIDs = mergedReconfigureIDs(
                changedItemIDsForReconfigure(
                    nextIDs: nextIDs,
                    nextItemByID: nextItemByID,
                    previousItemByID: previousItemByID,
                    streamingAssistantID: streamingAssistantID,
                    previousStreamingAssistantID: previousStreamingAssistantID
                ),
                nextIDs: nextIDs,
                forceReconfigureIDs: forceReconfigureIDs
            )
            if let dataSource, !changedIDs.isEmpty {
                // changedItemIDsForReconfigure validates streaming IDs
                // against nextItemByID before including them.
                willReconfigure(changedIDs)
                var snapshot = dataSource.snapshot()
                refresh(changedIDs, in: &snapshot, cellKindChanged: cellKindChanged)
                let applyToken = ChatTimelinePerf.beginCollectionApply(
                    itemCount: nextIDs.count,
                    changedCount: changedIDs.count,
                    sessionId: sessionId
                )
                dataSource.apply(snapshot, animatingDifferences: false)
                ChatTimelinePerf.endCollectionApply(applyToken)
            }
            return
        }

        let dedupedChangedIDs: [String]
        do {
            let nextIDSet = Set(nextIDs)
            dedupedChangedIDs = mergedReconfigureIDs(
                reconfigureItemIDs(
                    nextIDs: nextIDs,
                    nextIDSet: nextIDSet,
                    nextItemByID: nextItemByID,
                    previousItemByID: previousItemByID,
                    streamingAssistantID: streamingAssistantID,
                    previousStreamingAssistantID: previousStreamingAssistantID,
                    themeChanged: themeChanged
                ),
                nextIDs: nextIDs,
                forceReconfigureIDs: forceReconfigureIDs
            )
        }

        // Structural change: IDs changed (new rows inserted or removed).
        // Never animate structural diffs — instant transitions are calmer
        // and avoid the layout settlement overhead that animated applies
        // incur (~2-3x cost). The previous behavior animated during busy
        // sessions, which caused tool/system row insertions to slide in
        // with a crossfade that could stutter on heavy timelines.
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextIDs)

        if !dedupedChangedIDs.isEmpty {
            willReconfigure(dedupedChangedIDs)
            refresh(dedupedChangedIDs, in: &snapshot, cellKindChanged: cellKindChanged)
        }
        let applyToken = ChatTimelinePerf.beginCollectionApply(
            itemCount: nextIDs.count,
            changedCount: dedupedChangedIDs.count,
            sessionId: sessionId
        )
        dataSource?.apply(snapshot, animatingDifferences: false)
        ChatTimelinePerf.endCollectionApply(applyToken)
    }

    /// Redraws `itemIDs`: reconfigured in their existing cells, except a row
    /// whose cell kind changed (`cellKindChanged`), which is reloaded. UIKit
    /// reaches an existing cell, a prefetched one included, only through the
    /// registration that made it, and throws on any other.
    static func refresh(
        _ itemIDs: [String],
        in snapshot: inout NSDiffableDataSourceSnapshot<Int, String>,
        cellKindChanged: (String) -> Bool
    ) {
        var reload: [String] = []
        let reconfigure = itemIDs.filter { id in
            guard cellKindChanged(id) else { return true }
            reload.append(id)
            return false
        }
        if !reconfigure.isEmpty { snapshot.reconfigureItems(reconfigure) }
        if !reload.isEmpty { snapshot.reloadItems(reload) }
    }

    private static func mergedReconfigureIDs(
        _ changedIDs: [String],
        nextIDs: [String],
        forceReconfigureIDs: [String]
    ) -> [String] {
        guard !forceReconfigureIDs.isEmpty else { return changedIDs }
        let nextIDSet = Set(nextIDs)
        var seen = Set(changedIDs)
        var merged = changedIDs
        for id in forceReconfigureIDs where nextIDSet.contains(id) && !seen.contains(id) {
            merged.append(id)
            seen.insert(id)
        }
        return merged
    }

    static func assistantPresentationItemIDs(
        nextIDs: [String],
        nextItemByID: [String: ChatItem]
    ) -> [String] {
        nextIDs.filter { id in
            guard let item = nextItemByID[id], case .assistantMessage = item else {
                return false
            }
            return true
        }
    }

    static func themeReconfigureItemIDs(
        currentIDs: [String],
        visibleIDs: [String]
    ) -> [String] {
        guard !visibleIDs.isEmpty else { return [] }
        let visibleIDSet = Set(visibleIDs)
        return currentIDs.filter(visibleIDSet.contains)
    }

    /// Reconfigures the rows still in the snapshot. Returns whether any were;
    /// the caller owns the layout pass that sizes them. `willReconfigure`
    /// hears the rows first (the layout's `contentDidChange`).
    @discardableResult
    static func reconfigureItems(
        _ itemIDs: [String],
        dataSource: DataSource?,
        currentIDs: [String],
        sessionId: String? = nil,
        cellKindChanged: (String) -> Bool,
        willReconfigure: ([String]) -> Void = { _ in }
    ) -> Bool {
        guard let dataSource else { return false }

        var snapshot = dataSource.snapshot()
        let existing = itemIDs.filter { snapshot.indexOfItem($0) != nil }
        guard !existing.isEmpty else { return false }
        willReconfigure(existing)

        refresh(existing, in: &snapshot, cellKindChanged: cellKindChanged)

        let applyToken = ChatTimelinePerf.beginCollectionApply(
            itemCount: currentIDs.count,
            changedCount: existing.count,
            sessionId: sessionId
        )
        dataSource.apply(snapshot, animatingDifferences: false)
        ChatTimelinePerf.endCollectionApply(applyToken)
        return true
    }

    static func reconfigureItemIDs(
        nextIDs: [String],
        nextIDSet: Set<String>,
        nextItemByID: [String: ChatItem],
        previousItemByID: [String: ChatItem],
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
        streamingAssistantID: String?,
        previousStreamingAssistantID: String?
    ) -> [String] {
        var changed = changedItemIDs(
            nextIDs: nextIDs,
            nextItemByID: nextItemByID,
            previousItemByID: previousItemByID,
            streamingAssistantID: streamingAssistantID
        )

        // Streaming IDs can be arbitrary (not necessarily item IDs in the
        // snapshot). Validate against nextItemByID before appending — the
        // idsUnchanged fast path skips the nextIDSet filter that the
        // structural branch uses.
        if let streamingAssistantID,
           nextItemByID[streamingAssistantID] != nil,
           shouldReconfigureStreamingAssistant(
               id: streamingAssistantID,
               nextItemByID: nextItemByID,
               previousItemByID: previousItemByID
           ) {
            changed.append(streamingAssistantID)
        }

        if let previousStreamingAssistantID,
           previousStreamingAssistantID != streamingAssistantID,
           nextItemByID[previousStreamingAssistantID] != nil {
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
    /// - mutable marker rows such as compaction system events
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

    static func isStreamingMutableItem(_ item: ChatItem?) -> Bool {
        guard let item else { return false }

        switch item {
        case .toolCall(_, _, _, _, _, _, let isDone):
            return !isDone
        case .thinking(_, _, _, let isDone):
            return !isDone
        case .systemEvent:
            return true
        case .userMessage(_, _, let images, _):
            return !images.isEmpty
        // Assistant messages are handled separately via
        // shouldReconfigureStreamingAssistant — only the actively streaming
        // one needs reconfiguration. Past assistants never change in-flight.
        case .assistantMessage, .agentMessage, .audioClip, .cacheMiss, .customEvent, .error, .notice:
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
