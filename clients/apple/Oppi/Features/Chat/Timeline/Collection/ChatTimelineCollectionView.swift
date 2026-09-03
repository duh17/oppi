import SwiftUI
import UIKit

// swiftlint:disable type_body_length
struct ChatTimelineScrollCommand: Equatable {
    enum Anchor: Equatable {
        case top
        case bottom
        case viewport(relativeY: CGFloat)
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
        let displayRows: [TimelineDisplayRow]
        let workLineByID: [String: QuietTimelineWorkLine]
        /// Full timeline order used for absolute navigation ordinals. This is
        /// separate from `items`, which may only contain the rendered suffix.
        let fullTimelineItemIDs: [String]
        let hiddenCount: Int
        let hasOlderServerPage: Bool
        let renderWindowStep: Int
        let isBusy: Bool
        let showsWorkingIndicator: Bool
        let streamingAssistantID: String?
        let sessionId: String
        let serverId: String?
        let workspaceId: String?
        let agentId: String?
        let agentIcon: IconChoice?
        let routeScope: SessionRouteScope?
        let onFork: (String) -> Void
        let onBackSwipe: () -> Void
        let onQuietWorkLineToggle: (String) -> Void
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
        let extensionWorkingState: ExtensionWorkingState?
        let extensionHiddenThinkingLabel: String?
        let audioPlayer: AudioPlayerService
        let audioLifecycleCoordinator: AudioLifecycleCoordinator?
        let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
        let topOverlap: CGFloat
        let bottomOverlap: CGFloat
        let onVisibleAudioStripItemIDsChange: ((Set<String>) -> Void)?

        init(
            items: [ChatItem],
            displayRows: [TimelineDisplayRow]? = nil,
            workLineByID: [String: QuietTimelineWorkLine] = [:],
            fullTimelineItemIDs: [String]? = nil,
            hiddenCount: Int,
            hasOlderServerPage: Bool = false,
            renderWindowStep: Int,
            isBusy: Bool,
            showsWorkingIndicator: Bool? = nil,
            streamingAssistantID: String?,
            sessionId: String,
            serverId: String? = nil,
            workspaceId: String?,
            agentId: String? = nil,
            agentIcon: IconChoice? = nil,
            routeScope: SessionRouteScope? = nil,
            onFork: @escaping (String) -> Void,
            onBackSwipe: @escaping () -> Void,
            onQuietWorkLineToggle: @escaping (String) -> Void = { _ in },
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
            extensionWorkingState: ExtensionWorkingState? = nil,
            extensionHiddenThinkingLabel: String? = nil,
            audioPlayer: AudioPlayerService,
            audioLifecycleCoordinator: AudioLifecycleCoordinator? = nil,
            reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
            topOverlap: CGFloat = 0,
            bottomOverlap: CGFloat = 0,
            onVisibleAudioStripItemIDsChange: ((Set<String>) -> Void)? = nil
        ) {
            self.items = items
            self.displayRows = displayRows ?? items.map(TimelineDisplayRow.item)
            self.workLineByID = workLineByID
            self.fullTimelineItemIDs = fullTimelineItemIDs ?? items.map(\.id)
            self.hiddenCount = hiddenCount
            self.hasOlderServerPage = hasOlderServerPage
            self.renderWindowStep = renderWindowStep
            self.isBusy = isBusy
            self.showsWorkingIndicator = showsWorkingIndicator ?? isBusy
            self.streamingAssistantID = streamingAssistantID
            self.sessionId = sessionId
            self.serverId = serverId
            self.workspaceId = workspaceId
            self.agentId = agentId
            self.agentIcon = agentIcon
            self.routeScope = routeScope
                ?? workspaceId.map(SessionRouteScope.workspace)
            self.onFork = onFork
            self.onBackSwipe = onBackSwipe
            self.onQuietWorkLineToggle = onQuietWorkLineToggle
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
            self.extensionWorkingState = extensionWorkingState
            self.extensionHiddenThinkingLabel = extensionHiddenThinkingLabel
            self.audioPlayer = audioPlayer
            self.audioLifecycleCoordinator = audioLifecycleCoordinator
            self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
            self.topOverlap = topOverlap
            self.bottomOverlap = bottomOverlap
            self.onVisibleAudioStripItemIDsChange = onVisibleAudioStripItemIDsChange
        }
    }

    let configuration: Configuration

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = AnchoredCollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = UIColor(Color.themeBg)
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        // Keep scrolled transcript text from washing through the navigation
        // title on iOS's Liquid Glass navigation bar. The bottom edge stays
        // soft because the composer glass intentionally lets content breathe.
        collectionView.topEdgeEffect.style = .hard
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.delegate = context.coordinator

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Controller.handleTimelineTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(tapGesture)
        // The timeline is a UIKit scroll view, so the shared back-swipe
        // recognizer must live here instead of on the SwiftUI parent.
        context.coordinator.installBackSwipeGesture(on: collectionView)

        collectionView.accessibilityIdentifier = "chat.timeline"
        collectionView.contentInset.top = configuration.topOverlap
        collectionView.contentInset.bottom = configuration.bottomOverlap
        context.coordinator.attachHardwareKeybindingResponder(to: collectionView)
        context.coordinator.configureDataSource(collectionView: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.apply(configuration: configuration, to: collectionView)
    }

