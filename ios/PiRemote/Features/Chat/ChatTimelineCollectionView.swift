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
        section.interGroupSpacing = 12
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
        private var theme: AppTheme = .tokyoNight
        private var currentThemeID: ThemeID = .tokyoNight

        private var currentIDs: [String] = []
        private var currentItemByID: [String: ChatItem] = [:]
        private var previousItemByID: [String: ChatItem] = [:]
        private var previousStreamingAssistantID: String?
        private var previousHiddenCount = 0
        private var previousThemeID: ThemeID?
        private var lastHandledScrollCommandNonce = 0
        private var toolOutputLoadState = ToolOutputLoadState()

        var _fetchToolOutputForTesting: ((_ sessionId: String, _ toolCallId: String) async throws -> String)?
        private(set) var _toolOutputCanceledCountForTesting = 0
        private(set) var _toolOutputStaleDiscardCountForTesting = 0
        private(set) var _toolOutputAppliedCountForTesting = 0

        var _toolOutputLoadTaskCountForTesting: Int {
            toolOutputLoadState.taskCount
        }

        var _loadingToolOutputIDsForTesting: Set<String> {
            toolOutputLoadState.loadingIDs
        }

        func _triggerLoadFullToolOutputForTesting(
            itemID: String,
            outputByteCount: Int,
            in collectionView: UICollectionView
        ) {
            loadFullToolOutputIfNeeded(itemID: itemID, outputByteCount: outputByteCount, in: collectionView)
        }

        deinit {
            let canceled = toolOutputLoadState.cancelAll()
            _toolOutputCanceledCountForTesting += canceled
        }

        func configureDataSource(collectionView: UICollectionView) {
            let chatRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, itemID in
                let configureStartNs = ChatTimelinePerf.timestampNs()
                guard let self,
                      let item = self.currentItemByID[itemID],
                      let reducer = self.reducer,
                      let toolOutputStore = self.toolOutputStore,
                      let toolArgsStore = self.toolArgsStore,
                      let connection = self.connection,
                      let audioPlayer = self.audioPlayer
                else {
                    cell.contentConfiguration = UIHostingConfiguration {
                        Color.clear.frame(height: 1)
                    }
                    .margins(.all, 0)
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "placeholder",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                if let userConfiguration = self.nativeUserConfiguration(itemID: itemID, item: item) {
                    cell.contentConfiguration = userConfiguration
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "user_native",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                if let assistantConfiguration = self.nativeAssistantConfiguration(itemID: itemID, item: item) {
                    cell.contentConfiguration = assistantConfiguration
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "assistant_native",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                if let thinkingConfiguration = self.nativeThinkingConfiguration(itemID: itemID, item: item) {
                    cell.contentConfiguration = thinkingConfiguration
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "thinking_native",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                if let toolConfiguration = self.nativeToolConfiguration(itemID: itemID, item: item) {
                    cell.contentConfiguration = toolConfiguration
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    ChatTimelinePerf.recordCellConfigure(
                        rowType: "tool_native",
                        durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                    )
                    return
                }

                cell.contentConfiguration = UIHostingConfiguration {
                    ChatItemRow(
                        item: item,
                        isStreaming: itemID == self.streamingAssistantID,
                        workspaceId: self.workspaceId,
                        sessionId: self.sessionId,
                        onFork: self.onFork,
                        onOpenFile: self.onOpenFile
                    )
                    .environment(reducer)
                    .environment(toolOutputStore)
                    .environment(toolArgsStore)
                    .environment(connection)
                    .environment(audioPlayer)
                    .environment(\.theme, self.theme)
                }
                .margins(.all, 0)
                cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                ChatTimelinePerf.recordCellConfigure(
                    rowType: self.rowTypeName(for: itemID),
                    durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                )
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
                cell.contentConfiguration = UIHostingConfiguration {
                    TimelineLoadMoreRow(
                        hiddenCount: self.hiddenCount,
                        renderWindowStep: self.renderWindowStep,
                        onTap: { self.onShowEarlier?() }
                    )
                }
                .margins(.all, 0)
                cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                ChatTimelinePerf.recordCellConfigure(
                    rowType: "load_more",
                    durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                )
            }

            let workingRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, _ in
                let configureStartNs = ChatTimelinePerf.timestampNs()
                cell.contentConfiguration = UIHostingConfiguration {
                    TimelineWorkingIndicatorRow()
                }
                .margins(.all, 0)
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

        func apply(configuration: Configuration, to collectionView: UICollectionView) {
            hiddenCount = configuration.hiddenCount
            renderWindowStep = configuration.renderWindowStep
            streamingAssistantID = configuration.streamingAssistantID

            if sessionId != configuration.sessionId || workspaceId != configuration.workspaceId {
                cancelAllToolOutputLoadTasks()
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
            audioPlayer = configuration.audioPlayer
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
            updateScrollState(collectionView)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            updateScrollState(collectionView)
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

            let cell = collectionView.cellForItem(at: indexPath)
            let isNativeToolCell = cell?.contentConfiguration is ToolTimelineRowConfiguration
            let isNativeThinkingCell = cell?.contentConfiguration is ThinkingTimelineRowConfiguration
            switch item {
            case .toolCall(_, _, _, _, let outputByteCount, _, _):
                guard isNativeToolCell else { return }
                let wasExpanded = reducer.expandedItemIDs.contains(itemID)
                if wasExpanded {
                    reducer.expandedItemIDs.remove(itemID)
                } else {
                    reducer.expandedItemIDs.insert(itemID)
                    loadFullToolOutputIfNeeded(
                        itemID: itemID,
                        outputByteCount: outputByteCount,
                        in: collectionView
                    )
                }
                animateNativeToolExpansion(itemID: itemID, item: item, isExpanding: !wasExpanded, in: collectionView)
            case .thinking(_, _, _, let isDone):
                guard isDone,
                      isNativeThinkingCell,
                      !reducer.expandedItemIDs.contains(itemID) else {
                    return
                }
                reducer.expandedItemIDs.insert(itemID)
                reconfigureItems([itemID], in: collectionView)

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

        private func rowTypeName(for itemID: String) -> String {
            if itemID == ChatTimelineCollectionView.loadMoreID {
                return "load_more"
            }
            if itemID == ChatTimelineCollectionView.workingIndicatorID {
                return "working_indicator"
            }

            guard let item = currentItemByID[itemID] else {
                return "unknown"
            }

            switch item {
            case .userMessage:
                return "user"
            case .assistantMessage:
                return "assistant"
            case .audioClip:
                return "audio"
            case .thinking:
                return "thinking"
            case .toolCall:
                return "tool"
            case .permission:
                return "permission"
            case .permissionResolved:
                return "permission_resolved"
            case .systemEvent:
                return "system"
            case .error:
                return "error"
            }
        }

        private func nativeAssistantConfiguration(itemID: String, item: ChatItem) -> AssistantTimelineRowConfiguration? {
            guard case .assistantMessage(_, let text, _) = item else { return nil }

            let isStreaming = itemID == streamingAssistantID
            if AssistantMarkdownFallbackHeuristics.shouldFallbackToSwiftUI(text, isStreaming: isStreaming) {
                return nil
            }

            // Fork targets are canonical user entry IDs from get_fork_messages.
            // Assistant rows are display nodes and may have synthetic IDs.
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
            guard images.isEmpty else { return nil }

            let canFork = UUID(uuidString: itemID) == nil && onFork != nil
            let forkAction: (() -> Void)?
            if canFork {
                forkAction = { [weak self] in
                    self?.onFork?(itemID)
                }
            } else {
                forkAction = nil
            }

            return UserTimelineRowConfiguration(
                text: text,
                canFork: canFork,
                onFork: forkAction,
                themeID: currentThemeID
            )
        }

        private func nativeThinkingConfiguration(itemID: String, item: ChatItem) -> ThinkingTimelineRowConfiguration? {
            guard case .thinking(_, _, _, let isDone) = item else { return nil }
            if reducer?.expandedItemIDs.contains(itemID) == true {
                return nil
            }

            return ThinkingTimelineRowConfiguration(isDone: isDone, themeID: currentThemeID)
        }

        private func nativeToolConfiguration(itemID: String, item: ChatItem) -> ToolTimelineRowConfiguration? {
            guard case .toolCall(_, let tool, let argsSummary, let outputPreview, let outputByteCount, let isError, let isDone) = item else {
                return nil
            }

            let args = toolArgsStore?.args(for: itemID)
            let normalizedTool = ToolCallFormatting.normalized(tool)
            let isExpanded = reducer?.expandedItemIDs.contains(itemID) == true

            // Keep file tools on SwiftUI path for reliable tappable file links
            // and rich expanded file rendering parity.
            if normalizedTool == "read" || normalizedTool == "write" || normalizedTool == "edit" {
                return nil
            }

            var title: String
            var preview: String?
            var toolNamePrefix: String?
            var toolNameColor = UIColor(Color.tokyoCyan)
            var titleLineBreakMode: NSLineBreakMode = .byTruncatingTail

            switch normalizedTool {
            case "bash":
                let compactCommand = ToolCallFormatting.bashCommand(args: args, argsSummary: argsSummary)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if isExpanded {
                    title = "$ bash"
                } else {
                    title = compactCommand.isEmpty ? "$ bash" : "$ \(compactCommand)"
                    titleLineBreakMode = .byTruncatingMiddle
                }
                toolNamePrefix = "$"
                toolNameColor = UIColor(Color.tokyoGreen)
                if isDone {
                    preview = ToolCallFormatting.tailLines(outputPreview, count: 1)
                }

            case "todo":
                let summary = ToolCallFormatting.todoSummary(args: args, argsSummary: argsSummary)
                title = summary.isEmpty ? "todo" : "todo \(summary)"
                toolNamePrefix = "todo"
                toolNameColor = UIColor(Color.tokyoPurple)

            default:
                title = argsSummary.isEmpty ? tool : "\(tool) \(argsSummary)"
                toolNamePrefix = tool
                toolNameColor = UIColor(Color.tokyoCyan)
                if isError, !outputPreview.isEmpty {
                    preview = String(outputPreview.prefix(180))
                }
            }

            if title.count > 240 {
                title = String(title.prefix(239)) + "…"
            }

            let fullOutput = toolOutputStore?.fullOutput(for: itemID) ?? ""
            var expandedText: String?
            var expandedCommandText: String?
            var expandedOutputText: String?
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
                    showSeparatedCommandAndOutput = true

                default:
                    if !outputTrimmed.isEmpty {
                        expandedText = outputTrimmed
                    }
                }
            }

            let trailing = outputByteCount > 0
                ? ToolCallFormatting.formatBytes(outputByteCount)
                : nil

            return ToolTimelineRowConfiguration(
                title: title,
                preview: preview,
                expandedText: expandedText,
                expandedCommandText: expandedCommandText,
                expandedOutputText: expandedOutputText,
                showSeparatedCommandAndOutput: showSeparatedCommandAndOutput,
                copyCommandText: copyCommandText,
                copyOutputText: copyOutputText,
                trailing: trailing,
                titleLineBreakMode: titleLineBreakMode,
                toolNamePrefix: toolNamePrefix,
                toolNameColor: toolNameColor,
                editAdded: nil,
                editRemoved: nil,
                isExpanded: isExpanded,
                isDone: isDone,
                isError: isError
            )
        }

        private func loadFullToolOutputIfNeeded(
            itemID: String,
            outputByteCount: Int,
            in collectionView: UICollectionView
        ) {
            guard outputByteCount > 0,
                  let toolOutputStore,
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
                        return
                    }

                    self.toolOutputStore?.append(output, to: itemID)
                    self._toolOutputAppliedCountForTesting += 1

                    if let collectionView {
                        self.reconfigureItems([itemID], in: collectionView)
                    }
                }
            }

            toolOutputLoadState.start(itemID: itemID, task: task)
        }

        private func cancelToolOutputLoadTasks(for itemIDs: Set<String>) {
            let canceled = toolOutputLoadState.cancel(for: itemIDs)
            _toolOutputCanceledCountForTesting += canceled
        }

        private func cancelAllToolOutputLoadTasks() {
            let canceled = toolOutputLoadState.cancelAll()
            _toolOutputCanceledCountForTesting += canceled
        }

        private func animateNativeToolExpansion(
            itemID: String,
            item: ChatItem,
            isExpanding: Bool,
            in collectionView: UICollectionView
        ) {
            guard let index = currentIDs.firstIndex(of: itemID),
                  let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)),
                  let configuration = nativeToolConfiguration(itemID: itemID, item: item)
            else {
                reconfigureItems([itemID], in: collectionView)
                return
            }
            collectionView.layoutIfNeeded()
            cell.contentConfiguration = configuration
            let duration = isExpanding ? ToolRowExpansionAnimation.expandDuration : ToolRowExpansionAnimation.collapseDuration
            let timing = isExpanding ? CAMediaTimingFunction(name: .easeInEaseOut) : CAMediaTimingFunction(name: .easeOut)
            let layoutToken = ChatTimelinePerf.beginLayoutPass(itemCount: currentIDs.count)
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(timing)
            CATransaction.setCompletionBlock { ChatTimelinePerf.endLayoutPass(layoutToken) }
            collectionView.performBatchUpdates { collectionView.collectionViewLayout.invalidateLayout() }
            CATransaction.commit()
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
            return true
        }

        private func updateScrollState(_ collectionView: UICollectionView) {
            guard let scrollController else { return }

            let insets = collectionView.adjustedContentInset
            let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
            guard visibleHeight > 0 else { return }

            let bottomY = collectionView.contentOffset.y + insets.top + visibleHeight
            let contentHeight = collectionView.contentSize.height
            let distanceFromBottom = max(0, contentHeight - bottomY)
            scrollController.updateNearBottom(distanceFromBottom <= 24)

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
private struct TimelineLoadMoreRow: View {
    let hiddenCount: Int
    let renderWindowStep: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("Show \(min(renderWindowStep, hiddenCount)) earlier messages (\(hiddenCount) hidden)")
                .font(.caption.monospaced())
                .foregroundStyle(.tokyoBlue)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct TimelineWorkingIndicatorRow: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("π")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.tokyoPurple)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.tokyoComment)
                        .frame(width: 6, height: 6)
                        .opacity(dotOpacity(index: i))
                }
            }
            .padding(.top, 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func dotOpacity(index: Int) -> Double {
        let offset = Double(index) / 3.0
        let adjusted = (phase + offset).truncatingRemainder(dividingBy: 1.0)
        return 0.52 + 0.18 * max(0, 1 - abs(adjusted - 0.5) * 2.6)
    }
}
