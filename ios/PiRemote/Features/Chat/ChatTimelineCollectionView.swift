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

            let chatRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, itemID in
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

            let loadMoreRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, _ in
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

            let workingRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, _ in
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

        static func shouldWarnInlineMediaForToolOutput(
            normalizedTool: String,
            outputPreview: String,
            fullOutput: String
        ) -> Bool {
            let tool = ToolCallFormatting.normalized(normalizedTool)

            // Diagnostic heuristic only.
            // Tool rows always render natively; this controls warning affordances.
            // Skip parity tools where textual content may legitimately include
            // `data:image/...` literals (e.g. source files read via `read`).
            switch tool {
            case "bash", "read", "write", "edit", "todo":
                return false
            default:
                break
            }

            let outputSample = fullOutput.isEmpty ? outputPreview : fullOutput
            guard !outputSample.isEmpty else {
                return false
            }

            return containsInlineMediaDataURI(outputSample)
        }

        private static func containsInlineMediaDataURI(_ text: String) -> Bool {
            text.range(of: "data:image/", options: .caseInsensitive) != nil
                || text.range(of: "data:audio/", options: .caseInsensitive) != nil
        }

        static func readOutputFileType(
            args: [String: JSONValue]?,
            argsSummary: String
        ) -> FileType? {
            let filePath = ToolCallFormatting.filePath(from: args)
                ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
                ?? inferredPathFromSummary(argsSummary)
            guard let filePath, !filePath.isEmpty else {
                return nil
            }
            return FileType.detect(from: filePath)
        }

        private static func inferredPathFromSummary(_ argsSummary: String) -> String? {
            let trimmed = argsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // Some streamed tool summaries arrive as raw path strings
            // (e.g. `Chat/File.swift:440-499`) without `path:` keys.
            let withoutToolPrefix: String
            if trimmed.hasPrefix("read ") {
                withoutToolPrefix = String(trimmed.dropFirst(5))
            } else if trimmed.hasPrefix("write ") {
                withoutToolPrefix = String(trimmed.dropFirst(6))
            } else if trimmed.hasPrefix("edit ") {
                withoutToolPrefix = String(trimmed.dropFirst(5))
            } else {
                withoutToolPrefix = trimmed
            }

            let candidate = withoutToolPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return nil }

            // Strip read-style line range suffix so extension detection works:
            // `file.swift:120-180` -> `file.swift`
            if let range = candidate.range(of: #":\d+(?:-\d+)?$"#, options: .regularExpression) {
                return String(candidate[..<range.lowerBound])
            }

            return candidate
        }

        static func readOutputLanguage(
            args: [String: JSONValue]?,
            argsSummary: String
        ) -> SyntaxLanguage? {
            guard let fileType = readOutputFileType(args: args, argsSummary: argsSummary) else {
                return nil
            }

            switch fileType {
            case .code(let language):
                return language
            case .json:
                return .json
            case .markdown, .image, .audio, .plain:
                return nil
            }
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

            let args = toolArgsStore?.args(for: itemID)
            let normalizedTool = ToolCallFormatting.normalized(tool)
            let isExpanded = reducer?.expandedItemIDs.contains(itemID) == true
            let fullOutput = toolOutputStore?.fullOutput(for: itemID) ?? ""
            let hasInlineMediaDataURI = Self.shouldWarnInlineMediaForToolOutput(
                normalizedTool: normalizedTool,
                outputPreview: outputPreview,
                fullOutput: fullOutput
            )
            let outputForFormatting = fullOutput.isEmpty ? outputPreview : fullOutput
            let todoMutationDiff = normalizedTool == "todo"
                ? ToolCallFormatting.todoMutationDiffPresentation(
                    args: args,
                    argsSummary: argsSummary
                )
                : nil
            let todoPresentation = normalizedTool == "todo"
                ? ToolCallFormatting.todoOutputPresentation(
                    args: args,
                    argsSummary: argsSummary,
                    output: outputForFormatting
                )
                : nil

            var title: String
            var preview: String?
            var toolNamePrefix: String?
            var toolNameColor = UIColor(Color.tokyoCyan)
            var titleLineBreakMode: NSLineBreakMode = .byTruncatingTail
            var languageBadge: String?
            var editAdded: Int?
            var editRemoved: Int?
            var editTrailingFallback: String?

            switch normalizedTool {
            case "bash":
                let compactCommand = ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if isExpanded {
                    title = "bash"
                } else {
                    title = compactCommand.isEmpty ? "bash" : compactCommand
                    titleLineBreakMode = .byTruncatingMiddle
                }
                toolNamePrefix = "$"
                toolNameColor = UIColor(Color.tokyoGreen)

            case "read", "write", "edit":
                let displayPath = ToolCallFormatting.displayFilePath(
                    tool: normalizedTool,
                    args: args,
                    argsSummary: argsSummary
                )
                title = displayPath.isEmpty
                    ? normalizedTool
                    : displayPath
                toolNamePrefix = normalizedTool
                toolNameColor = UIColor(Color.tokyoCyan)
                titleLineBreakMode = .byTruncatingMiddle

                if normalizedTool == "read" {
                    if let fileType = Self.readOutputFileType(args: args, argsSummary: argsSummary),
                       fileType == .markdown {
                        languageBadge = fileType.displayLabel
                    } else {
                        languageBadge = Self.readOutputLanguage(
                            args: args,
                            argsSummary: argsSummary
                        )?.displayName
                    }
                }

                if normalizedTool == "edit" {
                    if let stats = ToolCallFormatting.editDiffStats(from: args) {
                        editAdded = stats.added
                        editRemoved = stats.removed
                    } else {
                        editTrailingFallback = "modified"
                    }
                }

            case "todo":
                let summary = ToolCallFormatting.todoSummary(args: args, argsSummary: argsSummary)
                title = summary.isEmpty ? "todo" : "todo \(summary)"
                toolNamePrefix = "todo"
                toolNameColor = UIColor(Color.tokyoPurple)
                if let todoMutationDiff {
                    editAdded = todoMutationDiff.addedLineCount
                    editRemoved = todoMutationDiff.removedLineCount
                    preview = todoMutationDiff.preview
                } else if let todoPresentation,
                          let todoPreview = ToolCallFormatting.headLines(todoPresentation.text, count: 2),
                          !todoPreview.isEmpty {
                    preview = todoPreview
                }

            default:
                title = argsSummary.isEmpty ? tool : "\(tool) \(argsSummary)"
                toolNamePrefix = tool
                toolNameColor = UIColor(Color.tokyoCyan)
                if isError, !outputPreview.isEmpty {
                    preview = String(outputPreview.prefix(180))
                }
            }

            // Keep collapsed tool rows single-line and visually consistent.
            preview = nil

            if title.count > 240 {
                title = String(title.prefix(239)) + "…"
            }

            var expandedText: String?
            var expandedTextUsesMarkdown = false
            var expandedDiffLines: [DiffLine]?
            var expandedDiffPath: String?
            var expandedCommandText: String?
            var expandedOutputText: String?
            var expandedOutputLanguage: SyntaxLanguage?
            var expandedCodeStartLine: Int?
            var expandedCodeFilePath: String?
            var expandedUsesReadMediaRenderer = false
            var prefersUnwrappedOutput = false
            var showSeparatedCommandAndOutput = false
            var copyCommandText: String?
            var copyOutputText: String?
            if isExpanded {
                let output = fullOutput.isEmpty ? outputPreview : fullOutput
                let outputTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                copyOutputText = outputTrimmed.isEmpty ? nil : outputTrimmed

                switch normalizedTool {
                case "bash":
                    let command = ToolCallFormatting.bashCommandFull(args: args, argsSummary: argsSummary)
                    copyCommandText = command.isEmpty ? nil : command
                    expandedCommandText = command.isEmpty ? nil : command
                    expandedOutputText = outputTrimmed.isEmpty ? nil : outputTrimmed
                    prefersUnwrappedOutput = true
                    showSeparatedCommandAndOutput = true

                case "read":
                    if !outputTrimmed.isEmpty {
                        expandedText = outputTrimmed
                        let readFileType = Self.readOutputFileType(
                            args: args,
                            argsSummary: argsSummary
                        )
                        expandedOutputLanguage = Self.readOutputLanguage(
                            args: args,
                            argsSummary: argsSummary
                        )
                        if readFileType == .markdown {
                            expandedTextUsesMarkdown = true
                            expandedCodeStartLine = nil
                        } else if readFileType == .image {
                            expandedUsesReadMediaRenderer = true
                            expandedCodeStartLine = nil
                        } else {
                            expandedCodeStartLine = ToolCallFormatting.readStartLine(from: args)
                        }
                        expandedCodeFilePath = ToolCallFormatting.filePath(from: args)
                            ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
                    } else if toolOutputLoadState.isLoading(itemID) {
                        expandedText = "Loading read output…"
                    } else if isDone {
                        expandedText = "Waiting for output…"
                    }

                case "write":
                    if !outputTrimmed.isEmpty {
                        expandedText = outputTrimmed
                        expandedOutputLanguage = Self.readOutputLanguage(
                            args: args,
                            argsSummary: argsSummary
                        )
                        expandedCodeFilePath = ToolCallFormatting.filePath(from: args)
                            ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
                    }

                case "edit":
                    if !isError,
                       let editText = ToolCallFormatting.editOldAndNewText(from: args) {
                        let lines = DiffEngine.compute(old: editText.oldText, new: editText.newText)
                        expandedDiffLines = lines
                        expandedDiffPath = ToolCallFormatting.displayFilePath(
                            tool: normalizedTool,
                            args: args,
                            argsSummary: argsSummary
                        )
                        copyOutputText = DiffEngine.formatUnified(lines)
                    } else if !outputTrimmed.isEmpty {
                        expandedText = outputTrimmed
                        expandedOutputLanguage = Self.readOutputLanguage(
                            args: args,
                            argsSummary: argsSummary
                        )
                        expandedCodeFilePath = ToolCallFormatting.filePath(from: args)
                            ?? ToolCallFormatting.parseArgValue("path", from: argsSummary)
                    }

                case "todo":
                    if let todoMutationDiff {
                        expandedDiffLines = todoMutationDiff.diffLines
                        copyOutputText = todoMutationDiff.unifiedText
                    } else if let todoPresentation {
                        expandedText = todoPresentation.text
                        expandedTextUsesMarkdown = todoPresentation.usesMarkdown
                    } else if !outputTrimmed.isEmpty {
                        expandedText = outputTrimmed
                    }

                default:
                    if !outputTrimmed.isEmpty {
                        expandedText = outputTrimmed
                    }
                }
            }

            let trailing: String?
            if let editTrailingFallback {
                trailing = editTrailingFallback
            } else if normalizedTool == "todo",
                      todoMutationDiff == nil,
                      let todoTrailing = todoPresentation?.trailing,
                      !todoTrailing.isEmpty {
                trailing = todoTrailing
            } else {
                trailing = nil
            }

            if hasInlineMediaDataURI {
                if let existingBadge = languageBadge, !existingBadge.isEmpty {
                    languageBadge = "\(existingBadge) • ⚠︎media"
                } else {
                    languageBadge = "⚠︎media"
                }
            }

            return ToolTimelineRowConfiguration(
                title: title,
                preview: preview,
                expandedText: expandedText,
                expandedTextUsesMarkdown: expandedTextUsesMarkdown,
                expandedDiffLines: expandedDiffLines,
                expandedDiffPath: expandedDiffPath,
                expandedCommandText: expandedCommandText,
                expandedOutputText: expandedOutputText,
                expandedOutputLanguage: expandedOutputLanguage,
                expandedCodeStartLine: expandedCodeStartLine,
                expandedCodeFilePath: expandedCodeFilePath,
                expandedUsesReadMediaRenderer: expandedUsesReadMediaRenderer,
                prefersUnwrappedOutput: prefersUnwrappedOutput,
                showSeparatedCommandAndOutput: showSeparatedCommandAndOutput,
                copyCommandText: copyCommandText,
                copyOutputText: copyOutputText,
                languageBadge: languageBadge,
                trailing: trailing,
                titleLineBreakMode: titleLineBreakMode,
                toolNamePrefix: toolNamePrefix,
                toolNameColor: toolNameColor,
                editAdded: editAdded,
                editRemoved: editRemoved,
                isExpanded: isExpanded,
                isDone: isDone,
                isError: isError
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
            collectionView.scrollToItem(at: indexPath, at: position, animated: command.animated)

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

// MARK: - Load More Row

struct LoadMoreTimelineRowConfiguration: UIContentConfiguration {
    let hiddenCount: Int
    let renderWindowStep: Int
    let onTap: () -> Void
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        LoadMoreTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class LoadMoreTimelineRowContentView: UIView, UIContentView {
    private let button = UIButton(type: .system)
    private var currentConfiguration: LoadMoreTimelineRowConfiguration

    init(configuration: LoadMoreTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? LoadMoreTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func apply(configuration: LoadMoreTimelineRowConfiguration) {
        currentConfiguration = configuration

        let revealCount = min(configuration.renderWindowStep, configuration.hiddenCount)
        button.setTitle(
            "Show \(revealCount) earlier messages (\(configuration.hiddenCount) hidden)",
            for: .normal
        )
        button.setTitleColor(UIColor(configuration.themeID.palette.blue), for: .normal)
    }

    @objc
    private func handleTap() {
        currentConfiguration.onTap()
    }
}

// MARK: - Working Indicator Row

struct WorkingIndicatorTimelineRowConfiguration: UIContentConfiguration {
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        WorkingIndicatorTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class WorkingIndicatorTimelineRowContentView: UIView, UIContentView {
    private let rootStack = UIStackView()
    private let symbolLabel = UILabel()
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []

    private var isAnimatingDots = false
    private var currentConfiguration: WorkingIndicatorTimelineRowConfiguration

    init(configuration: WorkingIndicatorTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? WorkingIndicatorTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            startDotAnimationsIfNeeded()
        } else {
            stopDotAnimations()
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 8

        symbolLabel.translatesAutoresizingMaskIntoConstraints = false
        symbolLabel.text = "π"
        symbolLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)

        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.axis = .horizontal
        dotsStack.alignment = .center
        dotsStack.spacing = 4

        for _ in 0..<3 {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.layer.cornerRadius = 3
            dot.alpha = 0.6

            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])

            dotViews.append(dot)
            dotsStack.addArrangedSubview(dot)
        }

        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        rootStack.addArrangedSubview(symbolLabel)
        rootStack.addArrangedSubview(dotsStack)
        rootStack.addArrangedSubview(spacer)

        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func apply(configuration: WorkingIndicatorTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        symbolLabel.textColor = UIColor(palette.purple)
        for dot in dotViews {
            dot.backgroundColor = UIColor(palette.comment)
        }

        if window != nil {
            startDotAnimationsIfNeeded()
        }
    }

    private func startDotAnimationsIfNeeded() {
        guard !isAnimatingDots else { return }
        isAnimatingDots = true

        for dot in dotViews {
            dot.alpha = 0.58
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            return
        }

        let baseTime = CACurrentMediaTime()
        for (index, dot) in dotViews.enumerated() {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.46
            animation.toValue = 0.72
            animation.duration = 1.6
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = baseTime + Double(index) * 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer.add(animation, forKey: "pulse")
        }
    }

    private func stopDotAnimations() {
        guard isAnimatingDots else { return }
        isAnimatingDots = false

        for dot in dotViews {
            dot.layer.removeAnimation(forKey: "pulse")
            dot.alpha = 0.58
        }
    }
}

// MARK: - Audio Clip Row

struct AudioClipTimelineRowConfiguration: UIContentConfiguration {
    let id: String
    let title: String
    let fileURL: URL
    let audioPlayer: AudioPlayerService
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        AudioClipTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

private enum AudioClipButtonState {
    case idle
    case loading
    case playing
}

final class AudioClipTimelineRowContentView: UIView, UIContentView {
    private let containerView = UIView()
    private let rootStack = UIStackView()
    private let iconImageView = UIImageView()
    private let labelsStack = UIStackView()
    private let titleLabel = UILabel()
    private let fileNameLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private var currentConfiguration: AudioClipTimelineRowConfiguration

    init(configuration: AudioClipTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? AudioClipTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 8

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 10

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.image = UIImage(systemName: "waveform")

        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        labelsStack.spacing = 2

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.numberOfLines = 1

        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = .preferredFont(forTextStyle: .caption2)
        fileNameLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.numberOfLines = 1

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.contentHorizontalAlignment = .center
        playButton.contentVerticalAlignment = .center
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true

        addSubview(containerView)
        containerView.addSubview(rootStack)

        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(fileNameLabel)

        rootStack.addArrangedSubview(iconImageView)
        rootStack.addArrangedSubview(labelsStack)
        rootStack.addArrangedSubview(UIView())
        rootStack.addArrangedSubview(playButton)

        playButton.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            rootStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            rootStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            rootStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),

            iconImageView.widthAnchor.constraint(equalToConstant: 14),
            iconImageView.heightAnchor.constraint(equalToConstant: 14),

            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),

            loadingIndicator.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
        ])
    }

    private func apply(configuration: AudioClipTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        containerView.backgroundColor = UIColor(palette.bgDark)

        iconImageView.tintColor = UIColor(palette.purple)
        titleLabel.textColor = UIColor(palette.fg)
        fileNameLabel.textColor = UIColor(palette.comment)

        titleLabel.text = configuration.title
        fileNameLabel.text = configuration.fileURL.lastPathComponent

        loadingIndicator.color = UIColor(palette.purple)
        updatePlayButton(state: buttonState(for: configuration), palette: palette)
    }

    private func buttonState(for configuration: AudioClipTimelineRowConfiguration) -> AudioClipButtonState {
        if configuration.audioPlayer.loadingItemID == configuration.id {
            return .loading
        }

        if configuration.audioPlayer.playingItemID == configuration.id {
            return .playing
        }

        return .idle
    }

    private func updatePlayButton(state: AudioClipButtonState, palette: ThemePalette) {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        playButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)

        switch state {
        case .idle:
            loadingIndicator.stopAnimating()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            playButton.tintColor = UIColor(palette.comment)

        case .loading:
            playButton.setImage(nil, for: .normal)
            playButton.tintColor = UIColor(palette.purple)
            loadingIndicator.startAnimating()

        case .playing:
            loadingIndicator.stopAnimating()
            playButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            playButton.tintColor = UIColor(palette.purple)
        }
    }

    @objc
    private func togglePlayback() {
        currentConfiguration.audioPlayer.toggleFilePlayback(
            fileURL: currentConfiguration.fileURL,
            itemID: currentConfiguration.id
        )
        apply(configuration: currentConfiguration)
    }
}