    static func dismantleUIView(_ collectionView: UICollectionView, coordinator: Controller) {
        coordinator.stopMarkdownVideoPlayback(in: collectionView)
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
        var hasOlderServerPage = false
        var workLineByID: [String: QuietTimelineWorkLine] = [:]
        var renderWindowStep = 0
        var streamingAssistantID: String?
        var audioPlayer: AudioPlayerService?
        var audioLifecycleCoordinator: AudioLifecycleCoordinator? {
            get { context.audioLifecycleCoordinator }
            set { context.audioLifecycleCoordinator = newValue }
        }
        weak var collectionView: UICollectionView?
        var hardwareKeybindingResponder: HardwareKeybindingResponder?
        private var backSwipeGestureInstaller: HorizontalBackSwipeGestureInstaller?
        var onBackSwipe: (() -> Void)?
        var onVisibleAudioStripItemIDsChange: ((Set<String>) -> Void)?
        var timelineTopOverlap: CGFloat = 0
        var timelineBottomOverlap: CGFloat = 0
        private var lastPublishedVisibleAudioStripItemIDs = Set<String>()

        override init() {
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleThemeDidChange),
                name: .oppiThemeDidChange,
                object: nil
            )
        }

        var sessionId: String {
            get { context.sessionId }
            set { context.sessionId = newValue }
        }

        var serverId: String? { context.serverId }

        var workspaceId: String? {
            get { context.workspaceId }
            set { context.workspaceId = newValue }
        }

        var agentId: String? { context.agentId }
        var agentIcon: IconChoice? { context.agentIcon }

        var routeScope: SessionRouteScope? {
            get { context.routeScope }
            set { context.routeScope = newValue }
        }

        var onFork: ((String) -> Void)? {
            get { context.onFork }
            set { context.onFork = newValue }
        }

        func installBackSwipeGesture(on collectionView: UICollectionView) {
            let installer = HorizontalBackSwipeGestureInstaller(
                onBack: { [weak self] in
                    self?.onBackSwipe?()
                },
                shouldReceiveTouch: { [weak self] touch in
                    self?.shouldReceiveTimelineGestureTouch(touch) ?? true
                }
            )
            installer.install(on: collectionView)
            backSwipeGestureInstaller = installer
        }

        var onShowEarlier: (() -> Void)? {
            get { context.onShowEarlier }
            set { context.onShowEarlier = newValue }
        }

        var onQuietWorkLineToggle: ((String) -> Void)? {
            get { context.onQuietWorkLineToggle }
            set { context.onQuietWorkLineToggle = newValue }
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

        var currentExtensionWorkingState: ExtensionWorkingState? {
            get { context.extensionWorkingState }
            set { context.extensionWorkingState = newValue }
        }

        var currentExtensionHiddenThinkingLabel: String? {
            get { context.extensionHiddenThinkingLabel }
            set { context.extensionHiddenThinkingLabel = newValue }
        }

        var interactionContext: TimelineInteractionContext {
            context.interactionContext
        }

        /// Follow only at the true live tail. Any larger gap is detached
        /// reading, including a tall just-sent user message.
        let nearBottomEnterThreshold: CGFloat = 32
        let nearBottomExitThreshold: CGFloat = 32
        let detachedProgrammaticArmMinDelta: CGFloat = 120
        let detachedProgrammaticCorrectionMaxDelta: CGFloat = 100

        var currentIDs: [String] = []

        func fullTimelineItemID(forRenderedID id: String) -> String? {
            if currentFullTimelineItemIDs.contains(id) {
                return id
            }
            return currentWorkLineByID[id]?.sourceItemIDs.first
        }

        /// Resolve a full ChatItem identity into the currently rendered row.
        /// A collapsed source item is represented by its synthetic work line;
        /// expanded items retain their own identity.
        func renderedID(forFullTimelineItemID id: String) -> String? {
            if currentIDs.contains(id) {
                return id
            }
            if let workLine = currentWorkLineByID[id], currentIDs.contains(workLine.id) {
                return workLine.id
            }
            if let renderedWorkLine = currentWorkLineByID.values.first(where: {
                $0.sourceItemIDs.contains(id) && currentIDs.contains($0.id)
            }) {
                return renderedWorkLine.id
            }
            // A Quiet toggle or older-page prepend can replace a synthetic
            // row while the detached capture still holds its prior ID. Bridge
            // overlapping source membership to the replacement presentation
            // row first; synthetic rows remain derived from ChatItem identity.
            if let replacementID = workLineReplacementIDByPreviousID[id],
               currentIDs.contains(replacementID) {
                return replacementID
            }
            if let previousWorkLine = previousWorkLineByID[id],
               let sourceID = previousWorkLine.sourceItemIDs.first(where: currentIDs.contains) {
                return sourceID
            }
            return nil
        }

        func resolvedScrollCommand(_ command: ChatTimelineScrollCommand) -> ChatTimelineScrollCommand? {
            guard let renderedID = renderedID(forFullTimelineItemID: command.id) else {
                return nil
            }
            guard renderedID != command.id else { return command }
            return ChatTimelineScrollCommand(
                id: renderedID,
                anchor: command.anchor,
                animated: command.animated,
                nonce: command.nonce
            )
        }

        /// Complete stable timeline order, including rows outside the rendered
        /// suffix window. Viewport fallback ordinals must use this coordinate space.
        private(set) var currentFullTimelineItemIDs: [String] = []
        var currentItemByID: [String: ChatItem] = [:]
        var currentWorkLineByID: [String: QuietTimelineWorkLine] = [:]
        private var previousWorkLineByID: [String: QuietTimelineWorkLine] = [:]
        private var workLineReplacementIDByPreviousID: [String: String] = [:]
        private var previousItemByID: [String: ChatItem] = [:]
        private var previousStreamingAssistantID: String?
        private var previousHiddenCount = 0
        private var previousHasOlderServerPage = false
        private var previousItemCount = 0
        private var previousShowsWorkingIndicator = false
        private var previousExtensionWorkingState: ExtensionWorkingState?
        private var previousHiddenThinkingLabel: String?
        private var previousThemeID: ThemeID?
        private var lastHandledScrollCommandNonce = 0
        var lastObservedContentOffsetY: CGFloat?
        var lastObservedContentHeight: CGFloat?
        var detachedProgrammaticTargetOffsetY: CGFloat?
        var isApplyingDetachedProgrammaticCorrection = false
        var isTimelineBusy = false
        /// Rendering/sizing must stop treating an assistant as streaming as soon
        /// as execution becomes idle, even if the reducer retains its final ID
        /// for one more render pass.
        var isAssistantStreamingPresentationActive = false
        var lastDistanceFromBottom: CGFloat = 0
        private var lastBusyAmbientScrollReconcileNs: UInt64 = 0
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
            var _toolOutputRetryDelayForTesting: TimeInterval? {
                get { toolOutputLoader.retryDelayForTesting }
                set { toolOutputLoader.retryDelayForTesting = newValue }
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
                NotificationCenter.default.removeObserver(
                    self,
                    name: .oppiThemeDidChange,
                    object: nil
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
        private func handleThemeDidChange() {
            guard let collectionView else { return }
            let currentThemeID = ThemeRuntimeState.currentThemeID()
            guard previousThemeID != currentThemeID else { return }
            previousThemeID = currentThemeID
            collectionView.backgroundColor = UIColor(Color.themeBg)
            guard !currentIDs.isEmpty else { return }
            reconfigureItems(currentIDs, in: collectionView)
        }

        @objc
        private func handleAudioStateChangeNotification(_ notification: Notification) {
            guard let collectionView else { return }

            let changedIDs = Set(Self.audioStateItemIDs(from: notification.userInfo))
            let targetIDs: [String]
            if changedIDs.isEmpty {
                targetIDs = currentAudioItemIDs()
            } else {
                let correlatedIDs = Set(changedIDs.flatMap { id -> [String] in
                    if let toolID = Self.toolItemID(fromAudioPlaybackItemID: id) {
                        return [id, toolID]
                    }
                    return [id]
                })
                targetIDs = currentIDs.filter { correlatedIDs.contains($0) && isAudioStateReactiveItem(id: $0) }
            }

            guard !targetIDs.isEmpty else { return }

            #if DEBUG
                _audioStateRefreshCountForTesting += 1
                _audioStateRefreshedItemIDsForTesting = targetIDs
            #endif
            reconfigureItems(targetIDs, in: collectionView)
        }

        private func currentAudioItemIDs() -> [String] {
            currentIDs.filter { isAudioStateReactiveItem(id: $0) }
        }

        private func isAudioStateReactiveItem(id: String) -> Bool {
            guard let item = currentItemByID[id] else { return false }
            switch item {
            case .audioClip, .toolCall:
                return true
            case .assistantMessage, .cacheMiss, .customEvent, .error, .systemEvent, .thinking, .userMessage:
                return false
            }
        }

        private static func toolItemID(fromAudioPlaybackItemID id: String) -> String? {
            let prefix = "audio-stream-"
            guard id.hasPrefix(prefix) else { return nil }
            return String(id.dropFirst(prefix.count))
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
            let agentPresentationChanged = context.didChangeAgentPresentation(for: configuration)

            hiddenCount = configuration.hiddenCount
            hasOlderServerPage = configuration.hasOlderServerPage
            workLineReplacementIDByPreviousID = Dictionary(uniqueKeysWithValues:
                previousWorkLineByID.compactMap { previousID, previousLine in
                    guard configuration.workLineByID[previousID] == nil else { return nil }
                    let previousSourceIDs = Set(previousLine.sourceItemIDs)
                    guard let replacement = configuration.workLineByID.values.first(where: {
                        $0.sourceItemIDs.contains(where: previousSourceIDs.contains)
                    }) else {
                        return nil
                    }
                    return (previousID, replacement.id)
                }
            )
            workLineByID = configuration.workLineByID
            currentWorkLineByID = configuration.workLineByID
            renderWindowStep = configuration.renderWindowStep
            streamingAssistantID = configuration.streamingAssistantID
            let timelineBusyChanged = configuration.isBusy != isTimelineBusy
            isAssistantStreamingPresentationActive = configuration.isBusy
            // Note: isTimelineBusy is updated AFTER the structurallyUnchanged
            // check so the comparison detects busy→idle transitions.

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
            refreshHardwareKeybindingResponder()
            currentFullTimelineItemIDs = configuration.fullTimelineItemIDs
            scrollController?.updateTimelineItemOrder(configuration.fullTimelineItemIDs)
            onBackSwipe = configuration.onBackSwipe
            onVisibleAudioStripItemIDsChange = configuration.onVisibleAudioStripItemIDsChange
            timelineTopOverlap = configuration.topOverlap
            timelineBottomOverlap = configuration.bottomOverlap
            bindAudioStateObservationIfNeeded(audioPlayer: configuration.audioPlayer)

            // Detect theme change from runtime state instead of threaded param.
            let currentThemeID = ThemeRuntimeState.currentThemeID()
            let themeChanged = previousThemeID != currentThemeID || previousThemeID == nil
            // Row configuration also depends on session/workspace-scoped
            // closures such as attachment fetchers. Reconfigure visible rows
            // when that scope appears or changes, even if ChatItem values are
            // identical, so expanded media retries with the current workspace.
            let globalAppearanceChanged = themeChanged || sessionScopeChanged
            let appearanceChanged = globalAppearanceChanged || agentPresentationChanged

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
                    TimelineOffsetController.apply(
                        targetOffsetY: collectionView.contentOffset.y + delta,
                        reason: .bottomInsetGrowth,
                        collectionView: collectionView,
                        scrollController: scrollController
                    )
                }
            }

            // Streaming fast path: when the rendered row list is structurally
            // unchanged, skip the full plan build. Quiet mode folds tools into
            // synthetic work lines, so ChatItem count alone is not the structure
            // — a new live strip can appear while items.count stays put.
            let previousDisplayIDs = currentIDs.filter {
                $0 != ChatTimelineCollectionHost.loadMoreID
                    && $0 != ChatTimelineCollectionHost.workingIndicatorID
            }
            let nextDisplayIDs = configuration.displayRows.map(\.id)
            let structurallyUnchanged = nextDisplayIDs == previousDisplayIDs
                && configuration.streamingAssistantID == previousStreamingAssistantID
                && configuration.isBusy == isTimelineBusy
                && configuration.showsWorkingIndicator == previousShowsWorkingIndicator
                && configuration.hiddenCount == previousHiddenCount
                && configuration.hasOlderServerPage == previousHasOlderServerPage
                && configuration.workLineByID == previousWorkLineByID
                && !appearanceChanged
                && configuration.extensionWorkingState == previousExtensionWorkingState
                && configuration.extensionHiddenThinkingLabel == previousHiddenThinkingLabel

            if structurallyUnchanged,
               let streamingID = configuration.streamingAssistantID,
               let nextItem = configuration.items.last(where: { $0.id == streamingID }),
               let prevItem = currentItemByID[streamingID],
               prevItem != nextItem,
               let dataSource {
                // Lightweight streaming reconfigure: skip the full plan build
                // (O(n) dedup + Set construction) but still go through
                // dataSource.apply() so UIKit handles cell self-sizing.
                // Raw cell.contentConfiguration bypasses the compositional
                // layout's preferredLayoutAttributesFitting — the cell stays
                // its old height and clips growing text.

                // Update the streaming item map entry.
                currentItemByID[streamingID] = nextItem

                // Also detect changed mutable items (in-flight tools, active
                // thinking rows) alongside the streaming assistant. Check both
                // the previous AND current item for mutability — a tool going
                // from isDone:false to isDone:true needs reconfiguration even
                // though the NEW item is no longer "mutable".
                var reconfigureIDs = [streamingID]
                for item in configuration.items {
                    let id = item.id
                    guard id != streamingID else { continue }
                    let prevItem = currentItemByID[id]
                    guard TimelineSnapshotApplier.isStreamingMutableItem(item)
                        || TimelineSnapshotApplier.isStreamingMutableItem(prevItem) else {
                        continue
                    }
                    if let prev = prevItem, prev != item {
                        currentItemByID[id] = item
                        previousItemByID[id] = item
                        reconfigureIDs.append(id)
                    }
                }

                ChatTimelinePerf.beginTimelineApplyCycle(
                    itemCount: currentIDs.count,
                    changedCount: reconfigureIDs.count
                )
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(reconfigureIDs)
                let applyToken = ChatTimelinePerf.beginCollectionApply(
                    itemCount: currentIDs.count,
                    changedCount: reconfigureIDs.count,
                    sessionId: configuration.sessionId
                )
                dataSource.apply(snapshot, animatingDifferences: false)
                ChatTimelinePerf.endCollectionApply(applyToken)

                previousStreamingAssistantID = configuration.streamingAssistantID
                previousWorkLineByID = configuration.workLineByID
                previousHiddenCount = configuration.hiddenCount
                previousHasOlderServerPage = configuration.hasOlderServerPage
                previousItemCount = configuration.items.count
                previousThemeID = currentThemeID
                previousShowsWorkingIndicator = configuration.showsWorkingIndicator
                previousExtensionWorkingState = configuration.extensionWorkingState
                previousHiddenThinkingLabel = configuration.extensionHiddenThinkingLabel
                isTimelineBusy = configuration.isBusy

                let hadPendingScrollCommand = isPendingScrollCommand(configuration.scrollCommand)
                let didScroll = performPendingScrollCommandIfNeeded(
                    configuration.scrollCommand,
                    in: collectionView
                )
                if !didScroll,
                   !hadPendingScrollCommand,
                   configuration.scrollCommand?.anchor != .top {
                    reconcileAmbientScrollAfterTimelineUpdate(
                        collectionView,
                        isBusy: configuration.isBusy,
                        itemCount: currentIDs.count,
                        sessionId: configuration.sessionId
                    )
                }
                ChatTimelinePerf.endTimelineApplyCycle(didScroll: didScroll)
                updateDetachedStreamingHintVisibility()
                return
            }

            // No-op fast path: streaming, structurally unchanged, content
            // identical for the assistant AND all mutable items.
            if structurallyUnchanged,
               let streamingID = configuration.streamingAssistantID,
               let nextItem = configuration.items.last(where: { $0.id == streamingID }),
               let prevItem = currentItemByID[streamingID],
               prevItem == nextItem {
                // Even when the assistant is unchanged, mutable items (tools,
                // thinking) may have changed. Scan for them before declaring
                // this a true no-op.
                var mutableChanged = false
                for item in configuration.items {
                    let id = item.id
                    guard id != streamingID else { continue }
                    let prev = currentItemByID[id]
                    guard TimelineSnapshotApplier.isStreamingMutableItem(item)
                        || TimelineSnapshotApplier.isStreamingMutableItem(prev) else {
                        continue
                    }
                    if prev != item {
                        mutableChanged = true
                        break
                    }
                }
                if !mutableChanged {
                    ChatTimelinePerf.beginTimelineApplyCycle(
                        itemCount: currentIDs.count,
                        changedCount: 0
                    )
                    previousStreamingAssistantID = configuration.streamingAssistantID
                    previousHiddenCount = configuration.hiddenCount
                previousHasOlderServerPage = configuration.hasOlderServerPage
                    previousItemCount = configuration.items.count
                    previousThemeID = currentThemeID
                    previousShowsWorkingIndicator = configuration.showsWorkingIndicator
                    previousExtensionWorkingState = configuration.extensionWorkingState
                    previousHiddenThinkingLabel = configuration.extensionHiddenThinkingLabel
                    isTimelineBusy = configuration.isBusy
                    ChatTimelinePerf.endTimelineApplyCycle(didScroll: false)
                    updateDetachedStreamingHintVisibility()
                    return
                }
                // Mutable items changed — fall through to mutable-only reconfigure.
                var reconfigureIDs: [String] = []
                for item in configuration.items {
                    let id = item.id
                    guard id != streamingID else { continue }
                    let prev = currentItemByID[id]
                    guard TimelineSnapshotApplier.isStreamingMutableItem(item)
                        || TimelineSnapshotApplier.isStreamingMutableItem(prev) else {
                        continue
                    }
                    if let prev, prev != item {
                        currentItemByID[id] = item
                        previousItemByID[id] = item
                        reconfigureIDs.append(id)
                    }
                }
                if !reconfigureIDs.isEmpty, let dataSource {
                    ChatTimelinePerf.beginTimelineApplyCycle(
                        itemCount: currentIDs.count,
                        changedCount: reconfigureIDs.count
                    )
                    var snapshot = dataSource.snapshot()
                    snapshot.reconfigureItems(reconfigureIDs)
                    let applyToken = ChatTimelinePerf.beginCollectionApply(
                        itemCount: currentIDs.count,
                        changedCount: reconfigureIDs.count,
                        sessionId: configuration.sessionId
                    )
                    dataSource.apply(snapshot, animatingDifferences: false)
                    ChatTimelinePerf.endCollectionApply(applyToken)
                }
                previousStreamingAssistantID = configuration.streamingAssistantID
                previousWorkLineByID = configuration.workLineByID
                previousHiddenCount = configuration.hiddenCount
                previousHasOlderServerPage = configuration.hasOlderServerPage
                previousItemCount = configuration.items.count
                previousThemeID = currentThemeID
                previousShowsWorkingIndicator = configuration.showsWorkingIndicator
                previousExtensionWorkingState = configuration.extensionWorkingState
                previousHiddenThinkingLabel = configuration.extensionHiddenThinkingLabel
                isTimelineBusy = configuration.isBusy

                let hadPendingScrollCommand = isPendingScrollCommand(configuration.scrollCommand)
                let didScroll = performPendingScrollCommandIfNeeded(
                    configuration.scrollCommand,
                    in: collectionView
                )
                if !didScroll,
                   !hadPendingScrollCommand,
                   configuration.scrollCommand?.anchor != .top {
                    reconcileAmbientScrollAfterTimelineUpdate(
                        collectionView,
                        isBusy: configuration.isBusy,
                        itemCount: currentIDs.count,
                        sessionId: configuration.sessionId
                    )
                }
                ChatTimelinePerf.endTimelineApplyCycle(didScroll: didScroll)
                updateDetachedStreamingHintVisibility()
                return
            }

            let applyPlan = ChatTimelineApplyPlan.build(
                rows: configuration.displayRows,
                hiddenCount: configuration.hiddenCount,
                hasOlderServerPage: configuration.hasOlderServerPage,
                isBusy: configuration.isBusy,
                showsWorkingIndicator: configuration.showsWorkingIndicator,
                streamingAssistantID: configuration.streamingAssistantID
            ).withRemovedIDs(from: currentIDs)

            if !applyPlan.removedIDs.isEmpty {
                cancelToolOutputLoadTasks(for: applyPlan.removedIDs)
            }

            // Capture identity against the current layout / currentIDs before
            // the rendered suffix is replaced. A later window shift can move
            // the same item to a new index path. Skip when a viewport jump is
            // pending: the identity pin would fight relative-Y restoration.
            if let anchoredCV = collectionView as? AnchoredCollectionView {
                let detached = !(scrollController?.isCurrentlyNearBottom ?? true)
                anchoredCV.isDetachedFromBottom = detached
                let pendingViewportRestore: Bool = {
                    guard case .viewport = configuration.scrollCommand?.anchor else {
                        return false
                    }
                    return isPendingScrollCommand(configuration.scrollCommand)
                }()
                if pendingViewportRestore {
                    anchoredCV.clearDetachedAnchor()
                } else if detached {
                    anchoredCV.captureDetachedAnchor()
                    anchoredCV.remapDetachedAnchorItemID(
                        using: workLineReplacementIDByPreviousID
                    )
                }
            }

            let previousIDs = currentIDs
            currentIDs = applyPlan.nextIDs
            currentItemByID = applyPlan.nextItemByID

            var forceReconfigureIDs: [String] = []
            if agentPresentationChanged {
                forceReconfigureIDs.append(contentsOf:
                    TimelineSnapshotApplier.assistantPresentationItemIDs(
                        nextIDs: applyPlan.nextIDs,
                        nextItemByID: applyPlan.nextItemByID
                    )
                )
            }
            if timelineBusyChanged,
               let finalAssistantID = configuration.streamingAssistantID ?? previousStreamingAssistantID {
                // Completion can arrive before the reducer clears its streaming
                // ID. Reconfigure anyway so SafeSizingCell drops its monotonic
                // streaming-height cache and the final markdown gets a settled
                // non-streaming layout instead of retaining a blank tail.
                forceReconfigureIDs.append(finalAssistantID)
            }
            if configuration.showsWorkingIndicator,
               configuration.extensionWorkingState != previousExtensionWorkingState {
                forceReconfigureIDs.append(ChatTimelineCollectionHost.workingIndicatorID)
            }
            forceReconfigureIDs.append(
                contentsOf: ChatTimelineApplyPlan.workLineReconfigureIDs(
                    previous: previousWorkLineByID,
                    next: configuration.workLineByID
                )
            )
            if configuration.extensionHiddenThinkingLabel != previousHiddenThinkingLabel {
                forceReconfigureIDs.append(contentsOf: applyPlan.nextIDs.filter { id in
                    if case .thinking = applyPlan.nextItemByID[id] {
                        return true
                    }
                    return false
                })
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
                themeChanged: globalAppearanceChanged,
                isBusy: configuration.isBusy,
                forceReconfigureIDs: forceReconfigureIDs
            )

            previousItemByID = applyPlan.nextItemByID
            previousWorkLineByID = applyPlan.nextWorkLineByID
            previousStreamingAssistantID = configuration.streamingAssistantID
            previousHiddenCount = configuration.hiddenCount
                previousHasOlderServerPage = configuration.hasOlderServerPage
            previousItemCount = configuration.items.count
            previousThemeID = currentThemeID
            previousShowsWorkingIndicator = configuration.showsWorkingIndicator
            previousExtensionWorkingState = configuration.extensionWorkingState
            previousHiddenThinkingLabel = configuration.extensionHiddenThinkingLabel
            isTimelineBusy = configuration.isBusy

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

            // When detached, force layout immediately after snapshot apply to
            // let AnchoredCollectionView restore the captured anchor and resolve
            // pending self-sizing in one pass. When attached, the ambient tail
            // governor/idle settle below owns the layout pass and applies only
            // the movement it needs.
            let detached = !(scrollController?.isCurrentlyNearBottom ?? true)
            if detached {
                let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: applyPlan.nextIDs.count, sessionId: configuration.sessionId)
                collectionView.layoutIfNeeded()
                if !workLineReplacementIDByPreviousID.isEmpty,
                   let anchoredCollectionView = collectionView as? AnchoredCollectionView {
                    anchoredCollectionView.restoreRemappedDetachedAnchorPosition()
                    DispatchQueue.main.async { [weak anchoredCollectionView] in
                        anchoredCollectionView?.layoutIfNeeded()
                        anchoredCollectionView?.restoreRemappedDetachedAnchorPosition()
                    }
                }
                ChatTimelinePerf.endLayoutPass(layoutToken)
            }
            let hadPendingScrollCommand = isPendingScrollCommand(configuration.scrollCommand)
            let didScroll = performPendingScrollCommandIfNeeded(
                configuration.scrollCommand,
                in: collectionView
            )
            if !didScroll,
               !hadPendingScrollCommand,
               configuration.scrollCommand?.anchor != .top {
                reconcileAmbientScrollAfterTimelineUpdate(
                    collectionView,
                    isBusy: configuration.isBusy,
                    itemCount: applyPlan.nextIDs.count,
                    sessionId: configuration.sessionId,
                    structuralAppend: applyPlan.nextIDs.count > previousIDs.count
                )
            }

            // When the session is busy (streaming or running tools), ambient
            // follow is handled by the tail governor and user-initiated scroll
            // changes are detected via scrollViewDidScroll delegate callbacks.
            // Suppress updateScrollState here so passive layout growth cannot
            // false-detach the user from attached follow.
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
            publishVisibleAudioStripItemIDs(in: collectionView)
            ChatTimelinePerf.endTimelineApplyCycle(didScroll: didScroll)
        }

        func publishVisibleAudioStripItemIDs(in collectionView: UICollectionView) {
            let unobstructed = collectionView.bounds.inset(
                by: UIEdgeInsets(
                    top: timelineTopOverlap,
                    left: 0,
                    bottom: timelineBottomOverlap,
                    right: 0
                )
            )
            let ids = InAppNowPlayingChrome.visibleStripItemIDs(
                in: collectionView,
                unobstructedRect: unobstructed
            )
            guard ids != lastPublishedVisibleAudioStripItemIDs else { return }
            lastPublishedVisibleAudioStripItemIDs = ids
            let callback = onVisibleAudioStripItemIDsChange
            DispatchQueue.main.async {
                callback?(ids)
            }
        }

        // MARK: - UICollectionViewDelegate

        @objc func handleTimelineTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            gesture.view?.window?.endEditing(true)
            claimHardwareKeybindingFocusIfNeeded()
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            Self.shouldReceiveTimelineGestureTouch(from: touch.view)
        }

        // The timeline tap only dismisses the keyboard. It must yield to any
        // interactive control so a control tap is owned by that control alone.
        static func shouldReceiveTimelineGestureTouch(from view: UIView?) -> Bool {
            var current = view
            while let candidate = current {
                if candidate is UIControl { return false }
                if let textView = candidate as? UITextView, textView.isSelectable { return false }
                current = candidate.superview
            }
            return true
        }

        private func shouldReceiveTimelineGestureTouch(_ touch: UITouch) -> Bool {
            Self.shouldReceiveTimelineGestureTouch(from: touch.view)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            Self.firstSubview(
                ofType: AssistantTimelineRowContentView.self,
                in: cell.contentView
            )?.setMarkdownVideoPlaybackVisible(true)
            publishVisibleAudioStripItemIDs(in: collectionView)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didEndDisplaying cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            Self.firstSubview(
                ofType: AssistantTimelineRowContentView.self,
                in: cell.contentView
            )?.setMarkdownVideoPlaybackVisible(false)
            publishVisibleAudioStripItemIDs(in: collectionView)
        }

        func stopMarkdownVideoPlayback(in collectionView: UICollectionView) {
            for cell in collectionView.visibleCells {
                Self.firstSubview(
                    ofType: AssistantTimelineRowContentView.self,
                    in: cell.contentView
                )?.prepareMarkdownVideosForRemoval()
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            shouldSelectItemAt indexPath: IndexPath
        ) -> Bool {
            guard indexPath.section == 0, indexPath.item < currentIDs.count else { return false }
            // Full-row UIButtons own their actions. Collection selection must
            // not become a second owner or a sticky highlight.
            let itemID = currentIDs[indexPath.item]
            return itemID != ChatTimelineCollectionHost.loadMoreID
                && currentWorkLineByID[itemID] == nil
        }

        func toggleQuietWorkLine(
            _ workLine: QuietTimelineWorkLine,
            in collectionView: UICollectionView,
            indexPath: IndexPath? = nil
        ) {
            guard let indexPath = indexPath
                ?? currentIDs.firstIndex(of: workLine.id).map({ IndexPath(item: $0, section: 0) }) else {
                return
            }

            AppHaptics.toolbarExpansion()
            let anchoredCollectionView = collectionView as? AnchoredCollectionView
            anchoredCollectionView?.setExpandCollapseAnchor(indexPath: indexPath)
            onQuietWorkLineToggle?(workLine.turnID)
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                self.reconfigureItems(
                    [workLine.id] + workLine.sourceItemIDs,
                    in: collectionView
                )
                // Keep the identity anchor through the snapshot apply and the
                // following layout pass. The second hop covers deferred
                // self-sizing invalidations without allowing idle tail settle
                // to reclaim the viewport in between.
                DispatchQueue.main.async {
                    DispatchQueue.main.async { [weak anchoredCollectionView] in
                        anchoredCollectionView?.clearExpandCollapseAnchor()
                    }
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.section == 0, indexPath.item < currentIDs.count else { return }
            let itemID = currentIDs[indexPath.item]
            if itemID == ChatTimelineCollectionHost.loadMoreID
                || currentWorkLineByID[itemID] != nil {
                collectionView.deselectItem(at: indexPath, animated: false)
                return
            }
            if itemID == ChatTimelineCollectionHost.workingIndicatorID {
                return
            }

            collectionView.deselectItem(at: indexPath, animated: false)

            guard let item = currentItemByID[itemID],
                  let reducer else {
                return
            }

            switch item {
            case .toolCall(_, let tool, _, _, let outputByteCount, _, _):
                if ToolCallFormatting.normalized(tool) == "ask" {
                    return
                }

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
                            in: collectionView,
                            preserveTopEdge: true
                        )
                    }
                    return
                }

                // Do not gate on current cell.contentConfiguration type.
                // During high-frequency streaming updates the visible cell can be
                // transiently reconfigured while still representing the same
                // tool item, and strict type checks can drop taps.
                let wasExpanded = reducer.expandedItemIDs.contains(itemID)
                AppHaptics.toolbarExpansion()
                if wasExpanded {
                    reducer.expandedItemIDs.remove(itemID)
                    cancelToolOutputRetryWork(for: itemID)
                    cancelToolOutputLoadTasks(for: [itemID])
                } else {
                    reducer.expandedItemIDs.insert(itemID)
                    FeatureEducationTips.markToolDetailsOpened()
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
                    in: collectionView,
                    preserveTopEdge: true
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

            case .cacheMiss, .customEvent:
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

        static func firstSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
            if let match = root as? T { return match }
            for child in root.subviews {
                if let match = firstSubview(ofType: type, in: child) {
                    return match
                }
            }
            return nil
        }

        // MARK: - Tool Output Loading

        func ensureExpandedToolOutputLoaded(
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
                  let routeScope else {
                return nil
            }

            return { sessionId, toolCallId in
                let isShellTool = ToolCallFormatting.isBashTool(tool)
                    || ToolCallFormatting.isGrepTool(tool)
                    || ToolCallFormatting.isFindTool(tool)
                    || ToolCallFormatting.isLsTool(tool)

                if isShellTool,
                   let fullOutput = try await apiClient.getNonEmptyFullToolOutput(
                       scope: routeScope,
                       sessionId: sessionId,
                       toolCallId: toolCallId
                   ) {
                    return fullOutput
                }

                return try await apiClient.getNonEmptyToolOutput(
                    scope: routeScope,
                    sessionId: sessionId,
                    toolCallId: toolCallId
                ) ?? ""
            }
        }

        func cancelToolOutputRetryWork(for itemID: String) {
            toolOutputLoader.cancelRetryWork(for: itemID)
        }

        func cancelToolOutputLoadTasks(for itemIDs: Set<String>) {
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
        func anchoredReconfigureToolRow(
            itemID: String,
            anchorIndexPath: IndexPath,
            in collectionView: UICollectionView,
            preserveTopEdge: Bool = true
        ) {
            let anchoredCV = collectionView as? AnchoredCollectionView

            // Keep the tapped row header stable so expansion grows downward
            // from the user's tap point and collapse leaves the same header
            // available for an immediate second tap.
            let anchorScreenYBefore: CGFloat?
            if let attrs = collectionView.layoutAttributesForItem(at: anchorIndexPath) {
                anchorScreenYBefore = (preserveTopEdge ? attrs.frame.minY : attrs.frame.maxY)
                    - collectionView.contentOffset.y
            } else {
                anchorScreenYBefore = nil
            }

            reconfigureToolRow(itemID: itemID, in: collectionView)

            // Temporarily disable AnchoredCollectionView's own anchoring
            // during the forced layout. Without this, the anchoring captures
            // the old offset before our explicit correction and the self-sizing
            // cascade can try to maintain that stale state.
            let savedDetached = anchoredCV?.isDetachedFromBottom ?? false
            anchoredCV?.isDetachedFromBottom = false
            anchoredCV?.clearDetachedAnchor()

            // Force layout to settle the new cell size before computing the
            // absolute offset that preserves the chosen edge.
            let offsetBeforeLayout = collectionView.contentOffset.y
            collectionView.layoutIfNeeded()

            // Restore the detached flag after the forced layout.
            anchoredCV?.isDetachedFromBottom = savedDetached

            // Compute the absolute target offset that keeps the chosen edge
            // at the same screen position as before the reconfigure.
            if let anchorScreenYBefore,
               let newAttrs = collectionView.layoutAttributesForItem(at: anchorIndexPath) {
                // Target: newAnchorY - targetOffset = savedAnchorScreenY
                //   => targetOffset = newAnchorY - savedAnchorScreenY
                let newAnchorY = preserveTopEdge ? newAttrs.frame.minY : newAttrs.frame.maxY
                let targetOffset = newAnchorY - anchorScreenYBefore

                TimelineOffsetController.apply(
                    targetOffsetY: targetOffset,
                    reason: .expandCollapse(edge: preserveTopEdge ? .top : .bottom),
                    collectionView: collectionView,
                    scrollController: scrollController
                )
            } else if abs(collectionView.contentOffset.y - offsetBeforeLayout) > 0.5 {
                // No attrs but layout shifted the offset — restore.
                TimelineOffsetController.apply(
                    targetOffsetY: offsetBeforeLayout,
                    reason: .expandCollapse(edge: preserveTopEdge ? .top : .bottom),
                    collectionView: collectionView,
                    scrollController: scrollController
                )
            }

            // Sync the detached flag on the AnchoredCollectionView so the
            // detached anchor system provides ongoing protection after the
            // expand/collapse anchor clears.
            let isDetached = !(scrollController?.isCurrentlyNearBottom ?? true)
            anchoredCV?.isDetachedFromBottom = isDetached

            // Set the expand/collapse anchor for the deferred async
            // layout passes (invalidateEnclosingCollectionViewLayout,
            // self-sizing cascades), then clear and hand off to the
            // detached anchor for ongoing protection.
            anchoredCV?.setExpandCollapseAnchor(indexPath: anchorIndexPath)
            DispatchQueue.main.async { [weak anchoredCV, isDetached] in
                DispatchQueue.main.async { [weak anchoredCV, isDetached] in
                    anchoredCV?.clearExpandCollapseAnchor()
                    // Re-capture the detached anchor at the settled position
                    // so the detached system takes over from the expand/collapse
                    // anchor seamlessly.
                    if isDetached {
                        anchoredCV?.captureDetachedAnchor()
                    }
                }
            }
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

        private let liveTailMinimumBottomPadding: CGFloat = 16

        private func isPendingScrollCommand(
            _ scrollCommand: ChatTimelineScrollCommand?
        ) -> Bool {
            guard let scrollCommand else { return false }
            return scrollCommand.nonce != lastHandledScrollCommandNonce
        }

        private func performPendingScrollCommandIfNeeded(
            _ scrollCommand: ChatTimelineScrollCommand?,
            in collectionView: UICollectionView
        ) -> Bool {
            guard let scrollCommand,
                  scrollCommand.nonce != lastHandledScrollCommandNonce,
                  let resolvedCommand = resolvedScrollCommand(scrollCommand) else {
                return false
            }
            if let anchoredCV = collectionView as? AnchoredCollectionView {
                switch resolvedCommand.anchor {
                case .bottom:
                    anchoredCV.isDetachedFromBottom = false
                    anchoredCV.clearDetachedAnchor()
                case .viewport, .top:
                    // Identity pin would fight the programmatic jump.
                    anchoredCV.clearDetachedAnchor()
                }
            }
            guard performScroll(resolvedCommand, in: collectionView) else {
                return false
            }
            lastHandledScrollCommandNonce = scrollCommand.nonce
            return true
        }

        private func reconcileAmbientScrollAfterTimelineUpdate(
            _ collectionView: UICollectionView,
            isBusy: Bool,
            itemCount: Int,
            sessionId: String,
            structuralAppend: Bool = false
        ) {
            guard scrollController?.isCurrentlyNearBottom ?? true else { return }
            guard !collectionView.isTracking,
                  !collectionView.isDragging,
                  !collectionView.isDecelerating else {
                return
            }
            if #available(iOS 17.4, *), collectionView.isScrollAnimating {
                return
            }
            if (collectionView as? AnchoredCollectionView)?.expandCollapseAnchorIP != nil {
                // The tapped work header owns the viewport until its structural
                // apply and deferred self-sizing passes settle. An idle bottom
                // correction here would yank an older turn back to the tail.
                return
            }

            if isBusy, !structuralAppend {
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastBusyAmbientScrollReconcileNs < 260_000_000 {
                    return
                }
                lastBusyAmbientScrollReconcileNs = now
            }

            let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: itemCount, sessionId: sessionId)
            collectionView.layoutIfNeeded()
            ChatTimelinePerf.endLayoutPass(layoutToken)

            if isBusy, !structuralAppend {
                keepLiveTailVisible(collectionView)
            } else {
                settleAttachedBottom(collectionView)
            }
        }

        private func keepLiveTailVisible(_ collectionView: UICollectionView) {
            guard let tailIndex = currentIDs.indices.last else { return }
            let tailIndexPath = IndexPath(item: tailIndex, section: 0)
            guard let attrs = collectionView.layoutAttributesForItem(at: tailIndexPath) else { return }

            let insets = collectionView.adjustedContentInset
            let viewportBottomY = collectionView.contentOffset.y
                + collectionView.bounds.height
                - insets.bottom
            let distanceFromViewportBottom = viewportBottomY - attrs.frame.maxY

            // Busy streaming uses minimum-needed visibility instead of
            // exact-bottom chasing. If the live tail is visible, do nothing.
            // If it is about to fall behind the composer/footer, nudge downward
            // only enough to restore the minimum padding. Never move upward
            // while busy; final settling happens on idle.
            guard distanceFromViewportBottom < liveTailMinimumBottomPadding else { return }

            let targetOffsetY = collectionView.contentOffset.y
                + (liveTailMinimumBottomPadding - distanceFromViewportBottom)
            applyAmbientOffsetCorrection(
                targetOffsetY,
                reason: .liveTailVisibility,
                in: collectionView
            )
        }

        private func settleAttachedBottom(_ collectionView: UICollectionView) {
            let insets = collectionView.adjustedContentInset
            let targetOffsetY = max(
                -insets.top,
                collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
            )
            applyAmbientOffsetCorrection(
                targetOffsetY,
                reason: .idleBottomSettle,
                in: collectionView
            )
        }

        private func applyAmbientOffsetCorrection(
            _ proposedOffsetY: CGFloat,
            reason: TimelineOffsetReason,
            in collectionView: UICollectionView
        ) {
            let didApply = TimelineOffsetController.apply(
                targetOffsetY: proposedOffsetY,
                reason: reason,
                collectionView: collectionView,
                scrollController: scrollController
            )
            guard didApply else { return }

            scrollController?.updateNearBottom(true)
            updateLastDistanceFromBottom(collectionView)
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
                self.correctProgrammaticScrollAlignmentIfNeeded(command, in: collectionView)
                self.triggerNavigationHighlightIfNeeded(for: command, in: collectionView)
                let preservesDetachedState: Bool
                if case .viewport = command.anchor {
                    // Estimated row heights can temporarily place a restored
                    // viewport inside near-bottom hysteresis. Reattaching here
                    // lets the later self-sizing pass pin to the live tail.
                    preservesDetachedState = true
                } else {
                    preservesDetachedState = false
                }
                self.updateScrollState(
                    collectionView,
                    preserveDetachedState: preservesDetachedState
                )
                self.updateDetachedStreamingHintVisibility()
            }
        }

        private func triggerNavigationHighlightIfNeeded(
            for command: ChatTimelineScrollCommand,
            in collectionView: UICollectionView
        ) {
            guard command.anchor == .top,
                  currentIDs.contains(command.id) else {
                return
            }

            func tryApplyHighlight(attempt: Int) {
                collectionView.layoutIfNeeded()

                if applyPendingNavigationHighlightIfVisible(for: command.id, in: collectionView) {
                    return
                }

                guard attempt < 20 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    tryApplyHighlight(attempt: attempt + 1)
                }
            }

            tryApplyHighlight(attempt: 0)
        }

        @discardableResult
        func applyPendingNavigationHighlightIfVisible(
            for itemID: String,
            in collectionView: UICollectionView
        ) -> Bool {
            guard let scrollController,
                  let token = scrollController.navigationHighlightTokenIfNeeded(for: itemID),
                  let itemIndex = currentIDs.firstIndex(of: itemID) else {
                return false
            }

            let indexPath = IndexPath(item: itemIndex, section: 0)
            guard let cell = collectionView.cellForItem(at: indexPath) as? SafeSizingCell else {
                return false
            }

            cell.performNavigationHighlight(token: token)
            scrollController.clearNavigationHighlightIfNeeded(for: itemID, token: token)

            let refreshZOrder: @MainActor @Sendable () -> Void = { [weak collectionView] in
                guard let collectionView,
                      let cell = collectionView.cellForItem(at: indexPath) as? SafeSizingCell else {
                    return
                }
                cell.ensureNavigationHighlightOverlayFrontmost()
            }

            DispatchQueue.main.async(execute: refreshZOrder)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: refreshZOrder)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: refreshZOrder)
            return true
        }

        private func correctProgrammaticScrollAlignmentIfNeeded(
            _ command: ChatTimelineScrollCommand,
            in collectionView: UICollectionView
        ) {
            let relativeY: CGFloat
            let reason: TimelineOffsetReason
            switch command.anchor {
            case .top:
                relativeY = collectionView.adjustedContentInset.top
                reason = .programmaticTopAlign
            case .viewport(let savedRelativeY):
                relativeY = savedRelativeY
                reason = .navigationViewportRestore
            case .bottom:
                return
            }

            guard let itemIndex = currentIDs.firstIndex(of: command.id) else {
                return
            }

            let indexPath = IndexPath(item: itemIndex, section: 0)
            collectionView.layoutIfNeeded()
            guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else {
                return
            }

            TimelineOffsetController.apply(
                targetOffsetY: attrs.frame.minY - relativeY,
                reason: reason,
                collectionView: collectionView,
                scrollController: scrollController
            )
            if let anchoredCV = collectionView as? AnchoredCollectionView,
               anchoredCV.isDetachedFromBottom {
                anchoredCV.captureDetachedAnchor()
            }
        }

        /// Minimum distance from bottom before showing the jump-to-bottom
        /// button. One viewport height prevents flash from bounce/small scrolls.
        let jumpToBottomMinDistance: CGFloat = 500
    }
}

// swiftlint:enable type_body_length
