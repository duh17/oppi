import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("ChatTimelineCollectionHost.Controller")
struct ChatTimelineCoordinatorTests {

    @MainActor
    @Test func uniqueItemsKeepingLastRetainsLatestDuplicate() {
        let first = ChatItem.systemEvent(id: "dup", message: "first")
        let middle = ChatItem.error(id: "middle", message: "middle")
        let second = ChatItem.systemEvent(id: "dup", message: "second")

        let result = ChatTimelineCollectionHost.Controller.uniqueItemsKeepingLast([first, middle, second])

        #expect(result.orderedIDs == ["middle", "dup"])
        #expect(result.itemByID["dup"] == second)
        #expect(result.itemByID["middle"] == middle)
    }

    @MainActor
    @Test func toolOutputCompletionDispositionGuardsStaleAndCanceledStates() {
        #expect(
            ChatTimelineCollectionHost.Controller.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .apply
        )

        #expect(
            ChatTimelineCollectionHost.Controller.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: true,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .canceled
        )

        #expect(
            ChatTimelineCollectionHost.Controller.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s2",
                itemExists: true
            ) == .staleSession
        )

        #expect(
            ChatTimelineCollectionHost.Controller.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: false
            ) == .missingItem
        )

        #expect(
            ChatTimelineCollectionHost.Controller.toolOutputCompletionDisposition(
                output: "",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .emptyOutput
        )
    }

    @MainActor
    @Test func assistantMarkdownRowsRenderNatively() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let markdownItem = ChatItem.assistantMessage(
            id: "assistant-md-1",
            text: "# Heading\n\n```swift\nprint(\"hi\")\n```",
            timestamp: Date()
        )

        let config = makeTimelineConfiguration(
            items: [markdownItem],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let cell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        // Markdown-bearing assistant messages now render natively via
        // AssistantTimelineRowConfiguration — no SwiftUI fallback needed.
        let nativeConfig = try #require(cell.contentConfiguration as? AssistantTimelineRowConfiguration)
        #expect(nativeConfig.text.contains("# Heading"))
    }

    @MainActor
    @Test func userRowsWithImagesRenderNatively() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let imageItem = ChatItem.userMessage(
            id: "user-image-1",
            text: "",
            images: [ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")],
            timestamp: Date()
        )

        let config = makeTimelineConfiguration(
            items: [imageItem],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let cell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        let nativeConfig = try #require(cell.contentConfiguration as? UserTimelineRowConfiguration)
        #expect(nativeConfig.images.count == 1)
    }

    @MainActor
    @Test func permissionRowsRenderWithNativeConfiguration() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let pending = PermissionRequest(
            id: "perm-pending-1",
            sessionId: "session-a",
            tool: "bash",
            input: [:],
            displaySummary: "command: rm -rf /tmp/demo",
            reason: "filesystem write",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true
        )

        let rows: [ChatItem] = [
            .permission(pending),
            .permissionResolved(id: "perm-resolved-1", outcome: .allowed, tool: "bash", summary: "command: ls"),
        ]

        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let firstCell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        let secondCell = try configuredTimelineCell(in: harness.collectionView, item: 1)

        #expect(firstCell.contentConfiguration is PermissionTimelineRowConfiguration)
        #expect(secondCell.contentConfiguration is PermissionTimelineRowConfiguration)
    }

    @MainActor
    @Test func systemAndErrorRowsRenderWithNativeConfiguration() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .systemEvent(id: "system-1", message: "Model changed"),
            .error(id: "error-1", message: "Permission denied"),
        ]

        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let firstCell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        let secondCell = try configuredTimelineCell(in: harness.collectionView, item: 1)

        #expect(firstCell.contentConfiguration is SystemTimelineRowConfiguration)
        #expect(secondCell.contentConfiguration is ErrorTimelineRowConfiguration)
    }

    @MainActor
    @Test func compactionRowsRenderWithNativeConfiguration() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .systemEvent(
                id: "compaction-1",
                message: "Context compacted (12,345 tokens): ## Goal\n1. Keep calm"
            ),
        ]

        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let cell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        let compactionConfig = try #require(cell.contentConfiguration as? CompactionTimelineRowConfiguration)
        #expect(compactionConfig.presentation.phase == .completed)
        #expect(compactionConfig.presentation.tokensBefore == 12_345)
        #expect(compactionConfig.canExpand)
    }

    @MainActor
    @Test func thinkingRowsAutoRenderExpandedWithNativeConfiguration() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .thinking(id: "thinking-1", preview: "full reasoning block", hasMore: false, isDone: true),
        ]

        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let cell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        let thinkingConfig = try #require(cell.contentConfiguration as? ThinkingTimelineRowConfiguration)
        #expect(thinkingConfig.isDone)
        #expect(thinkingConfig.displayText == "full reasoning block")
    }

    @MainActor
    @Test func audioClipRowsRenderWithNativeConfiguration() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(
                id: "audio-1",
                title: "Harness Clip",
                fileURL: URL(fileURLWithPath: "/tmp/harness-audio.wav"),
                timestamp: Date()
            ),
        ]

        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let cell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        #expect(cell.contentConfiguration is AudioClipTimelineRowConfiguration)
    }

    @MainActor
    @Test func loadMoreAndWorkingRowsRenderWithNativeConfiguration() throws {
        var showEarlierTapped = 0

        do {
            let harness = makeTimelineHarness(sessionId: "session-a")
            let withHiddenRows = makeTimelineConfiguration(
                items: [.systemEvent(id: "system-1", message: "Context compacted")],
                hiddenCount: 4,
                renderWindowStep: 2,
                onShowEarlier: { showEarlierTapped += 1 },
                sessionId: "session-a",
                reducer: harness.reducer,
                toolOutputStore: harness.toolOutputStore,
                toolArgsStore: harness.toolArgsStore,
                connection: harness.connection,
                scrollController: harness.scrollController,
                audioPlayer: harness.audioPlayer
            )
            harness.coordinator.apply(configuration: withHiddenRows, to: harness.collectionView)

            let loadMoreCell = try configuredTimelineCell(in: harness.collectionView, item: 0)
            #expect(loadMoreCell.contentConfiguration is LoadMoreTimelineRowConfiguration)

            // sanity check closure is wired in config payload
            if let config = loadMoreCell.contentConfiguration as? LoadMoreTimelineRowConfiguration {
                config.onTap()
            }
            #expect(showEarlierTapped == 1)
        }

        do {
            let harness = makeTimelineHarness(sessionId: "session-a")
            let busy = makeTimelineConfiguration(
                items: [],
                isBusy: true,
                streamingAssistantID: nil,
                sessionId: "session-a",
                reducer: harness.reducer,
                toolOutputStore: harness.toolOutputStore,
                toolArgsStore: harness.toolArgsStore,
                connection: harness.connection,
                scrollController: harness.scrollController,
                audioPlayer: harness.audioPlayer
            )
            harness.coordinator.apply(configuration: busy, to: harness.collectionView)

            let workingCell = try configuredTimelineCell(in: harness.collectionView, item: 0)
            #expect(workingCell.contentConfiguration is WorkingIndicatorTimelineRowConfiguration)
        }
    }

    @MainActor
    @Test func tappingToolRowTogglesExpansionEvenWithoutMaterializedCell() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let toolID = "tool-read-1"

        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: toolID)
        let config = makeTimelineConfiguration(
            items: [
                .toolCall(
                    id: toolID,
                    tool: "read",
                    argsSummary: "path: src/main.swift",
                    outputPreview: "line1\nline2",
                    outputByteCount: 16,
                    isError: false,
                    isDone: true
                ),
            ],
            isBusy: true,
            streamingAssistantID: "assistant-streaming",
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        // Intentionally do not materialize the cell via `configuredTimelineCell(...)`.
        // Selection handling should still toggle expansion state based on item ID.
        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
    }

    @MainActor
    @Test func compactionChevronActionTogglesExpansionWhenSummaryIsLong() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let itemID = "compaction-expand-1"
        let summary = String(repeating: "keep-calm ", count: 24)

        let config = makeTimelineConfiguration(
            items: [
                .systemEvent(id: itemID, message: "Context compacted: \(summary)"),
            ],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )

        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let cell = try configuredTimelineCell(in: harness.collectionView, item: 0)
        let compactionConfig = try #require(cell.contentConfiguration as? CompactionTimelineRowConfiguration)
        let toggle = try #require(compactionConfig.onToggleExpand)

        toggle()
        #expect(harness.reducer.expandedItemIDs.contains(itemID))

        toggle()
        #expect(!harness.reducer.expandedItemIDs.contains(itemID))
    }

    @MainActor
    @Test func tappingCompactionRowDoesNotToggleExpansion() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let itemID = "compaction-expand-1"
        let summary = String(repeating: "keep-calm ", count: 24)

        let config = makeTimelineConfiguration(
            items: [
                .systemEvent(id: itemID, message: "Context compacted: \(summary)"),
            ],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )

        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(!harness.reducer.expandedItemIDs.contains(itemID))
    }

    @MainActor
    @Test func permissionRowContentViewReportsFiniteFittingSize() {
        let config = PermissionTimelineRowConfiguration(
            outcome: .allowed,
            tool: "bash",
            summary: "command: rm -rf /tmp/demo",
            themeID: .dark
        )

        let view = PermissionTimelineRowContentView(configuration: config)
        let fitting = view.systemLayoutSizeFitting(
            CGSize(width: 338, height: UIView.layoutFittingExpandedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        #expect(fitting.width.isFinite)
        #expect(fitting.height.isFinite)
        #expect(fitting.height < 10_000)
    }

    @MainActor
    @Test func compactionRowContentViewReportsFiniteFittingSize() {
        let config = CompactionTimelineRowConfiguration(
            presentation: .init(
                phase: .completed,
                detail: "## Goal\n1. Continue migration\n2. Keep animations subtle",
                tokensBefore: 98_765
            ),
            isExpanded: false,
            themeID: .dark
        )

        let view = CompactionTimelineRowContentView(configuration: config)
        let fitting = fittedTimelineSize(for: view, width: 338)

        #expect(fitting.width.isFinite)
        #expect(fitting.height.isFinite)
        #expect(fitting.height < 10_000)
    }

    @MainActor
    @Test func compactionRowCollapsedDetailUsesSingleLinePreview() throws {
        let config = CompactionTimelineRowConfiguration(
            presentation: .init(
                phase: .completed,
                detail: "## Goal\n1. Continue migration\n2. Keep animations subtle",
                tokensBefore: 98_765
            ),
            isExpanded: false,
            themeID: .dark
        )

        let view = CompactionTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 338)

        let detailLabel = try #require(timelineAllLabels(in: view).first {
            timelineRenderedText(of: $0).contains("Goal") || timelineRenderedText(of: $0).contains("Continue migration")
        })

        #expect(detailLabel.numberOfLines == 1)
    }

    @MainActor
    @Test func compactionRowExpandedUsesMarkdownRenderer() throws {
        let config = CompactionTimelineRowConfiguration(
            presentation: .init(
                phase: .completed,
                detail: "## Goal\n1. Continue migration\n2. Keep animations subtle",
                tokensBefore: 98_765
            ),
            isExpanded: true,
            themeID: .dark
        )

        let view = CompactionTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 338)

        let markdownView = try #require(timelineFirstView(ofType: AssistantMarkdownContentView.self, in: view))
        #expect(!markdownView.isHidden)

        let rendered = timelineAllTextViews(in: markdownView)
            .map { $0.attributedText?.string ?? $0.text ?? "" }
            .joined(separator: "\n")
        #expect(rendered.contains("Goal"))
    }

    @MainActor
    @Test func compactionRowCollapseAfterExpandShrinksHeight() {
        let detail = String(repeating: "reasoning line\n", count: 100)

        // Expand first: markdown view renders fully.
        let expandedConfig = CompactionTimelineRowConfiguration(
            presentation: .init(phase: .completed, detail: detail, tokensBefore: 42_000),
            isExpanded: true,
            themeID: .dark
        )
        let view = CompactionTimelineRowContentView(configuration: expandedConfig)
        let expandedSize = fittedTimelineSize(for: view, width: 338)

        // Collapse: reconfigure with isExpanded = false.
        let collapsedConfig = CompactionTimelineRowConfiguration(
            presentation: .init(phase: .completed, detail: detail, tokensBefore: 42_000),
            isExpanded: false,
            themeID: .dark
        )
        view.configuration = collapsedConfig
        let collapsedSize = fittedTimelineSize(for: view, width: 338)

        // Collapsed must be substantially shorter than expanded (header + 1-line detail).
        // Expanded 100 lines of text should be > 500pt. Collapsed should be < 80pt.
        #expect(expandedSize.height > 200, "expanded should be tall, got \(expandedSize.height)")
        #expect(collapsedSize.height < 80, "collapsed should shrink, got \(collapsedSize.height)")
    }

    @MainActor
    @Test func assistantRowContentViewReportsFiniteFittingSizeForMarkdown() {
        let markdown = """
        # Opus Session

        | Key | Value |
        | --- | ----- |
        | mode | opus |
        | state | active |

        ```swift
        for i in 0..<200 {
            print("line \\(i)")
        }
        ```
        """

        let config = AssistantTimelineRowConfiguration(
            text: markdown,
            isStreaming: false,
            canFork: false,
            onFork: nil,
            themeID: .dark
        )

        let view = AssistantTimelineRowContentView(configuration: config)
        let fitting = fittedTimelineSize(for: view, width: 338)

        #expect(fitting.width.isFinite)
        #expect(fitting.height.isFinite)
        #expect(fitting.height < 10_000)
    }

    @MainActor
    @Test func audioClipRowContentViewReportsFiniteFittingSize() {
        let config = AudioClipTimelineRowConfiguration(
            id: "audio-1",
            title: "Harness Clip",
            fileURL: URL(fileURLWithPath: "/tmp/harness-audio.wav"),
            audioPlayer: AudioPlayerService(),
            themeID: .dark
        )

        let view = AudioClipTimelineRowContentView(configuration: config)
        let fitting = fittedTimelineSize(for: view, width: 338)

        #expect(fitting.width.isFinite)
        #expect(fitting.height.isFinite)
        #expect(fitting.height < 10_000)
    }

    @MainActor
    @Test func thinkingRowContentViewExpandedReportsFiniteFittingSize() {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "preview",
            fullText: String(repeating: "reasoning line\n", count: 500),
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        let fitting = fittedTimelineSize(for: view, width: 338)

        #expect(fitting.width.isFinite)
        #expect(fitting.height.isFinite)
        #expect(fitting.height < 10_000)
    }

    @MainActor
    @Test func thinkingRowExpandedUsesCappedViewportHeight() {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "preview",
            fullText: String(repeating: "reasoning line\n", count: 900),
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        let fitting = fittedTimelineSize(for: view, width: 338)

        #expect(fitting.height < 280)
        #expect(fitting.height > 140)
    }

    @MainActor
    @Test func thinkingRowExpandedShrinksForShortText() {
        let short = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "preview",
            fullText: "short thought",
            themeID: .dark
        )
        let long = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "preview",
            fullText: String(repeating: "reasoning line\n", count: 900),
            themeID: .dark
        )

        let shortView = ThinkingTimelineRowContentView(configuration: short)
        let longView = ThinkingTimelineRowContentView(configuration: long)

        let shortSize = fittedTimelineSize(for: shortView, width: 338)
        let longSize = fittedTimelineSize(for: longView, width: 338)

        #expect(shortSize.height < longSize.height)
    }

    @MainActor
    @Test func thinkingRowShowsTextContent() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "Reviewing checklist for updates",
            fullText: nil,
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 338)

        let label = try #require(timelineAllLabels(in: view).first { $0.text?.contains("Reviewing") == true })
        #expect(label.text == "Reviewing checklist for updates")
    }

    @MainActor
    @Test func thinkingRowStreamingShowsLivePreviewText() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "Let me analyze this step by step",
            fullText: nil,
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        let fitting = fittedTimelineSize(for: view, width: 338)

        // Should have nonzero height (spinner header + preview container)
        #expect(fitting.height > 20)

        // Preview text should be rendered in a label
        let label = try #require(timelineAllLabels(in: view).first { $0.text?.contains("Let me analyze") == true })
        #expect(label.text?.contains("Let me analyze") == true)
    }

    @MainActor
    @Test func thinkingRowStreamingWithEmptyPreviewHidesContainer() {
        let config = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "",
            fullText: nil,
            themeID: .dark
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedTimelineSize(for: view, width: 338)

        // No content labels should have thinking text
        let labels = timelineAllLabels(in: view)
        let thinkingLabels = labels.filter { !($0.text ?? "").isEmpty && $0.text != "Thinking…" }
        #expect(thinkingLabels.isEmpty)
    }

    @MainActor
    @Test func thinkingRowStreamingGrowsWithPreviewText() {
        let short = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: "hmm",
            fullText: nil,
            themeID: .dark
        )
        let long = ThinkingTimelineRowConfiguration(
            isDone: false,
            previewText: String(repeating: "thinking about this problem ", count: 15),
            fullText: nil,
            themeID: .dark
        )

        let shortView = ThinkingTimelineRowContentView(configuration: short)
        let longView = ThinkingTimelineRowContentView(configuration: long)

        let shortSize = fittedTimelineSize(for: shortView, width: 338)
        let longSize = fittedTimelineSize(for: longView, width: 338)

        #expect(longSize.height > shortSize.height)
    }

    @MainActor
    @Test func audioStateChangeReconfiguresAffectedAudioRows() async {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(id: "audio-1", title: "Clip 1", fileURL: URL(fileURLWithPath: "/tmp/audio-1.wav"), timestamp: Date()),
            .systemEvent(id: "system-1", message: "separator"),
            .audioClip(id: "audio-2", title: "Clip 2", fileURL: URL(fileURLWithPath: "/tmp/audio-2.wav"), timestamp: Date()),
        ]
        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        NotificationCenter.default.post(
            name: AudioPlayerService.stateDidChangeNotification,
            object: harness.audioPlayer,
            userInfo: [
                AudioPlayerService.previousPlayingItemIDUserInfoKey: "audio-1",
                AudioPlayerService.playingItemIDUserInfoKey: "audio-2",
                AudioPlayerService.previousLoadingItemIDUserInfoKey: "",
                AudioPlayerService.loadingItemIDUserInfoKey: "",
            ]
        )

        #expect(await waitForTimelineCondition(timeoutMs: 300) {
            await MainActor.run {
                harness.coordinator._audioStateRefreshCountForTesting == 1
            }
        })

        #expect(harness.coordinator._audioStateRefreshedItemIDsForTesting == ["audio-1", "audio-2"])
    }

    @MainActor
    @Test func audioStateChangeWithoutIDsRefreshesAllVisibleAudioRows() async {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(id: "audio-1", title: "Clip 1", fileURL: URL(fileURLWithPath: "/tmp/audio-1.wav"), timestamp: Date()),
            .audioClip(id: "audio-2", title: "Clip 2", fileURL: URL(fileURLWithPath: "/tmp/audio-2.wav"), timestamp: Date()),
        ]
        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        NotificationCenter.default.post(
            name: AudioPlayerService.stateDidChangeNotification,
            object: harness.audioPlayer,
            userInfo: nil
        )

        #expect(await waitForTimelineCondition(timeoutMs: 300) {
            await MainActor.run {
                harness.coordinator._audioStateRefreshCountForTesting == 1
            }
        })

        #expect(harness.coordinator._audioStateRefreshedItemIDsForTesting == ["audio-1", "audio-2"])
    }

    @MainActor
    @Test func audioStateChangeFromDifferentPlayerIsIgnored() async {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(id: "audio-1", title: "Clip 1", fileURL: URL(fileURLWithPath: "/tmp/audio-1.wav"), timestamp: Date()),
        ]
        let config = makeTimelineConfiguration(
            items: rows,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: config, to: harness.collectionView)

        let otherPlayer = AudioPlayerService()
        NotificationCenter.default.post(
            name: AudioPlayerService.stateDidChangeNotification,
            object: otherPlayer,
            userInfo: [
                AudioPlayerService.playingItemIDUserInfoKey: "audio-1",
            ]
        )

        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.coordinator._audioStateRefreshCountForTesting == 0)
    }
}
