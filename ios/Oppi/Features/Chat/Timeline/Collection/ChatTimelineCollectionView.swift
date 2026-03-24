import SwiftUI
import UIKit

// swiftlint:disable type_body_length
struct ChatTimelineScrollCommand: Equatable {
    enum Anchor: Equatable {
        case top
        case bottom
    }

    let id: String
    let anchor: Anchor
    let animated: Bool
    let nonce: Int
}

struct ChatTimelineCollectionHost: UIViewRepresentable {
    static let loadMoreID = "__timeline.load-more__"
    static let workingIndicatorID = "working-indicator"

    struct Configuration {
        let items: [ChatItem]
        let hiddenCount: Int
        let renderWindowStep: Int
        let isBusy: Bool
        let streamingAssistantID: String?
        let sessionId: String
        let workspaceId: String?
        let onFork: (String) -> Void
        let onShowEarlier: () -> Void
        let scrollCommand: ChatTimelineScrollCommand?
        let scrollController: ChatScrollController
        let reducer: TimelineReducer
        let toolOutputStore: ToolOutputStore
        let toolArgsStore: ToolArgsStore
        let toolSegmentStore: ToolSegmentStore
        let toolDetailsStore: ToolDetailsStore
        let connection: ServerConnection
        let currentModel: String?
        let audioPlayer: AudioPlayerService
        let selectedTextPiRouter: SelectedTextPiActionRouter?
        let piQuickActionStore: PiQuickActionStore?
        let topOverlap: CGFloat
        let bottomOverlap: CGFloat

        init(
            items: [ChatItem],
            hiddenCount: Int,
            renderWindowStep: Int,
            isBusy: Bool,
            streamingAssistantID: String?,
            sessionId: String,
            workspaceId: String?,
            onFork: @escaping (String) -> Void,
            onShowEarlier: @escaping () -> Void,
            scrollCommand: ChatTimelineScrollCommand? = nil,
            scrollController: ChatScrollController,
            reducer: TimelineReducer,
            toolOutputStore: ToolOutputStore,
            toolArgsStore: ToolArgsStore,
            toolSegmentStore: ToolSegmentStore,
            toolDetailsStore: ToolDetailsStore? = nil,
            connection: ServerConnection,
            currentModel: String? = nil,
            audioPlayer: AudioPlayerService,
            selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
            piQuickActionStore: PiQuickActionStore? = nil,
            topOverlap: CGFloat = 0,
            bottomOverlap: CGFloat = 0
        ) {
            self.items = items
            self.hiddenCount = hiddenCount
            self.renderWindowStep = renderWindowStep
            self.isBusy = isBusy
            self.streamingAssistantID = streamingAssistantID
            self.sessionId = sessionId
            self.workspaceId = workspaceId
            self.onFork = onFork
            self.onShowEarlier = onShowEarlier
            self.scrollCommand = scrollCommand
            self.scrollController = scrollController
            self.reducer = reducer
            self.toolOutputStore = toolOutputStore
            self.toolArgsStore = toolArgsStore
            self.toolSegmentStore = toolSegmentStore
            self.toolDetailsStore = toolDetailsStore ?? reducer.toolDetailsStore
            self.connection = connection
            self.currentModel = currentModel
            self.audioPlayer = audioPlayer
            self.selectedTextPiRouter = selectedTextPiRouter
            self.piQuickActionStore = piQuickActionStore
            self.topOverlap = topOverlap
            self.bottomOverlap = bottomOverlap
        }
    }

    let configuration: Configuration

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = AnchoredCollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = UIColor(Color.themeBg)
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.delegate = context.coordinator

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Controller.handleTimelineTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(tapGesture)

        collectionView.accessibilityIdentifier = "chat.timeline"
        collectionView.contentInset.top = configuration.topOverlap
        collectionView.contentInset.bottom = configuration.bottomOverlap
        context.coordinator.configureDataSource(collectionView: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.apply(configuration: configuration, to: collectionView)
    }

    func makeCoordinator() -> Controller {
        Controller()
    }

    // periphery:ignore - used by ChatTimelineLayoutTests via @testable import
    /// Exposed for tests that need the same layout as the real timeline.
    static func makeTestLayout() -> UICollectionViewLayout { makeLayout() }

