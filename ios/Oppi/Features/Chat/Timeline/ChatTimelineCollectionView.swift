import SwiftUI
import UIKit

// MARK: - Safe-sizing cell

/// UICollectionViewCell subclass that bypasses UIKit's content-view size
/// assertion entirely.
///
/// **The problem:** `UICollectionViewCell.systemLayoutSizeFitting` internally
/// calls `systemLayoutSizeFitting` on the *UIContentView*, checks the result,
/// and throws `NSInternalInconsistencyException` if it's non-finite (DBL_MAX).
/// This happens when a content view's constraints are momentarily ambiguous
/// (e.g. during initial cell configuration). Overriding `systemLayoutSizeFitting`
/// on the cell doesn't help because the assertion fires inside UIKit's private
/// code path *before* calling the cell's method.
///
/// **The fix:** Override `preferredLayoutAttributesFittingAttributes:` — the
/// method that UIKit calls to get self-sizing dimensions. This is the CALLER
/// of `systemLayoutSizeFitting`. By overriding it, we compute the size
/// ourselves (via `contentView.systemLayoutSizeFitting`) and clamp the result,
/// completely bypassing the assertion path in `UICollectionViewCell`.
private final class SafeSizingCell: UICollectionViewCell {
    private static let maxValidHeight: CGFloat = 10_000
    private static let fallbackHeight: CGFloat = 44

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes

        let targetSize = CGSize(
            width: attributes.size.width,
            height: UIView.layoutFittingCompressedSize.height
        )

        // Size the cell's contentView directly. This triggers auto layout on
        // all subviews (including the UIContentView) without going through
        // UICollectionViewCell's assertion-guarded systemLayoutSizeFitting.
        let fitted = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        )

        let width = attributes.size.width
        let height: CGFloat
        if fitted.height.isFinite && fitted.height > 0 {
            height = min(fitted.height, Self.maxValidHeight)
        } else {
            height = Self.fallbackHeight
        }

        attributes.size = CGSize(width: width, height: height)
        return attributes
    }
}

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

