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
        guard let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else {
            return layoutAttributes
        }

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
        let connection: ServerConnection
        let audioPlayer: AudioPlayerService
        let theme: AppTheme
        let themeID: ThemeID
    }

    let configuration: Configuration

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = AnchoredCollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = UIColor(Color.themeBg)
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInset.bottom = 12
        collectionView.delegate = context.coordinator

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Controller.handleTimelineTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        collectionView.addGestureRecognizer(tapGesture)

        context.coordinator.configureDataSource(collectionView: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.apply(configuration: configuration, to: collectionView)
    }

    func makeCoordinator() -> Controller {
        Controller()
    }

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
        private var toolSegmentStore: ToolSegmentStore?
        private var connection: ServerConnection?
        private var audioPlayer: AudioPlayerService?
        private weak var collectionView: UICollectionView?
        private var theme: AppTheme = .dark
        private var currentThemeID: ThemeID = .dark

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
        private var lastDistanceFromBottom: CGFloat = 0
        private let toolOutputLoader = ExpandedToolOutputLoader()

        #if DEBUG
            var _fetchToolOutputForTesting: ((_ sessionId: String, _ toolCallId: String) async throws -> String)? {
                get { toolOutputLoader.fetchOverrideForTesting }
                set { toolOutputLoader.fetchOverrideForTesting = newValue }
            }

            var _toolOutputCanceledCountForTesting: Int {
                toolOutputLoader.canceledCountForTesting
            }

            var _toolOutputStaleDiscardCountForTesting: Int {
                toolOutputLoader.staleDiscardCountForTesting
            }

            var _toolOutputAppliedCountForTesting: Int {
                toolOutputLoader.appliedCountForTesting
            }

            private(set) var _toolExpansionFallbackCountForTesting = 0
            private(set) var _audioStateRefreshCountForTesting = 0
            private(set) var _audioStateRefreshedItemIDsForTesting: [String] = []

            var _toolOutputLoadTaskCountForTesting: Int {
                toolOutputLoader.taskCountForTesting
            }

            var _loadingToolOutputIDsForTesting: Set<String> {
                toolOutputLoader.loadingIDsForTesting
            }

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

        // MARK: - Data Source Configuration

        func configureDataSource(collectionView: UICollectionView) {
            self.collectionView = collectionView

            let assistantRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "assistant"
                ) { item in
                    self?.assistantRowConfiguration(itemID: itemID, item: item)
                }
            }

            let userRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "user"
                ) { item in
                    self?.userRowConfiguration(itemID: itemID, item: item)
                }
            }

            let thinkingRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "thinking"
                ) { item in
                    self?.thinkingRowConfiguration(itemID: itemID, item: item)
                }
            }

            let toolRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "tool"
                ) { item in
                    self?.toolRowConfiguration(itemID: itemID, item: item)
                }
            }

            let audioRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "audio"
                ) { item in
                    self?.audioRowConfiguration(item: item)
                }
            }

            let permissionRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "permission"
                ) { item in
                    self?.permissionRowConfiguration(item: item)
                }
            }

            let systemRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "system"
                ) { item in
                    self?.systemEventRowConfiguration(itemID: itemID, item: item)
                }
            }

            let compactionRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "compaction"
                ) { item in
                    self?.systemEventRowConfiguration(itemID: itemID, item: item)
                }
            }

            let errorRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
                self?.configureNativeCell(
                    cell,
                    itemID: itemID,
                    rowLabel: "error"
                ) { item in
                    self?.errorRowConfiguration(item: item)
                }
            }

            let missingItemRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, _ in
                self?.applyNativeFrictionRow(
                    to: cell,
                    title: "⚠️ Timeline row unavailable",
                    detail: "Timeline item missing from snapshot.",
                    rowType: "placeholder"
                )
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
            ) { [weak self] collectionView, indexPath, itemID in
                if itemID == ChatTimelineCollectionHost.loadMoreID {
                    return collectionView.dequeueConfiguredReusableCell(
                        using: loadMoreRegistration,
                        for: indexPath,
                        item: itemID
                    )
                }

                if itemID == ChatTimelineCollectionHost.workingIndicatorID {
                    return collectionView.dequeueConfiguredReusableCell(
                        using: workingRegistration,
                        for: indexPath,
                        item: itemID
                    )
                }

                guard let self,
                      let item = self.currentItemByID[itemID] else {
                    return collectionView.dequeueConfiguredReusableCell(
                        using: missingItemRegistration,
                        for: indexPath,
                        item: itemID
                    )
                }

                switch item {
                case .assistantMessage:
                    return collectionView.dequeueConfiguredReusableCell(
                        using: assistantRegistration,
                        for: indexPath,
                        item: itemID
                    )
                case .userMessage:
                    return collectionView.dequeueConfiguredReusableCell(
                        using: userRegistration,
                        for: indexPath,
                        item: itemID
                    )
                case .thinking:
                    return collectionView.dequeueConfiguredReusableCell(
                        using: thinkingRegistration,
                        for: indexPath,
                        item: itemID
                    )
                case .toolCall:
                    return collectionView.dequeueConfiguredReusableCell(
                        using: toolRegistration,
                        for: indexPath,
                        item: itemID
                    )
                case .audioClip:
                    return collectionView.dequeueConfiguredReusableCell(
                        using: audioRegistration,
                        for: indexPath,
                        item: itemID
                    )
                case .permission, .permissionResolved:
                    return collectionView.dequeueConfiguredReusableCell(
                        using: permissionRegistration,
                        for: indexPath,
                        item: itemID
                    )
                case .systemEvent(_, let message):
                    let registration = Self.compactionPresentation(from: message) == nil
                        ? systemRegistration
                        : compactionRegistration
                    return collectionView.dequeueConfiguredReusableCell(
                        using: registration,
                        for: indexPath,
                        item: itemID
                    )
                case .error:
                    return collectionView.dequeueConfiguredReusableCell(
                        using: errorRegistration,
                        for: indexPath,
                        item: itemID
                    )
                }
            }

        }

        private func configureNativeCell(
            _ cell: SafeSizingCell,
            itemID: String,
            rowLabel: String,
            builder: (ChatItem) -> (any UIContentConfiguration)?
        ) {
            let configureStartNs = ChatTimelinePerf.timestampNs()

            guard let item = currentItemByID[itemID],
                  toolOutputStore != nil,
                  reducer != nil,
                  toolArgsStore != nil,
                  connection != nil,
                  audioPlayer != nil
            else {
                applyNativeFrictionRow(
                    to: cell,
                    title: "⚠️ Timeline row unavailable",
                    detail: "Native timeline dependencies missing.",
                    rowType: "placeholder",
                    startNs: configureStartNs
                )
                return
            }

            guard let nativeConfig = builder(item) else {
                Self.reportNativeRendererGap("Native \(rowLabel) configuration missing.")
                applyNativeFrictionRow(
                    to: cell,
                    title: "⚠️ Native \(rowLabel) row unavailable",
                    detail: "Native \(rowLabel) renderer gap.",
                    rowType: "\(rowLabel)_native_failsafe",
                    startNs: configureStartNs
                )
                return
            }

            applyNativeRow(
                to: cell,
                configuration: nativeConfig,
                rowType: "\(rowLabel)_native",
                startNs: configureStartNs
            )
        }

        private func applyNativeRow(
            to cell: SafeSizingCell,
            configuration: any UIContentConfiguration,
            rowType: String,
            startNs: UInt64
        ) {
            cell.contentConfiguration = configuration
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            ChatTimelinePerf.recordCellConfigure(
                rowType: rowType,
                durationMs: ChatTimelinePerf.elapsedMs(since: startNs)
            )
        }

        private func applyNativeFrictionRow(
            to cell: SafeSizingCell,
            title: String,
            detail: String,
            rowType: String,
            startNs: UInt64 = ChatTimelinePerf.timestampNs()
        ) {
            var fallback = UIListContentConfiguration.subtitleCell()
            fallback.text = title
            fallback.secondaryText = detail
            fallback.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            fallback.textProperties.color = UIColor(Color.themeOrange)
            fallback.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            fallback.secondaryTextProperties.color = UIColor(Color.themeComment)
            cell.contentConfiguration = fallback
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            ChatTimelinePerf.recordCellConfigure(
                rowType: rowType,
                durationMs: ChatTimelinePerf.elapsedMs(since: startNs)
            )
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

        private static func reportNativeRendererGap(_ message: String) {
            #if DEBUG
                NSLog("⚠️ [TimelineNativeGap] %@", message)
            #endif
        }

        // MARK: - Compaction

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
            toolSegmentStore = configuration.toolSegmentStore
            connection = configuration.connection
            self.collectionView = collectionView
            bindAudioStateObservationIfNeeded(audioPlayer: configuration.audioPlayer)
            theme = configuration.theme
            currentThemeID = configuration.themeID

            collectionView.backgroundColor = UIColor(Color.themeBg)

            var nextItemByID: [String: ChatItem] = [:]
            nextItemByID.reserveCapacity(configuration.items.count)

            var nextIDs: [String] = []
            nextIDs.reserveCapacity(configuration.items.count + 2)

            if configuration.hiddenCount > 0 {
                nextIDs.append(ChatTimelineCollectionHost.loadMoreID)
            }

            // Diffable data sources require globally unique item identifiers.
            // Keep only the last occurrence for duplicate IDs so reconnect/
            // replay races cannot crash UICollectionView snapshot application.
            let dedupedItems = Self.uniqueItemsKeepingLast(configuration.items)
            nextIDs.append(contentsOf: dedupedItems.orderedIDs)
            nextItemByID = dedupedItems.itemByID

            if configuration.isBusy, configuration.streamingAssistantID == nil {
                nextIDs.append(ChatTimelineCollectionHost.workingIndicatorID)
            }

            let removedIDs = Set(currentIDs).subtracting(nextIDs)
            if !removedIDs.isEmpty {
                cancelToolOutputLoadTasks(for: removedIDs)
            }

            currentIDs = nextIDs
            currentItemByID = nextItemByID

            ChatTimelinePerf.beginTimelineApplyCycle(itemCount: nextIDs.count, changedCount: 0)
            ChatTimelinePerf.beginSnapshotBuildPhase()

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(nextIDs)

            var changedIDs = changedItemIDs(nextItemByID: nextItemByID)

            if configuration.hiddenCount != previousHiddenCount,
               nextIDs.contains(ChatTimelineCollectionHost.loadMoreID) {
                changedIDs.append(ChatTimelineCollectionHost.loadMoreID)
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

            previousItemByID = nextItemByID
            previousStreamingAssistantID = configuration.streamingAssistantID
            previousHiddenCount = configuration.hiddenCount
            previousThemeID = configuration.themeID

            let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: nextIDs.count)
            collectionView.layoutIfNeeded()
            ChatTimelinePerf.endLayoutPass(layoutToken)
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

        // MARK: - UIScrollViewDelegate

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

            // Always track distance for hint visibility, even when
            // updateScrollState is skipped.
            let insets = scrollView.adjustedContentInset
            let visH = scrollView.bounds.height - insets.top - insets.bottom
            if visH > 0 {
                let botY = scrollView.contentOffset.y + insets.top + visH
                lastDistanceFromBottom = max(0, scrollView.contentSize.height - botY)
            }

            let isUserDriven = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating

            if isUserDriven {
                let previousOffset = lastObservedContentOffsetY ?? scrollView.contentOffset.y
                let deltaY = scrollView.contentOffset.y - previousOffset
                if deltaY < -0.5 {
                    // User is scrolling up: detach and skip position-based
                    // re-evaluation so updateScrollState cannot immediately
                    // re-attach within the same callback.
                    scrollController?.detachFromBottomForUserScroll()
                    lastObservedContentOffsetY = scrollView.contentOffset.y
                    updateDetachedStreamingHintVisibility()
                    return
                }
            }

            lastObservedContentOffsetY = scrollView.contentOffset.y

            // For user-driven scrolls (scrolling back down toward bottom),
            // always update state so re-attach can happen.
            //
            // For programmatic offset changes (layout invalidation during
            // snapshot apply), only update when already attached. This prevents
            // a detached user from being re-attached by a layout-triggered
            // contentOffset adjustment.
            let alreadyAttached = scrollController?.isCurrentlyNearBottom ?? true
            if isUserDriven || alreadyAttached {
                updateScrollState(collectionView)
            }
            updateDetachedStreamingHintVisibility()
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
                    ensureExpandedToolOutputLoaded(
                        itemID: itemID,
                        tool: tool,
                        outputByteCount: outputByteCount,
                        in: collectionView
                    )
                }
                animateToolRowExpansion(itemID: itemID, item: item, isExpanding: !wasExpanded, in: collectionView)
            case .thinking(_, let preview, _, let isDone):
                guard isDone else {
                    return
                }
                let displayText = preview.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayText.isEmpty else { return }

                // Only expand if text would overflow the 200pt bubble cap.
                if !Self.thinkingTextOverflows(displayText, availableWidth: collectionView.bounds.width) {
                    return
                }

                let content = FullScreenCodeContent.thinking(content: displayText)
                ToolTimelineRowPresentationHelpers.presentFullScreenContent(content, from: collectionView)

            case .systemEvent:
                // Compaction rows now use an explicit chevron button affordance
                // for expand/collapse to keep row-level tap behavior consistent
                // with double-tap copy gestures.
                return

            default:
                break
            }
        }

        // MARK: - Row Configuration Builders

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

        private func assistantRowConfiguration(itemID: String, item: ChatItem) -> AssistantTimelineRowConfiguration? {
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

        private func userRowConfiguration(itemID: String, item: ChatItem) -> UserTimelineRowConfiguration? {
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

        /// Check if thinking text would overflow the bubble's max height (200pt).
        /// Measures text at callout font, accounting for brain icon indent.
        private static func thinkingTextOverflows(_ text: String, availableWidth: CGFloat) -> Bool {
            let padding: CGFloat = 10
            let brainIndent: CGFloat = 14 + 6 // icon + spacing
            let textWidth = max(1, availableWidth - brainIndent - padding * 2)
            let font = UIFont.preferredFont(forTextStyle: .callout)
            let size = (text as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            let intrinsic = ceil(size.height) + padding * 2
            return intrinsic > ThinkingTimelineRowContentView.maxBubbleHeight
        }

        private func thinkingRowConfiguration(itemID: String, item: ChatItem) -> ThinkingTimelineRowConfiguration? {
            guard case .thinking(_, let preview, _, let isDone) = item else { return nil }

            return ThinkingTimelineRowConfiguration(
                isDone: isDone,
                previewText: preview,
                fullText: toolOutputStore?.fullOutput(for: itemID),
                themeID: currentThemeID
            )
        }

        private func audioRowConfiguration(item: ChatItem) -> AudioClipTimelineRowConfiguration? {
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

        private func permissionRowConfiguration(item: ChatItem) -> PermissionTimelineRowConfiguration? {
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

        private func systemEventRowConfiguration(itemID: String, item: ChatItem) -> (any UIContentConfiguration)? {
            guard case .systemEvent(_, let message) = item else { return nil }

            if let compaction = Self.compactionPresentation(from: message) {
                let isExpanded = reducer?.expandedItemIDs.contains(itemID) == true
                let onToggleExpand: (() -> Void)?
                if compaction.canExpand {
                    onToggleExpand = { [weak self] in
                        self?.toggleCompactionExpansion(itemID: itemID)
                    }
                } else {
                    onToggleExpand = nil
                }

                return CompactionTimelineRowConfiguration(
                    presentation: compaction,
                    isExpanded: isExpanded,
                    themeID: currentThemeID,
                    onToggleExpand: onToggleExpand
                )
            }

            return SystemTimelineRowConfiguration(message: message, themeID: currentThemeID)
        }

        private func toggleCompactionExpansion(itemID: String) {
            guard let reducer,
                  let collectionView,
                  let item = currentItemByID[itemID],
                  case .systemEvent(_, let message) = item,
                  let compaction = Self.compactionPresentation(from: message),
                  compaction.canExpand else {
                return
            }

            if reducer.expandedItemIDs.contains(itemID) {
                reducer.expandedItemIDs.remove(itemID)
            } else {
                reducer.expandedItemIDs.insert(itemID)
            }

            reconfigureItems([itemID], in: collectionView)
        }

        private func errorRowConfiguration(item: ChatItem) -> ErrorTimelineRowConfiguration? {
            guard case .error(_, let message) = item else { return nil }
            return ErrorTimelineRowConfiguration(message: message, themeID: currentThemeID)
        }

        func toolRowConfiguration(itemID: String, item: ChatItem) -> ToolTimelineRowConfiguration? {
            guard case .toolCall(_, let tool, let argsSummary, let outputPreview, _, let isError, let isDone) = item else {
                return nil
            }

            let context = ToolPresentationBuilder.Context(
                args: toolArgsStore?.args(for: itemID),
                expandedItemIDs: reducer?.expandedItemIDs ?? [],
                fullOutput: toolOutputStore?.fullOutput(for: itemID) ?? "",
                isLoadingOutput: toolOutputLoader.isLoading(itemID),
                callSegments: toolSegmentStore?.callSegments(for: itemID),
                resultSegments: toolSegmentStore?.resultSegments(for: itemID)
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
                    !toolOutputStore.fullOutput(for: itemID).isEmpty
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
                    toolOutputStore.append(output, to: itemID)
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

        private func cancelAllToolOutputRetryWork() {
            toolOutputLoader.cancelAllRetryWork()
        }

        private func cancelToolOutputLoadTasks(for itemIDs: Set<String>) {
            toolOutputLoader.cancelLoadTasks(for: itemIDs)
        }

        private func cancelAllToolOutputLoadTasks() {
            toolOutputLoader.cancelAllWork()
        }

        // MARK: - Animation + Scroll

        private func animateToolRowExpansion(
            itemID: String,
            item: ChatItem,
            isExpanding _: Bool,
            in collectionView: UICollectionView
        ) {
            guard let index = currentIDs.firstIndex(of: itemID),
                  let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)),
                  let configuration = toolRowConfiguration(itemID: itemID, item: item)
            else {
                // Defensive fallback: should be rare for tap-selected visible
                // rows. Track it so tests can catch regressions.
                #if DEBUG
                    _toolExpansionFallbackCountForTesting += 1
                #endif
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
                collectionView.scrollToItem(at: indexPath, at: position, animated: true)
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

        /// Minimum distance from bottom before showing the jump-to-bottom
        /// button. One viewport height prevents flash from bounce/small scrolls.
        private let jumpToBottomMinDistance: CGFloat = 500

        private func updateDetachedStreamingHintVisibility() {
            guard let scrollController else { return }

            let isDetached = !scrollController.isCurrentlyNearBottom
            let isFarFromBottom = isDetached && lastDistanceFromBottom > jumpToBottomMinDistance

            let showsStreamingState = streamingAssistantID != nil && isDetached

            scrollController.setDetachedStreamingHintVisible(showsStreamingState && isFarFromBottom)
            scrollController.setJumpToBottomHintVisible(isFarFromBottom)
        }

        private func updateScrollState(_ collectionView: UICollectionView) {
            guard let scrollController else { return }

            let insets = collectionView.adjustedContentInset
            let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
            guard visibleHeight > 0 else { return }

            let bottomY = collectionView.contentOffset.y + insets.top + visibleHeight
            let contentHeight = collectionView.contentSize.height
            let distanceFromBottom = max(0, contentHeight - bottomY)
            lastDistanceFromBottom = distanceFromBottom
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
            if id == ChatTimelineCollectionHost.loadMoreID || id == ChatTimelineCollectionHost.workingIndicatorID {
                scrollController.updateTopVisibleItemId(nil)
            } else {
                scrollController.updateTopVisibleItemId(id)
            }
        }
    }
}

// swiftlint:enable type_body_length