    private static func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(100)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        return UICollectionViewCompositionalLayout(section: section)
    }

    @MainActor
    final class Controller: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        // MARK: - Properties + Init

        var dataSource: UICollectionViewDiffableDataSource<Int, String>?

        private let context = ChatTimelineControllerContext()

        var hiddenCount = 0
        var renderWindowStep = 0
        var streamingAssistantID: String?
        var audioPlayer: AudioPlayerService?
        weak var collectionView: UICollectionView?

        var sessionId: String {
            get { context.sessionId }
            set { context.sessionId = newValue }
        }

        var workspaceId: String? {
            get { context.workspaceId }
            set { context.workspaceId = newValue }
        }

        var onFork: ((String) -> Void)? {
            get { context.onFork }
            set { context.onFork = newValue }
        }

        var onShowEarlier: (() -> Void)? {
            get { context.onShowEarlier }
            set { context.onShowEarlier = newValue }
        }

        var scrollController: ChatScrollController? {
            get { context.scrollController }
            set { context.scrollController = newValue }
        }

        var reducer: TimelineReducer? {
            get { context.reducer }
            set { context.reducer = newValue }
        }

        var toolOutputStore: ToolOutputStore? {
            get { context.toolOutputStore }
            set { context.toolOutputStore = newValue }
        }

        var toolArgsStore: ToolArgsStore? {
            get { context.toolArgsStore }
            set { context.toolArgsStore = newValue }
        }

        var toolSegmentStore: ToolSegmentStore? {
            get { context.toolSegmentStore }
            set { context.toolSegmentStore = newValue }
        }

        var toolDetailsStore: ToolDetailsStore? {
            get { context.toolDetailsStore }
            set { context.toolDetailsStore = newValue }
        }

        var connection: ServerConnection? {
            get { context.connection }
            set { context.connection = newValue }
        }

        var currentModel: String? {
            get { context.currentModel }
            set { context.currentModel = newValue }
        }

        var interactionContext: TimelineInteractionContext {
            context.interactionContext
        }

        /// Near-bottom hysteresis to avoid follow/unfollow flicker while
        /// streaming text grows the tail between throttled auto-scroll pulses.
        let nearBottomEnterThreshold: CGFloat = 120
        let nearBottomExitThreshold: CGFloat = 200
        let detachedProgrammaticArmMinDelta: CGFloat = 120
        let detachedProgrammaticCorrectionMaxDelta: CGFloat = 100

        var currentIDs: [String] = []
        var currentItemByID: [String: ChatItem] = [:]
        private var previousItemByID: [String: ChatItem] = [:]
        private var previousStreamingAssistantID: String?
        private var previousHiddenCount = 0
        private var previousItemCount = 0
        private var previousThemeID: ThemeID?
        private var lastHandledScrollCommandNonce = 0
        var lastObservedContentOffsetY: CGFloat?
        var lastObservedContentHeight: CGFloat?
        var detachedProgrammaticTargetOffsetY: CGFloat?
        var isApplyingDetachedProgrammaticCorrection = false
        var isTimelineBusy = false
        var lastDistanceFromBottom: CGFloat = 0
        let toolOutputLoader = ExpandedToolOutputLoader()

        #if DEBUG
            var _fetchToolOutputForTesting: ((_ sessionId: String, _ toolCallId: String) async throws -> String)? {
                get { toolOutputLoader.fetchOverrideForTesting }
                set { toolOutputLoader.fetchOverrideForTesting = newValue }
            }

            // periphery:ignore - used by ChatTimelineTests via @testable import
            var _toolOutputCanceledCountForTesting: Int {
                toolOutputLoader.canceledCountForTesting
            }

            // periphery:ignore - used by ChatTimelineTests via @testable import
            var _toolOutputStaleDiscardCountForTesting: Int {
                toolOutputLoader.staleDiscardCountForTesting
            }

            // periphery:ignore - used by ChatTimelineTests via @testable import
            var _toolOutputAppliedCountForTesting: Int {
                toolOutputLoader.appliedCountForTesting
            }

            private(set) var _audioStateRefreshCountForTesting = 0
            private(set) var _audioStateRefreshedItemIDsForTesting: [String] = []

            // periphery:ignore - used by ChatTimelineTests via @testable import
            var _toolOutputLoadTaskCountForTesting: Int {
                toolOutputLoader.taskCountForTesting
            }

            // periphery:ignore - used by ChatTimelineTests via @testable import
            var _loadingToolOutputIDsForTesting: Set<String> {
                toolOutputLoader.loadingIDsForTesting
            }

            // periphery:ignore - used by ChatTimelineTests via @testable import
            func _triggerLoadFullToolOutputForTesting(
                itemID: String,
                tool: String,
                outputByteCount: Int,
                in collectionView: UICollectionView
            ) {
                ensureExpandedToolOutputLoaded(
                    itemID: itemID,
                    tool: tool,
                    outputByteCount: outputByteCount,
                    in: collectionView
                )
            }
        #endif

        deinit {
            MainActor.assumeIsolated {
                let observedAudioPlayer = audioPlayer
                toolOutputLoader.cancelAllWork()
                NotificationCenter.default.removeObserver(
                    self,
                    name: AudioPlayerService.stateDidChangeNotification,
                    object: observedAudioPlayer
                )
            }
        }

        // MARK: - Diffing

        /// Build ordered unique items, keeping the last occurrence of each ID.
        ///
        /// Single-pass fast path when no duplicates exist (the common case).
        /// Falls back to a two-pass dedup only when a collision is detected.
        static func uniqueItemsKeepingLast(_ items: [ChatItem]) -> (orderedIDs: [String], itemByID: [String: ChatItem]) {
            var itemByID: [String: ChatItem] = [:]
            itemByID.reserveCapacity(items.count)

            var orderedIDs: [String] = []
            orderedIDs.reserveCapacity(items.count)

            var hasDuplicates = false

            for item in items {
                if itemByID[item.id] != nil {
                    hasDuplicates = true
                    break
                }
                itemByID[item.id] = item
                orderedIDs.append(item.id)
            }

            // Common case: no duplicates — single pass is complete.
            if !hasDuplicates {
                return (orderedIDs: orderedIDs, itemByID: itemByID)
            }

            // Rare case: duplicates found — fall back to two-pass dedup
            // that keeps the last occurrence of each ID.
            itemByID.removeAll(keepingCapacity: true)
            orderedIDs.removeAll(keepingCapacity: true)

            var lastIndexByID: [String: Int] = [:]
            lastIndexByID.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                lastIndexByID[item.id] = index
            }

            for (index, item) in items.enumerated() {
                guard lastIndexByID[item.id] == index else { continue }
                orderedIDs.append(item.id)
                itemByID[item.id] = item
            }

            return (orderedIDs: orderedIDs, itemByID: itemByID)
        }

        // periphery:ignore - used by ChatTimelineCoordinatorTests via @testable import
        static func toolOutputCompletionDisposition(
            output: String,
            isTaskCancelled: Bool,
            activeSessionID: String,
            currentSessionID: String,
            itemExists: Bool
        ) -> ExpandedToolOutputLoader.CompletionDisposition {
            ExpandedToolOutputLoader.completionDisposition(
                output: output,
                isTaskCancelled: isTaskCancelled,
                activeSessionID: activeSessionID,
                currentSessionID: currentSessionID,
                itemExists: itemExists
            )
        }

        // MARK: - Audio State Observation

        private func bindAudioStateObservationIfNeeded(audioPlayer: AudioPlayerService) {
            if let currentAudioPlayer = self.audioPlayer,
               currentAudioPlayer === audioPlayer {
                return
            }

            NotificationCenter.default.removeObserver(
                self,
                name: AudioPlayerService.stateDidChangeNotification,
                object: self.audioPlayer
            )

            self.audioPlayer = audioPlayer
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioStateChangeNotification(_:)),
                name: AudioPlayerService.stateDidChangeNotification,
                object: audioPlayer
            )
        }

        @objc
        private func handleAudioStateChangeNotification(_ notification: Notification) {
            guard let collectionView else { return }

            let changedIDs = Set(Self.audioStateItemIDs(from: notification.userInfo))
            let targetIDs: [String]
            if changedIDs.isEmpty {
                targetIDs = currentAudioItemIDs()
            } else {
                targetIDs = currentIDs.filter { changedIDs.contains($0) && isAudioClipItem(id: $0) }
            }

            guard !targetIDs.isEmpty else { return }

            #if DEBUG
                _audioStateRefreshCountForTesting += 1
                _audioStateRefreshedItemIDsForTesting = targetIDs
            #endif
            reconfigureItems(targetIDs, in: collectionView)
        }

        private func currentAudioItemIDs() -> [String] {
            currentIDs.filter { isAudioClipItem(id: $0) }
        }

        private func isAudioClipItem(id: String) -> Bool {
            guard let item = currentItemByID[id] else { return false }
            if case .audioClip = item {
                return true
            }
            return false
        }

        private static func audioStateItemIDs(from userInfo: [AnyHashable: Any]?) -> [String] {
            guard let userInfo else { return [] }

            let keys = [
                AudioPlayerService.previousPlayingItemIDUserInfoKey,
                AudioPlayerService.playingItemIDUserInfoKey,
                AudioPlayerService.previousLoadingItemIDUserInfoKey,
                AudioPlayerService.loadingItemIDUserInfoKey,
            ]

            var ids: [String] = []
            ids.reserveCapacity(keys.count)
            for key in keys {
                guard let value = userInfo[key] as? String,
                      !value.isEmpty else {
                    continue
                }
                ids.append(value)
            }

            return ids
        }

        // MARK: - Apply Configuration

        func apply(configuration: Configuration, to collectionView: UICollectionView) {
            let sessionScopeChanged = context.didChangeSessionScope(for: configuration)

            hiddenCount = configuration.hiddenCount
            renderWindowStep = configuration.renderWindowStep
            streamingAssistantID = configuration.streamingAssistantID
            isTimelineBusy = configuration.isBusy

            if sessionScopeChanged {
                cancelAllToolOutputLoadTasks()
                lastObservedContentOffsetY = nil
                lastObservedContentHeight = nil
                detachedProgrammaticTargetOffsetY = nil
                isApplyingDetachedProgrammaticCorrection = false
                configuration.scrollController.setUserInteracting(false)
                configuration.scrollController.setDetachedStreamingHintVisible(false)
                configuration.scrollController.setJumpToBottomHintVisible(false)
            }

            context.apply(configuration: configuration)
            self.collectionView = collectionView
            bindAudioStateObservationIfNeeded(audioPlayer: configuration.audioPlayer)

            // Detect theme change from runtime state instead of threaded param.
            let currentThemeID = ThemeRuntimeState.currentThemeID()
            let themeChanged = previousThemeID != currentThemeID || previousThemeID == nil

            // Only update backgroundColor when theme changed or on first apply.
            if themeChanged {
                collectionView.backgroundColor = UIColor(Color.themeBg)
            }

            if collectionView.contentInset.top != configuration.topOverlap {
                collectionView.contentInset.top = configuration.topOverlap
            }
            if collectionView.contentInset.bottom != configuration.bottomOverlap {
                let oldBottom = collectionView.contentInset.bottom
                collectionView.contentInset.bottom = configuration.bottomOverlap

                // When the bottom inset grows (e.g. footer measured from 0 →
                // real height, or message queue appearing) while the user is
                // attached to the bottom, compensate the content offset so
                // the last item stays right above the footer. Without this,
                // the inset increase expands the scrollable range downward
                // but the offset stays put, leaving a visible gap between
                // the last message and the input bar.
                let delta = configuration.bottomOverlap - oldBottom
                if delta > 0, scrollController?.isCurrentlyNearBottom ?? true {
                    let maxOffsetY = max(
                        -collectionView.adjustedContentInset.top,
                        collectionView.contentSize.height
                            - collectionView.bounds.height
                            + collectionView.adjustedContentInset.bottom
                    )
                    let target = min(collectionView.contentOffset.y + delta, maxOffsetY)
                    collectionView.contentOffset.y = target
                }
            }

            // Streaming fast path: when the item list is structurally unchanged
            // (same count, same streaming ID, same busy/hidden state), skip
            // the full plan build + snapshot apply. This avoids O(n) dedup,
            // Set construction, and UIKit snapshot diffing on every 33ms tick.
            let structurallyUnchanged = configuration.items.count == previousItemCount
                && configuration.streamingAssistantID == previousStreamingAssistantID
                && configuration.isBusy == isTimelineBusy
                && configuration.hiddenCount == previousHiddenCount
                && !themeChanged

            if structurallyUnchanged,
               let streamingID = configuration.streamingAssistantID,
               let nextItem = configuration.items.last(where: { $0.id == streamingID }),
               let prevItem = currentItemByID[streamingID],
               prevItem != nextItem,
               let indexPath = dataSource?.indexPath(for: streamingID),
               let cell = collectionView.cellForItem(at: indexPath) {
                // Direct streaming cell update.
                ChatTimelinePerf.beginTimelineApplyCycle(
                    itemCount: currentIDs.count,
                    changedCount: 1
                )
                let configureStartNs = ChatTimelinePerf.timestampNs()
                if let config = assistantRowConfiguration(itemID: streamingID, item: nextItem) {
                    let applyToken = ChatTimelinePerf.beginCollectionApply(
                        itemCount: currentIDs.count,
                        changedCount: 1,
                        sessionId: configuration.sessionId
                    )
                    cell.contentConfiguration = config
                    cell.contentView.clipsToBounds = true
                    ChatTimelinePerf.endCollectionApply(applyToken)
                }
                ChatTimelinePerf.recordCellConfigure(
                    rowType: "assistant_native_direct",
                    durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                )
                // Update tracking for the streaming item only.
                currentItemByID[streamingID] = nextItem
                previousItemByID[streamingID] = nextItem
                previousStreamingAssistantID = configuration.streamingAssistantID
                previousHiddenCount = configuration.hiddenCount
                previousItemCount = configuration.items.count
                previousThemeID = currentThemeID
                ChatTimelinePerf.endTimelineApplyCycle(didScroll: false)
                updateDetachedStreamingHintVisibility()
                return
            }

            // No-op fast path: streaming, structurally unchanged, content identical.
            if structurallyUnchanged,
               let streamingID = configuration.streamingAssistantID,
               let nextItem = configuration.items.last(where: { $0.id == streamingID }),
               let prevItem = currentItemByID[streamingID],
               prevItem == nextItem {
                ChatTimelinePerf.beginTimelineApplyCycle(
                    itemCount: currentIDs.count,
                    changedCount: 0
                )
                previousStreamingAssistantID = configuration.streamingAssistantID
                previousHiddenCount = configuration.hiddenCount
                previousItemCount = configuration.items.count
                previousThemeID = currentThemeID
                ChatTimelinePerf.endTimelineApplyCycle(didScroll: false)
                updateDetachedStreamingHintVisibility()
                return
            }

            let applyPlan = ChatTimelineApplyPlan.build(
                items: configuration.items,
                hiddenCount: configuration.hiddenCount,
                isBusy: configuration.isBusy,
                streamingAssistantID: configuration.streamingAssistantID
            ).withRemovedIDs(from: currentIDs)

            if !applyPlan.removedIDs.isEmpty {
                cancelToolOutputLoadTasks(for: applyPlan.removedIDs)
            }

            let previousIDs = currentIDs
            currentIDs = applyPlan.nextIDs
            currentItemByID = applyPlan.nextItemByID

            // Enable passive anchoring before snapshot apply so layout passes
            // during reconfigure preserve scroll position for detached users.
            // When attached (near bottom), anchoring is off so auto-scroll and
            // passive bottom-pinning work without interference.
            if let anchoredCV = collectionView as? AnchoredCollectionView {
                let detached = !(scrollController?.isCurrentlyNearBottom ?? true)
                anchoredCV.isDetachedFromBottom = detached
                if detached {
                    anchoredCV.captureDetachedAnchor()
                }
            }

            TimelineSnapshotApplier.applySnapshot(
                dataSource: dataSource,
                nextIDs: applyPlan.nextIDs,
                previousIDs: previousIDs,
                nextItemByID: applyPlan.nextItemByID,
                previousItemByID: previousItemByID,
                hiddenCount: configuration.hiddenCount,
                previousHiddenCount: previousHiddenCount,
                streamingAssistantID: configuration.streamingAssistantID,
                previousStreamingAssistantID: previousStreamingAssistantID,
                sessionId: configuration.sessionId,
                themeChanged: themeChanged,
                isBusy: configuration.isBusy
            )

            previousItemByID = applyPlan.nextItemByID
            previousStreamingAssistantID = configuration.streamingAssistantID
            previousHiddenCount = configuration.hiddenCount
            previousItemCount = configuration.items.count
            previousThemeID = currentThemeID

            // Note: detached anchor is NOT cleared here. It persists until
            // the next snapshot apply, where captureDetachedAnchor() replaces
            // it with a fresh capture. This ensures the anchor stays active
            // through all deferred layout invalidations (e.g.
            // invalidateEnclosingCollectionViewLayout from tool rows) that
            // fire asynchronously after this apply completes.
            //
            // Previously, a double-async clear raced with the deferred
            // invalidation — the anchor could be cleared BEFORE the
            // invalidation's layoutIfNeeded fired, causing 480pt drift.

            // Force layout when not streaming, or when the user is scrolled
            // away from the bottom. Forced layout resolves all pending cell
            // self-sizing in one pass, preventing the post-layout self-sizing
            // cascade that causes contentOffset drift and potential hangs.
            //
            // When attached and streaming, skip forced layout — the collection
            // view layouts naturally and auto-scroll keeps the viewport pinned.
            let detached = !(scrollController?.isCurrentlyNearBottom ?? true)
            if !configuration.isBusy || detached {
                let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: applyPlan.nextIDs.count, sessionId: configuration.sessionId)
                collectionView.layoutIfNeeded()
                ChatTimelinePerf.endLayoutPass(layoutToken)
            }
            var didScroll = false
            if let scrollCommand = configuration.scrollCommand,
               scrollCommand.nonce != lastHandledScrollCommandNonce,
               performScroll(scrollCommand, in: collectionView) {
                lastHandledScrollCommandNonce = scrollCommand.nonce
                didScroll = true
            }

            // When the session is busy (streaming or running tools), new items
            // grow contentSize faster than auto-scroll can keep up. Suppress
            // updateScrollState here to avoid flipping isNearBottom=false before
            // the throttled auto-scroll fires. User-initiated scroll changes
            // are still detected via scrollViewDidScroll delegate callbacks.
            //
            // When idle (!isBusy), only update scroll state if the user is
            // currently attached. A detached user must not be re-attached by
            // the idle transition — re-attachment only happens through explicit
            // user-driven scrolls back toward the bottom.
            let isBusy = configuration.isBusy
            let alreadyAttached = scrollController?.isCurrentlyNearBottom ?? true
            if !isBusy, alreadyAttached {
                updateScrollState(collectionView)
            }
            updateDetachedStreamingHintVisibility()
            ChatTimelinePerf.endTimelineApplyCycle(didScroll: didScroll)
        }

        // MARK: - UICollectionViewDelegate

        @objc func handleTimelineTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            gesture.view?.window?.endEditing(true)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var current = touch.view
            while let candidate = current {
                if let textView = candidate as? UITextView, textView.isSelectable { return false }
                current = candidate.superview
            }
            return true
        }
        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.section == 0, indexPath.item < currentIDs.count else { return }
            let itemID = currentIDs[indexPath.item]
            if itemID == ChatTimelineCollectionHost.loadMoreID || itemID == ChatTimelineCollectionHost.workingIndicatorID {
                return
            }

            collectionView.deselectItem(at: indexPath, animated: false)

            guard let item = currentItemByID[itemID],
                  let reducer else {
                return
            }

            switch item {
            case .toolCall(_, let tool, _, _, let outputByteCount, _, _):
                if presentReadImagePreviewInsteadOfExpanding(
                    itemID: itemID,
                    item: item,
                    indexPath: indexPath,
                    in: collectionView
                ) {
                    if reducer.expandedItemIDs.contains(itemID) {
                        reducer.expandedItemIDs.remove(itemID)
                        anchoredReconfigureToolRow(
                            itemID: itemID,
                            anchorIndexPath: indexPath,
                            in: collectionView
                        )
                    }
                    return
                }

                // Do not gate on current cell.contentConfiguration type.
                // During high-frequency streaming updates the visible cell can be
                // transiently reconfigured while still representing the same
                // tool item, and strict type checks can drop taps.
                let wasExpanded = reducer.expandedItemIDs.contains(itemID)
                if wasExpanded {
                    reducer.expandedItemIDs.remove(itemID)
                    cancelToolOutputRetryWork(for: itemID)
                    cancelToolOutputLoadTasks(for: [itemID])
                } else {
                    reducer.expandedItemIDs.insert(itemID)
                    ensureExpandedToolOutputLoaded(
                        itemID: itemID,
                        tool: tool,
                        outputByteCount: outputByteCount,
                        in: collectionView
                    )
                }
                anchoredReconfigureToolRow(
                    itemID: itemID,
                    anchorIndexPath: indexPath,
                    in: collectionView
                )
            case .thinking:
                // Thinking rows own their long-form entry points (floating
                // button, context menu, pinch/double-tap) to match tool rows.
                return

            case .systemEvent:
                // Compaction rows now use an explicit chevron button affordance
                // for expand/collapse to keep row-level tap behavior consistent
                // with double-tap copy gestures.
                return

            default:
                break
            }
        }

        private func presentReadImagePreviewInsteadOfExpanding(
            itemID: String,
            item: ChatItem,
            indexPath: IndexPath,
            in collectionView: UICollectionView
        ) -> Bool {
            guard let config = toolRowConfiguration(itemID: itemID, item: item),
                  config.collapsedImageBase64 != nil else {
                return false
            }

            guard let cell = collectionView.cellForItem(at: indexPath),
                  let toolRowView = Self.firstSubview(ofType: ToolTimelineRowContentView.self, in: cell.contentView) else {
                return false
            }

            return toolRowView.presentCollapsedImagePreviewIfAvailable()
        }

        private static func firstSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
            if let match = root as? T { return match }
            for child in root.subviews {
                if let match = firstSubview(ofType: type, in: child) {
                    return match
                }
            }
            return nil
        }

        // MARK: - Tool Output Loading

        private func ensureExpandedToolOutputLoaded(
            itemID: String,
            tool: String,
            outputByteCount: Int,
            in collectionView: UICollectionView,
            attempt: Int = 0
        ) {
            guard let toolOutputStore else { return }

            let fetchToolOutput: ExpandedToolOutputLoader.FetchToolOutput
            #if DEBUG
                if let fetchHook = _fetchToolOutputForTesting {
                    fetchToolOutput = fetchHook
                } else {
                    guard let defaultFetch = makeDefaultFetchToolOutput(tool: tool) else { return }
                    fetchToolOutput = defaultFetch
                }
            #else
                guard let defaultFetch = makeDefaultFetchToolOutput(tool: tool) else { return }
                fetchToolOutput = defaultFetch
            #endif

            let request = ExpandedToolOutputLoader.LoadRequest(
                itemID: itemID,
                tool: tool,
                outputByteCount: outputByteCount,
                attempt: attempt,
                hasExistingOutput: {
                    toolOutputStore.hasCompleteOutput(for: itemID)
                },
                activeSessionID: sessionId,
                currentSessionID: { [weak self] in
                    self?.sessionId ?? ""
                },
                itemExists: { [weak self] in
                    self?.currentItemByID[itemID] != nil
                },
                isItemExpanded: { [weak self] in
                    self?.reducer?.expandedItemIDs.contains(itemID) == true
                },
                fetchToolOutput: fetchToolOutput,
                applyOutput: { output in
                    toolOutputStore.replace(output, for: itemID)
                },
                reconfigureItem: { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    self.reconfigureItems([itemID], in: collectionView)
                }
            )

            toolOutputLoader.loadIfNeeded(request)
        }

        private func makeDefaultFetchToolOutput(tool: String) -> ExpandedToolOutputLoader.FetchToolOutput? {
            guard let apiClient = connection?.apiClient,
                  let workspaceId,
                  !workspaceId.isEmpty else {
                return nil
            }

            return { sessionId, toolCallId in
                let isShellTool = ToolCallFormatting.isBashTool(tool)
                    || ToolCallFormatting.isGrepTool(tool)
                    || ToolCallFormatting.isFindTool(tool)
                    || ToolCallFormatting.isLsTool(tool)

                if isShellTool,
                   let fullOutput = try await apiClient.getNonEmptyFullToolOutput(
                       workspaceId: workspaceId,
                       sessionId: sessionId,
                       toolCallId: toolCallId
                   ) {
                    return fullOutput
                }

                return try await apiClient.getNonEmptyToolOutput(
                    workspaceId: workspaceId,
                    sessionId: sessionId,
                    toolCallId: toolCallId
                ) ?? ""
            }
        }

        private func cancelToolOutputRetryWork(for itemID: String) {
            toolOutputLoader.cancelRetryWork(for: itemID)
        }

        private func cancelToolOutputLoadTasks(for itemIDs: Set<String>) {
            toolOutputLoader.cancelLoadTasks(for: itemIDs)
        }

        private func cancelAllToolOutputLoadTasks() {
            toolOutputLoader.cancelAllWork()
        }

        // MARK: - Animation + Scroll

        /// Reconfigure a single tool row through the diffable data source
        /// snapshot pipeline. This preserves scroll stability through UIKit's
        /// self-sizing flow. The previous direct cell.contentConfiguration +
        /// invalidateLayout() approach caused full layout re-estimation that
        /// reset off-screen cached sizes, shifting contentOffset when a
        /// visible cell changed height (expand/collapse).
        private func reconfigureToolRow(
            itemID: String,
            in collectionView: UICollectionView
        ) {
            reconfigureItems([itemID], in: collectionView)
        }

        /// Reconfigure a tool row while anchoring a specific item's screen
        /// position. Captures the tapped row's screen-relative Y before
        /// the reconfigure, restores it after, and sets the anchored
        /// collection view's expand/collapse anchor for any deferred async
        /// layout passes (e.g. `invalidateEnclosingCollectionViewLayout`).
        private func anchoredReconfigureToolRow(
            itemID: String,
            anchorIndexPath: IndexPath,
            in collectionView: UICollectionView
        ) {
            let anchoredCV = collectionView as? AnchoredCollectionView

            // Capture anchor position before the reconfigure changes it.
            let screenYBefore: CGFloat?
            if let attrs = collectionView.layoutAttributesForItem(at: anchorIndexPath) {
                screenYBefore = attrs.frame.origin.y - collectionView.contentOffset.y
            } else {
                screenYBefore = nil
            }

            reconfigureToolRow(itemID: itemID, in: collectionView)

            // Restore anchor position after the synchronous layout pass.
            if let screenYBefore {
                restoreAnchorScreenPosition(
                    anchorIndexPath: anchorIndexPath,
                    savedScreenY: screenYBefore,
                    in: collectionView
                )
            }

            // Set the AnchoredCollectionView anchor for the deferred async
            // invalidateEnclosingCollectionViewLayout pass, then clear one
            // tick after that pass settles.
            anchoredCV?.setExpandCollapseAnchor(indexPath: anchorIndexPath)
            DispatchQueue.main.async { [weak anchoredCV] in
                DispatchQueue.main.async { [weak anchoredCV] in
                    anchoredCV?.clearExpandCollapseAnchor()
                }
            }
        }

        /// Adjust contentOffset so the item at `anchorIndexPath` returns
        /// to `savedScreenY` (its screen-relative Y before the layout
        /// change). Safe to call outside of `layoutSubviews`.
        private func restoreAnchorScreenPosition(
            anchorIndexPath: IndexPath,
            savedScreenY: CGFloat,
            in collectionView: UICollectionView
        ) {
            guard let newAttrs = collectionView.layoutAttributesForItem(at: anchorIndexPath) else {
                return
            }
            let currentScreenY = newAttrs.frame.origin.y - collectionView.contentOffset.y
            let delta = currentScreenY - savedScreenY
            guard delta.isFinite, abs(delta) > 0.5 else { return }

            let insets = collectionView.adjustedContentInset
            let minOffsetY = -insets.top
            let maxOffsetY = max(
                minOffsetY,
                collectionView.contentSize.height
                    - collectionView.bounds.height
                    + insets.bottom
            )
            let target = collectionView.contentOffset.y + delta
            let clamped = min(max(target, minOffsetY), maxOffsetY)
            guard abs(clamped - collectionView.contentOffset.y) > 0.5 else { return }
            collectionView.contentOffset.y = clamped
        }

        func reconfigureItems(_ itemIDs: [String], in collectionView: UICollectionView) {
            TimelineSnapshotApplier.reconfigureItems(
                itemIDs,
                dataSource: dataSource,
                collectionView: collectionView,
                currentIDs: currentIDs,
                sessionId: sessionId
            )
        }

        private func performScroll(
            _ command: ChatTimelineScrollCommand,
            in collectionView: UICollectionView
        ) -> Bool {
            TimelineScrollCoordinator.performScroll(
                command,
                in: collectionView,
                currentIDs: currentIDs,
                sessionId: sessionId
            ) { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                // `scrollToItem(animated: false)` can update contentOffset on the next
                // runloop tick without always triggering immediate delegate callbacks.
                // Re-sample scroll state asynchronously so diagnostics (near-bottom,
                // top visible id) converge deterministically for harness assertions.
                collectionView.layoutIfNeeded()
                self.updateScrollState(collectionView)
                self.updateDetachedStreamingHintVisibility()
            }
        }

        /// Minimum distance from bottom before showing the jump-to-bottom
        /// button. One viewport height prevents flash from bounce/small scrolls.
        let jumpToBottomMinDistance: CGFloat = 500
    }
}

// swiftlint:enable type_body_length