struct ChatTimelineCollectionView: UIViewRepresentable {
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
        let connection: ServerConnection
        let audioPlayer: AudioPlayerService
        let theme: AppTheme
        let themeID: ThemeID
    }

    let configuration: Configuration

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = UIColor(Color.tokyoBg)
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInset.bottom = 12
        collectionView.delegate = context.coordinator

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTimelineTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(tapGesture)

        context.coordinator.configureDataSource(collectionView: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.apply(configuration: configuration, to: collectionView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private static func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(44)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        return UICollectionViewCompositionalLayout(section: section)
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?

        private var hiddenCount = 0
        private var renderWindowStep = 0
        private var streamingAssistantID: String?
        private var sessionId = ""
        private var workspaceId: String?
        private var onFork: ((String) -> Void)?
        private var onOpenFile: ((FileToOpen) -> Void)?
        private var onShowEarlier: (() -> Void)?

        private weak var scrollController: ChatScrollController?

        private var reducer: TimelineReducer?
        private var toolOutputStore: ToolOutputStore?
        private var toolArgsStore: ToolArgsStore?
        private var connection: ServerConnection?
        private var audioPlayer: AudioPlayerService?
        private weak var collectionView: UICollectionView?
        private var theme: AppTheme = .tokyoNight
        private var currentThemeID: ThemeID = .tokyoNight

        /// Near-bottom hysteresis to avoid follow/unfollow flicker while
        /// streaming text grows the tail between throttled auto-scroll pulses.
        private let nearBottomEnterThreshold: CGFloat = 120
        private let nearBottomExitThreshold: CGFloat = 200

        private var currentIDs: [String] = []
        private var currentItemByID: [String: ChatItem] = [:]
        private var previousItemByID: [String: ChatItem] = [:]
        private var previousStreamingAssistantID: String?
        private var previousHiddenCount = 0
        private var previousThemeID: ThemeID?
        private var lastHandledScrollCommandNonce = 0
        private var lastObservedContentOffsetY: CGFloat?
        private var toolOutputLoadState = ToolOutputLoadState()
        private var pendingToolOutputRetryWorkByID: [String: DispatchWorkItem] = [:]

        private static let toolOutputRetryMaxAttempts = 6
        private static let toolOutputRetryBaseDelay: TimeInterval = 0.45
        private static let toolOutputRetryMaxDelay: TimeInterval = 2.0

        var _fetchToolOutputForTesting: ((_ sessionId: String, _ toolCallId: String) async throws -> String)?
        private(set) var _toolOutputCanceledCountForTesting = 0
        private(set) var _toolOutputStaleDiscardCountForTesting = 0
        private(set) var _toolOutputAppliedCountForTesting = 0
        private(set) var _toolExpansionFallbackCountForTesting = 0
        private(set) var _audioStateRefreshCountForTesting = 0
        private(set) var _audioStateRefreshedItemIDsForTesting: [String] = []

        var _toolOutputLoadTaskCountForTesting: Int {
            toolOutputLoadState.taskCount
        }

        var _loadingToolOutputIDsForTesting: Set<String> {
            toolOutputLoadState.loadingIDs
        }

        func _triggerLoadFullToolOutputForTesting(
            itemID: String,
            tool: String,
            outputByteCount: Int,
            in collectionView: UICollectionView
        ) {
            loadFullToolOutputIfNeeded(
                itemID: itemID,
                tool: tool,
                outputByteCount: outputByteCount,
                in: collectionView
            )
        }

        deinit {
            let observedAudioPlayer = audioPlayer
            let canceled = toolOutputLoadState.cancelAll()
            _toolOutputCanceledCountForTesting += canceled
            cancelAllToolOutputRetryWork()
            NotificationCenter.default.removeObserver(
                self,
                name: AudioPlayerService.stateDidChangeNotification,
                object: observedAudioPlayer
            )
        }

        func configureDataSource(collectionView: UICollectionView) {
            self.collectionView = collectionView

            let chatRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                let configureStartNs = ChatTimelinePerf.timestampNs()
                guard let self,
                      let item = self.currentItemByID[itemID],
                      let toolOutputStore = self.toolOutputStore,
                      self.reducer != nil,
                      self.toolArgsStore != nil,
                      self.connection != nil,
                      self.audioPlayer != nil
                else {
                    var fallback = UIListContentConfiguration.subtitleCell()
                    fallback.text = "⚠️ Timeline row unavailable"
                    fallback.secondaryText = "Native timeline dependencies missing."
                    fallback.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
                    fallback.textProperties.color = UIColor(Color.tokyoOrange)
                    fallback.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                    fallback.secondaryTextProperties.color = UIColor(Color.tokyoComment)
                    cell.contentConfiguration = fallback
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "placeholder",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                let applyNativeRow: (_ configuration: any UIContentConfiguration, _ rowType: String) -> Void = { configuration, rowType in
                    cell.contentConfiguration = configuration
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: rowType,
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                }

                let applyNativeFrictionRow: (_ title: String, _ detail: String, _ rowType: String) -> Void = { title, detail, rowType in
                    var fallback = UIListContentConfiguration.subtitleCell()
                    fallback.text = title
                    fallback.secondaryText = detail
                    fallback.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
                    fallback.textProperties.color = UIColor(Color.tokyoOrange)
                    fallback.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                    fallback.secondaryTextProperties.color = UIColor(Color.tokyoComment)
                    cell.contentConfiguration = fallback
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: rowType,
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                }

                // Resolve native configuration for each item type.
                let rowLabel: String
                let nativeConfig: (any UIContentConfiguration)?

                switch item {
                case .userMessage:
                    rowLabel = "user"
                    nativeConfig = self.nativeUserConfiguration(itemID: itemID, item: item)
                case .assistantMessage:
                    rowLabel = "assistant"
                    nativeConfig = self.nativeAssistantConfiguration(itemID: itemID, item: item)
                case .thinking:
                    rowLabel = "thinking"
                    nativeConfig = self.nativeThinkingConfiguration(itemID: itemID, item: item)
                case .toolCall:
                    rowLabel = "tool"
                    nativeConfig = self.nativeToolConfiguration(itemID: itemID, item: item)
                case .audioClip:
                    rowLabel = "audio"
                    nativeConfig = self.nativeAudioConfiguration(item: item)
                case .permission, .permissionResolved:
                    rowLabel = "permission"
                    nativeConfig = self.nativePermissionConfiguration(item: item)
                case .systemEvent(_, let message):
                    rowLabel = Self.compactionPresentation(from: message) == nil ? "system" : "compaction"
                    nativeConfig = self.nativeSystemEventConfiguration(itemID: itemID, item: item)
                case .error:
                    rowLabel = "error"
                    nativeConfig = self.nativeErrorConfiguration(item: item)
                }

                if let nativeConfig {
                    applyNativeRow(nativeConfig, "\(rowLabel)_native")
                } else {
                    // Defensive failsafe — should not fire for any current item type.
                    Self.reportNativeRendererGap("Native \(rowLabel) configuration missing.")
                    applyNativeFrictionRow(
                        "⚠️ Native \(rowLabel) row unavailable",
                        "Native \(rowLabel) renderer gap.",
                        "\(rowLabel)_native_failsafe"
                    )
                }
            }

            let loadMoreRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, _ in
                let configureStartNs = ChatTimelinePerf.timestampNs()
                guard let self else {
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "load_more",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                cell.contentConfiguration = LoadMoreTimelineRowConfiguration(
                    hiddenCount: self.hiddenCount,
                    renderWindowStep: self.renderWindowStep,
                    onTap: { [weak self] in self?.onShowEarlier?() },
                    themeID: self.currentThemeID
                )
                cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                ChatTimelinePerf.recordCellConfigure(
                    rowType: "load_more",
                    durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                )
            }

            let workingRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, _ in
                let configureStartNs = ChatTimelinePerf.timestampNs()
                guard let self else {
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "working_indicator",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                cell.contentConfiguration = WorkingIndicatorTimelineRowConfiguration(themeID: self.currentThemeID)
                cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                ChatTimelinePerf.recordCellConfigure(
                    rowType: "working_indicator",
                    durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                )
            }

            dataSource = UICollectionViewDiffableDataSource<Int, String>(
                collectionView: collectionView
            ) { collectionView, indexPath, itemID in
                if itemID == ChatTimelineCollectionView.loadMoreID {
                    return collectionView.dequeueConfiguredReusableCell(
                        using: loadMoreRegistration,
                        for: indexPath,
                        item: itemID
                    )
                }

                if itemID == ChatTimelineCollectionView.workingIndicatorID {
                    return collectionView.dequeueConfiguredReusableCell(
                        using: workingRegistration,
                        for: indexPath,
                        item: itemID
                    )
                }

                return collectionView.dequeueConfiguredReusableCell(
                    using: chatRegistration,
                    for: indexPath,
                    item: itemID
                )
            }
        }

        enum ToolOutputCompletionDisposition: Equatable {
            case apply
            case canceled
            case staleSession
            case missingItem
            case emptyOutput
        }
        private struct ToolOutputLoadState {
            var loadingIDs: Set<String> = []
            var tasks: [String: Task<Void, Never>] = [:]
            var taskCount: Int { tasks.count }
            func isLoading(_ itemID: String) -> Bool { loadingIDs.contains(itemID) || tasks[itemID] != nil }
            mutating func start(itemID: String, task: Task<Void, Never>) {
                loadingIDs.insert(itemID)
                tasks[itemID] = task
            }
            mutating func finish(itemID: String) {
                loadingIDs.remove(itemID)
                tasks.removeValue(forKey: itemID)
            }
            mutating func cancel(for itemIDs: Set<String>) -> Int {
                guard !itemIDs.isEmpty else { return 0 }
                var canceled = 0
                for itemID in itemIDs {
                    if let task = tasks.removeValue(forKey: itemID) {
                        task.cancel()
                        canceled += 1
                    }
                    loadingIDs.remove(itemID)
                }
                return canceled
            }
            mutating func cancelAll() -> Int {
                let canceled = tasks.count
                for task in tasks.values { task.cancel() }
                tasks.removeAll()
                loadingIDs.removeAll()
                return canceled
            }
        }

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

        static func toolOutputCompletionDisposition(
            output: String,
            isTaskCancelled: Bool,
            activeSessionID: String,
            currentSessionID: String,
            itemExists: Bool
        ) -> ToolOutputCompletionDisposition {
            if isTaskCancelled {
                return .canceled
            }
            if activeSessionID != currentSessionID {
                return .staleSession
            }
            if !itemExists {
                return .missingItem
            }
            if output.isEmpty {
                return .emptyOutput
            }
            return .apply
        }

        private static func reportNativeRendererGap(_ message: String) {
            #if DEBUG
                NSLog("⚠️ [TimelineNativeGap] %@", message)
            #endif
        }

        struct CompactionPresentation: Equatable {
            enum Phase: Equatable {
                case inProgress
                case completed
                case retrying
                case cancelled
            }

            let phase: Phase
            let detail: String?
            let tokensBefore: Int?

            var canExpand: Bool {
                guard let detail else { return false }
                let cleaned = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return false }
                return cleaned.count > 140 || cleaned.contains("\n")
            }
        }

        static func compactionPresentation(from rawMessage: String) -> CompactionPresentation? {
            let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return nil }

            if message.hasPrefix("Context overflow — compacting")
                || message.hasPrefix("Compacting context") {
                return CompactionPresentation(phase: .inProgress, detail: nil, tokensBefore: nil)
            }

            if message.hasPrefix("Compaction cancelled") {
                return CompactionPresentation(phase: .cancelled, detail: nil, tokensBefore: nil)
            }

            if message.hasPrefix("Context compacted — retrying") {
                return CompactionPresentation(phase: .retrying, detail: nil, tokensBefore: nil)
            }

            guard message.hasPrefix("Context compacted") else {
                return nil
            }

            let detail = compactionDetail(from: message)
            let tokensBefore = compactionTokensBefore(from: message)

            return CompactionPresentation(
                phase: .completed,
                detail: detail,
                tokensBefore: tokensBefore
            )
        }

        private static func compactionDetail(from message: String) -> String? {
            guard let separator = message.firstIndex(of: ":") else {
                return nil
            }

            let start = message.index(after: separator)
            let detail = message[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? nil : detail
        }

        private static func compactionTokensBefore(from message: String) -> Int? {
            guard let compactedRange = message.range(of: "Context compacted") else {
                return nil
            }

            let suffix = message[compactedRange.upperBound...]
            guard let openParen = suffix.firstIndex(of: "("),
                  let closeParen = suffix[openParen...].firstIndex(of: ")") else {
                return nil
            }

            let inside = suffix[suffix.index(after: openParen)..<closeParen]
            guard String(inside).localizedCaseInsensitiveContains("token") else {
                return nil
            }

            let digits = inside.filter { $0.isNumber }
            guard !digits.isEmpty else {
                return nil
            }

            return Int(String(digits))
        }


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

            _audioStateRefreshCountForTesting += 1
            _audioStateRefreshedItemIDsForTesting = targetIDs
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

        func apply(configuration: Configuration, to collectionView: UICollectionView) {
            hiddenCount = configuration.hiddenCount
            renderWindowStep = configuration.renderWindowStep
            streamingAssistantID = configuration.streamingAssistantID

            if sessionId != configuration.sessionId || workspaceId != configuration.workspaceId {
                cancelAllToolOutputLoadTasks()
                lastObservedContentOffsetY = nil
                configuration.scrollController.setUserInteracting(false)
                configuration.scrollController.setDetachedStreamingHintVisible(false)
                configuration.scrollController.setJumpToBottomHintVisible(false)
            }
            sessionId = configuration.sessionId
            workspaceId = configuration.workspaceId

            onFork = configuration.onFork
            onOpenFile = configuration.onOpenFile
            onShowEarlier = configuration.onShowEarlier
            scrollController = configuration.scrollController
            reducer = configuration.reducer
            toolOutputStore = configuration.toolOutputStore
            toolArgsStore = configuration.toolArgsStore
            connection = configuration.connection
            self.collectionView = collectionView
            bindAudioStateObservationIfNeeded(audioPlayer: configuration.audioPlayer)
            theme = configuration.theme
            currentThemeID = configuration.themeID

            collectionView.backgroundColor = UIColor(Color.tokyoBg)

            var nextItemByID: [String: ChatItem] = [:]
            nextItemByID.reserveCapacity(configuration.items.count)

            var nextIDs: [String] = []
            nextIDs.reserveCapacity(configuration.items.count + 2)

            if configuration.hiddenCount > 0 {
                nextIDs.append(ChatTimelineCollectionView.loadMoreID)
            }

            // Diffable data sources require globally unique item identifiers.
            // Keep only the last occurrence for duplicate IDs so reconnect/
            // replay races cannot crash UICollectionView snapshot application.
            let dedupedItems = Self.uniqueItemsKeepingLast(configuration.items)
            nextIDs.append(contentsOf: dedupedItems.orderedIDs)
            nextItemByID = dedupedItems.itemByID

            if configuration.isBusy, configuration.streamingAssistantID == nil {
                nextIDs.append(ChatTimelineCollectionView.workingIndicatorID)
            }

            let removedIDs = Set(currentIDs).subtracting(nextIDs)
            if !removedIDs.isEmpty {
                cancelToolOutputLoadTasks(for: removedIDs)
            }

            currentIDs = nextIDs
            currentItemByID = nextItemByID

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(nextIDs)

            var changedIDs = changedItemIDs(nextItemByID: nextItemByID)

            if configuration.hiddenCount != previousHiddenCount,
               nextIDs.contains(ChatTimelineCollectionView.loadMoreID) {
                changedIDs.append(ChatTimelineCollectionView.loadMoreID)
            }

            if let streamingAssistantID = configuration.streamingAssistantID {
                changedIDs.append(streamingAssistantID)
            }

            if let previousStreamingAssistantID,
               previousStreamingAssistantID != configuration.streamingAssistantID {
                changedIDs.append(previousStreamingAssistantID)
            }

            if previousThemeID != configuration.themeID {
                changedIDs.append(contentsOf: nextIDs)
            }

            let dedupedChangedIDs = Array(Set(changedIDs)).filter { nextIDs.contains($0) }
            if !dedupedChangedIDs.isEmpty {
                snapshot.reconfigureItems(dedupedChangedIDs)
            }

            let applyToken = ChatTimelinePerf.beginCollectionApply(
                itemCount: nextIDs.count,
                changedCount: dedupedChangedIDs.count
            )
            dataSource?.apply(snapshot, animatingDifferences: false)
            ChatTimelinePerf.endCollectionApply(applyToken)

            previousItemByID = nextItemByID
            previousStreamingAssistantID = configuration.streamingAssistantID
            previousHiddenCount = configuration.hiddenCount
            previousThemeID = configuration.themeID

            let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: nextIDs.count)
            collectionView.layoutIfNeeded()
            ChatTimelinePerf.endLayoutPass(layoutToken)
            if let scrollCommand = configuration.scrollCommand,
               scrollCommand.nonce != lastHandledScrollCommandNonce,
               performScroll(scrollCommand, in: collectionView) {
                lastHandledScrollCommandNonce = scrollCommand.nonce
            }

            // When the session is busy (streaming or running tools), new items
            // grow contentSize faster than auto-scroll can keep up. Suppress
            // updateScrollState here to avoid flipping isNearBottom=false before
            // the throttled auto-scroll fires. User-initiated scroll changes
            // are still detected via scrollViewDidScroll delegate callbacks.
            let isBusy = configuration.isBusy
            if !isBusy {
                updateScrollState(collectionView)
            }
            updateDetachedStreamingHintVisibility()
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            scrollController?.setUserInteracting(true)
            lastObservedContentOffsetY = scrollView.contentOffset.y
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                scrollController?.setUserInteracting(false)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scrollController?.setUserInteracting(false)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }

            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                let previousOffset = lastObservedContentOffsetY ?? scrollView.contentOffset.y
                let deltaY = scrollView.contentOffset.y - previousOffset
                if deltaY < -0.5 {
                    scrollController?.detachFromBottomForUserScroll()
                }
            }

            lastObservedContentOffsetY = scrollView.contentOffset.y
            updateScrollState(collectionView)
            updateDetachedStreamingHintVisibility()
        }
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
            if itemID == ChatTimelineCollectionView.loadMoreID || itemID == ChatTimelineCollectionView.workingIndicatorID {
                return
            }

            collectionView.deselectItem(at: indexPath, animated: false)

            guard let item = currentItemByID[itemID],
                  let reducer else {
                return
            }

            switch item {
            case .toolCall(_, let tool, _, _, let outputByteCount, _, _):
                // Do not gate on current cell.contentConfiguration type.
                // During high-frequency streaming updates the visible cell can be
                // transiently reconfigured while still representing the same
                // tool item, and strict type checks can drop taps.
                let wasExpanded = reducer.expandedItemIDs.contains(itemID)
                if wasExpanded {
                    reducer.expandedItemIDs.remove(itemID)
                    cancelToolOutputRetryWork(for: itemID)
                } else {
                    reducer.expandedItemIDs.insert(itemID)
                    loadFullToolOutputIfNeeded(
                        itemID: itemID,
                        tool: tool,
                        outputByteCount: outputByteCount,
                        in: collectionView
                    )
                }
                animateNativeToolExpansion(itemID: itemID, item: item, isExpanding: !wasExpanded, in: collectionView)
            case .thinking(_, _, _, let isDone):
                guard isDone else {
                    return
                }
                // Thought rows auto-expand by default and are not interactive.
                // Keep tap as no-op so accidental touches don't churn reconfigures.
                return

            case .systemEvent(let systemID, let message):
                guard let compaction = Self.compactionPresentation(from: message),
                      compaction.canExpand else {
                    return
                }

                if reducer.expandedItemIDs.contains(systemID) {
                    reducer.expandedItemIDs.remove(systemID)
                } else {
                    reducer.expandedItemIDs.insert(systemID)
                }

                reconfigureItems([systemID], in: collectionView)

            default:
                break
            }
        }

        private func changedItemIDs(nextItemByID: [String: ChatItem]) -> [String] {
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

        private func nativeAssistantConfiguration(itemID: String, item: ChatItem) -> AssistantTimelineRowConfiguration? {
            guard case .assistantMessage(_, let text, _) = item else { return nil }

            let isStreaming = itemID == streamingAssistantID

            // Unified native markdown renderer — handles all content (plain
            // text, rich markdown, code blocks, tables) via
            // AssistantMarkdownContentView.
            return AssistantTimelineRowConfiguration(
                text: text,
                isStreaming: isStreaming,
                canFork: false,
                onFork: nil,
                themeID: currentThemeID
            )
        }

        private func nativeUserConfiguration(itemID: String, item: ChatItem) -> UserTimelineRowConfiguration? {
            guard case .userMessage(_, let text, let images, _) = item else { return nil }

            let canFork = UUID(uuidString: itemID) == nil && onFork != nil
            let forkAction: (() -> Void)?
            if canFork {
                forkAction = { [weak self] in
                    self?.onFork?(itemID)
                }
            } else {
                forkAction = nil
            }

            // Unified native user row — handles both text-only and image messages.
            return UserTimelineRowConfiguration(
                text: text,
                images: images,
                canFork: canFork,
                onFork: forkAction,
                themeID: currentThemeID
            )
        }

        private func nativeThinkingConfiguration(itemID: String, item: ChatItem) -> ThinkingTimelineRowConfiguration? {
            guard case .thinking(_, let preview, _, let isDone) = item else { return nil }

            // Thought content should be visible by default once complete.
            let isExpanded = isDone
            return ThinkingTimelineRowConfiguration(
                isDone: isDone,
                isExpanded: isExpanded,
                previewText: preview,
                fullText: toolOutputStore?.fullOutput(for: itemID),
                themeID: currentThemeID
            )
        }

        private func nativeAudioConfiguration(item: ChatItem) -> AudioClipTimelineRowConfiguration? {
            guard case .audioClip(let id, let title, let fileURL, _) = item,
                  let audioPlayer else {
                return nil
            }

            return AudioClipTimelineRowConfiguration(
                id: id,
                title: title,
                fileURL: fileURL,
                audioPlayer: audioPlayer,
                themeID: currentThemeID
            )
        }

        private func nativePermissionConfiguration(item: ChatItem) -> PermissionTimelineRowConfiguration? {
            switch item {
            case .permission(let request):
                return PermissionTimelineRowConfiguration(
                    outcome: .expired,
                    tool: request.tool,
                    summary: request.displaySummary,
                    themeID: currentThemeID
                )

            case .permissionResolved(_, let outcome, let tool, let summary):
                return PermissionTimelineRowConfiguration(
                    outcome: outcome,
                    tool: tool,
                    summary: summary,
                    themeID: currentThemeID
                )

            default:
                return nil
            }
        }

        private func nativeSystemEventConfiguration(itemID: String, item: ChatItem) -> (any UIContentConfiguration)? {
            guard case .systemEvent(_, let message) = item else { return nil }

            if let compaction = Self.compactionPresentation(from: message) {
                let isExpanded = reducer?.expandedItemIDs.contains(itemID) == true
                return CompactionTimelineRowConfiguration(
                    presentation: compaction,
                    isExpanded: isExpanded,
                    themeID: currentThemeID
                )
            }

            return SystemTimelineRowConfiguration(message: message, themeID: currentThemeID)
        }

        private func nativeErrorConfiguration(item: ChatItem) -> ErrorTimelineRowConfiguration? {
            guard case .error(_, let message) = item else { return nil }
            return ErrorTimelineRowConfiguration(message: message, themeID: currentThemeID)
        }

        func nativeToolConfiguration(itemID: String, item: ChatItem) -> ToolTimelineRowConfiguration? {
            guard case .toolCall(_, let tool, let argsSummary, let outputPreview, _, let isError, let isDone) = item else {
                return nil
            }

            let context = ToolPresentationBuilder.Context(
                args: toolArgsStore?.args(for: itemID),
                expandedItemIDs: reducer?.expandedItemIDs ?? [],
                fullOutput: toolOutputStore?.fullOutput(for: itemID) ?? "",
                isLoadingOutput: toolOutputLoadState.isLoading(itemID)
            )

            return ToolPresentationBuilder.build(
                itemID: itemID,
                tool: tool,
                argsSummary: argsSummary,
                outputPreview: outputPreview,
                isError: isError,
                isDone: isDone,
                context: context
            )
        }

        private func loadFullToolOutputIfNeeded(
            itemID: String,
            tool: String,
            outputByteCount: Int,
            in collectionView: UICollectionView,
            attempt: Int = 0
        ) {
            _ = tool
            _ = outputByteCount

            guard let toolOutputStore,
                  toolOutputStore.fullOutput(for: itemID).isEmpty,
                  !toolOutputLoadState.isLoading(itemID) else {
                return
            }

            let fetchToolOutput: (_ sessionId: String, _ toolCallId: String) async throws -> String
            if let fetchHook = _fetchToolOutputForTesting {
                fetchToolOutput = fetchHook
            } else {
                guard let apiClient = connection?.apiClient,
                      let workspaceId,
                      !workspaceId.isEmpty else { return }

                fetchToolOutput = { sessionId, toolCallId in
                    try await apiClient.getNonEmptyToolOutput(workspaceId: workspaceId, sessionId: sessionId, toolCallId: toolCallId) ?? ""
                }
            }

            let activeSessionID = sessionId

            let task = Task { [weak self, weak collectionView, activeSessionID] in
                let output: String
                do {
                    output = try await fetchToolOutput(activeSessionID, itemID)
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.toolOutputLoadState.finish(itemID: itemID)
                    }
                    return
                }

                await MainActor.run {
                    guard let self else { return }
                    defer {
                        self.toolOutputLoadState.finish(itemID: itemID)
                    }

                    let disposition = Self.toolOutputCompletionDisposition(
                        output: output,
                        isTaskCancelled: Task.isCancelled,
                        activeSessionID: activeSessionID,
                        currentSessionID: self.sessionId,
                        itemExists: self.currentItemByID[itemID] != nil
                    )

                    guard disposition == .apply else {
                        switch disposition {
                        case .staleSession, .missingItem, .emptyOutput:
                            self._toolOutputStaleDiscardCountForTesting += 1
                        case .canceled, .apply:
                            break
                        }

                        if disposition == .emptyOutput {
                            self.scheduleToolOutputRetryIfNeeded(
                                itemID: itemID,
                                tool: tool,
                                outputByteCount: outputByteCount,
                                in: collectionView,
                                attempt: attempt
                            )
                        }
                        return
                    }

                    self.cancelToolOutputRetryWork(for: itemID)
                    self.toolOutputStore?.append(output, to: itemID)
                    self._toolOutputAppliedCountForTesting += 1

                    if let collectionView {
                        self.reconfigureItems([itemID], in: collectionView)
                    }
                }
            }

            toolOutputLoadState.start(itemID: itemID, task: task)
        }

        private func scheduleToolOutputRetryIfNeeded(
            itemID: String,
            tool: String,
            outputByteCount: Int,
            in collectionView: UICollectionView?,
            attempt: Int
        ) {
            guard ToolCallFormatting.isReadTool(tool) else { return }
            guard attempt < Self.toolOutputRetryMaxAttempts else { return }
            guard reducer?.expandedItemIDs.contains(itemID) == true else { return }
            guard let collectionView else { return }

            cancelToolOutputRetryWork(for: itemID)

            let nextAttempt = attempt + 1
            let delay = min(
                Self.toolOutputRetryMaxDelay,
                Self.toolOutputRetryBaseDelay * pow(1.6, Double(attempt))
            )

            let retryWork = DispatchWorkItem { [weak self, weak collectionView] in
                guard let self,
                      let collectionView,
                      self.reducer?.expandedItemIDs.contains(itemID) == true,
                      self.currentItemByID[itemID] != nil else {
                    return
                }

                self.loadFullToolOutputIfNeeded(
                    itemID: itemID,
                    tool: tool,
                    outputByteCount: outputByteCount,
                    in: collectionView,
                    attempt: nextAttempt
                )
            }

            pendingToolOutputRetryWorkByID[itemID] = retryWork
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryWork)
        }

        private func cancelToolOutputRetryWork(for itemID: String) {
            pendingToolOutputRetryWorkByID.removeValue(forKey: itemID)?.cancel()
        }

        private func cancelAllToolOutputRetryWork() {
            for (_, work) in pendingToolOutputRetryWorkByID {
                work.cancel()
            }
            pendingToolOutputRetryWorkByID.removeAll(keepingCapacity: false)
        }

        private func cancelToolOutputLoadTasks(for itemIDs: Set<String>) {
            let canceled = toolOutputLoadState.cancel(for: itemIDs)
            _toolOutputCanceledCountForTesting += canceled
            for itemID in itemIDs {
                cancelToolOutputRetryWork(for: itemID)
            }
        }

        private func cancelAllToolOutputLoadTasks() {
            let canceled = toolOutputLoadState.cancelAll()
            _toolOutputCanceledCountForTesting += canceled
            cancelAllToolOutputRetryWork()
        }

        private func animateNativeToolExpansion(
            itemID: String,
            item: ChatItem,
            isExpanding _: Bool,
            in collectionView: UICollectionView
        ) {
            guard let index = currentIDs.firstIndex(of: itemID),
                  let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)),
                  let configuration = nativeToolConfiguration(itemID: itemID, item: item)
            else {
                // Defensive fallback: should be rare for tap-selected visible
                // rows. Track it so tests can catch regressions.
                _toolExpansionFallbackCountForTesting += 1
                reconfigureItems([itemID], in: collectionView)
                return
            }
            collectionView.layoutIfNeeded()
            cell.contentConfiguration = configuration

            let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: currentIDs.count)
            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
                CATransaction.commit()
            }
            ChatTimelinePerf.endLayoutPass(layoutToken)
        }

        private func reconfigureItems(_ itemIDs: [String], in collectionView: UICollectionView) {
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

        private func performScroll(
            _ command: ChatTimelineScrollCommand,
            in collectionView: UICollectionView
        ) -> Bool {
            guard let index = currentIDs.firstIndex(of: command.id) else { return false }
            let indexPath = IndexPath(item: index, section: 0)

            let position: UICollectionView.ScrollPosition
            switch command.anchor {
            case .top:
                position = .top
            case .bottom:
                position = .bottom
            }

            ChatTimelinePerf.recordScrollCommand(anchor: command.anchor, animated: command.animated)

            if command.animated {
                // Use a spring animation for a more obvious push-up feel
                // when new items appear. scrollToItem's default animation is
                // too fast/subtle to notice.
                collectionView.scrollToItem(at: indexPath, at: position, animated: false)
                let targetOffset = collectionView.contentOffset
                // Rewind to pre-scroll position and animate to target
                collectionView.contentOffset.y = max(0, targetOffset.y - 60)
                UIView.animate(
                    withDuration: 0.4,
                    delay: 0,
                    usingSpringWithDamping: 0.85,
                    initialSpringVelocity: 0.5,
                    options: [.allowUserInteraction, .curveEaseOut]
                ) {
                    collectionView.contentOffset = targetOffset
                }
            } else {
                collectionView.scrollToItem(at: indexPath, at: position, animated: false)
            }

            // `scrollToItem(animated: false)` can update contentOffset on the next
            // runloop tick without always triggering immediate delegate callbacks.
            // Re-sample scroll state asynchronously so diagnostics (near-bottom,
            // top visible id) converge deterministically for harness assertions.
            if !command.animated {
                DispatchQueue.main.async { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    collectionView.layoutIfNeeded()
                    self.updateScrollState(collectionView)
                    self.updateDetachedStreamingHintVisibility()
                }
            }

            return true
        }

        private func updateDetachedStreamingHintVisibility() {
            guard let scrollController else { return }

            let isDetached = !scrollController.isCurrentlyNearBottom
            let showsStreamingState = streamingAssistantID != nil && isDetached

            scrollController.setDetachedStreamingHintVisible(showsStreamingState)
            scrollController.setJumpToBottomHintVisible(isDetached)
        }

        private func updateScrollState(_ collectionView: UICollectionView) {
            guard let scrollController else { return }

            let insets = collectionView.adjustedContentInset
            let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
            guard visibleHeight > 0 else { return }

            let bottomY = collectionView.contentOffset.y + insets.top + visibleHeight
            let contentHeight = collectionView.contentSize.height
            let distanceFromBottom = max(0, contentHeight - bottomY)
            let nearBottomThreshold = scrollController.isCurrentlyNearBottom
                ? nearBottomExitThreshold
                : nearBottomEnterThreshold
            scrollController.updateNearBottom(distanceFromBottom <= nearBottomThreshold)

            let firstVisible = collectionView.indexPathsForVisibleItems
                .min { lhs, rhs in lhs.item < rhs.item }

            guard let firstVisible else {
                scrollController.updateTopVisibleItemId(nil)
                return
            }

            guard firstVisible.item < currentIDs.count else {
                scrollController.updateTopVisibleItemId(nil)
                return
            }

            let id = currentIDs[firstVisible.item]
            if id == ChatTimelineCollectionView.loadMoreID || id == ChatTimelineCollectionView.workingIndicatorID {
                scrollController.updateTopVisibleItemId(nil)
            } else {
                scrollController.updateTopVisibleItemId(id)
            }
        }
    }
}

// swiftlint:enable type_body_length
