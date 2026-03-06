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
        let onOpenFile: (FileToOpen) -> Void
        let onShowEarlier: () -> Void
        let scrollCommand: ChatTimelineScrollCommand?
        let scrollController: ChatScrollController
        let reducer: TimelineReducer
        let toolOutputStore: ToolOutputStore
        let toolArgsStore: ToolArgsStore
        let toolSegmentStore: ToolSegmentStore
        let toolDetailsStore: ToolDetailsStore
        let connection: ServerConnection
        let audioPlayer: AudioPlayerService
        let theme: AppTheme
        let themeID: ThemeID
        let selectedTextPiRouter: SelectedTextPiActionRouter?
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
            onOpenFile: @escaping (FileToOpen) -> Void,
            onShowEarlier: @escaping () -> Void,
            scrollCommand: ChatTimelineScrollCommand?,
            scrollController: ChatScrollController,
            reducer: TimelineReducer,
            toolOutputStore: ToolOutputStore,
            toolArgsStore: ToolArgsStore,
            toolSegmentStore: ToolSegmentStore,
            toolDetailsStore: ToolDetailsStore? = nil,
            connection: ServerConnection,
            audioPlayer: AudioPlayerService,
            theme: AppTheme,
            themeID: ThemeID,
            selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
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
            self.onOpenFile = onOpenFile
            self.onShowEarlier = onShowEarlier
            self.scrollCommand = scrollCommand
            self.scrollController = scrollController
            self.reducer = reducer
            self.toolOutputStore = toolOutputStore
            self.toolArgsStore = toolArgsStore
            self.toolSegmentStore = toolSegmentStore
            self.toolDetailsStore = toolDetailsStore ?? reducer.toolDetailsStore
            self.connection = connection
            self.audioPlayer = audioPlayer
            self.theme = theme
            self.themeID = themeID
            self.selectedTextPiRouter = selectedTextPiRouter
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

        private var onOpenFile: ((FileToOpen) -> Void)? {
            get { context.onOpenFile }
            set { context.onOpenFile = newValue }
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

        var currentThemeID: ThemeID {
            get { context.currentThemeID }
            set { context.currentThemeID = newValue }
        }

        var selectedTextPiRouter: SelectedTextPiActionRouter? {
            get { context.selectedTextPiRouter }
            set { context.selectedTextPiRouter = newValue }
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

        static func uniqueItemsKeepingLast(_ items: [ChatItem]) -> (orderedIDs: [String], itemByID: [String: ChatItem]) {
            var itemByID: [String: ChatItem] = [:]
            itemByID.reserveCapacity(items.count)

            var orderedIDs: [String] = []
            orderedIDs.reserveCapacity(items.count)

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
            hiddenCount = configuration.hiddenCount
            renderWindowStep = configuration.renderWindowStep
            streamingAssistantID = configuration.streamingAssistantID
            isTimelineBusy = configuration.isBusy

            if context.didChangeSessionScope(for: configuration) {
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

            collectionView.backgroundColor = UIColor(Color.themeBg)

            if collectionView.contentInset.top != configuration.topOverlap {
                collectionView.contentInset.top = configuration.topOverlap
            }
            if collectionView.contentInset.bottom != configuration.bottomOverlap {
                collectionView.contentInset.bottom = configuration.bottomOverlap
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

            currentIDs = applyPlan.nextIDs
            currentItemByID = applyPlan.nextItemByID

            TimelineSnapshotApplier.applySnapshot(
                dataSource: dataSource,
                nextIDs: applyPlan.nextIDs,
                nextItemByID: applyPlan.nextItemByID,
                previousItemByID: previousItemByID,
                hiddenCount: configuration.hiddenCount,
                previousHiddenCount: previousHiddenCount,
                streamingAssistantID: configuration.streamingAssistantID,
                previousStreamingAssistantID: previousStreamingAssistantID,
                themeID: configuration.themeID,
                previousThemeID: previousThemeID
            )

            previousItemByID = applyPlan.nextItemByID
            previousStreamingAssistantID = configuration.streamingAssistantID
            previousHiddenCount = configuration.hiddenCount
            previousThemeID = configuration.themeID

            // Skip forced layout during streaming — the collection view
            // layouts naturally before the next display cycle, and the only
            // consumer (updateScrollState) is gated off when isBusy. Forcing
            // layout at 30Hz wastes ~1-3ms per tick for no visible effect.
            if !configuration.isBusy {
                let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: applyPlan.nextIDs.count)
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
                        reconfigureToolRow(itemID: itemID, in: collectionView)
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
                reconfigureToolRow(itemID: itemID, in: collectionView)
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
                    guard let apiClient = connection?.apiClient,
                          let workspaceId,
                          !workspaceId.isEmpty else {
                        return
                    }

                    fetchToolOutput = { sessionId, toolCallId in
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
            #else
                guard let apiClient = connection?.apiClient,
                      let workspaceId,
                      !workspaceId.isEmpty else {
                    return
                }

                fetchToolOutput = { sessionId, toolCallId in
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

        func reconfigureItems(_ itemIDs: [String], in collectionView: UICollectionView) {
            TimelineSnapshotApplier.reconfigureItems(
                itemIDs,
                dataSource: dataSource,
                collectionView: collectionView,
                currentIDs: currentIDs
            )
        }

        private func performScroll(
            _ command: ChatTimelineScrollCommand,
            in collectionView: UICollectionView
        ) -> Bool {
            TimelineScrollCoordinator.performScroll(
                command,
                in: collectionView,
                currentIDs: currentIDs
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
