import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("ChatTimelineCollectionView.Coordinator")
struct ChatTimelineCollectionViewCoordinatorTests {

    @MainActor
    @Test func uniqueItemsKeepingLastRetainsLatestDuplicate() {
        let first = ChatItem.systemEvent(id: "dup", message: "first")
        let middle = ChatItem.error(id: "middle", message: "middle")
        let second = ChatItem.systemEvent(id: "dup", message: "second")

        let result = ChatTimelineCollectionView.Coordinator.uniqueItemsKeepingLast([first, middle, second])

        #expect(result.orderedIDs == ["middle", "dup"])
        #expect(result.itemByID["dup"] == second)
        #expect(result.itemByID["middle"] == middle)
    }

    @MainActor
    @Test func toolOutputCompletionDispositionGuardsStaleAndCanceledStates() {
        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .apply
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: true,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .canceled
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s2",
                itemExists: true
            ) == .staleSession
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "ok",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: false
            ) == .missingItem
        )

        #expect(
            ChatTimelineCollectionView.Coordinator.toolOutputCompletionDisposition(
                output: "",
                isTaskCancelled: false,
                activeSessionID: "s1",
                currentSessionID: "s1",
                itemExists: true
            ) == .emptyOutput
        )
    }

    @MainActor
    @Test func inlineMediaWarningHeuristicDoesNotFlagParityTools() {
        let sample = "let sample = \"data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==\""

        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "read",
                outputPreview: sample,
                fullOutput: ""
            )
        )
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "functions.read",
                outputPreview: "",
                fullOutput: sample
            )
        )
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "write",
                outputPreview: sample,
                fullOutput: ""
            )
        )
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "tools/write",
                outputPreview: "",
                fullOutput: sample
            )
        )
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "edit",
                outputPreview: sample,
                fullOutput: ""
            )
        )
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "todo",
                outputPreview: sample,
                fullOutput: ""
            )
        )
    }

    @MainActor
    @Test func inlineMediaWarningHeuristicKeepsBashPlainText() {
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "bash",
                outputPreview: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==",
                fullOutput: ""
            )
        )

        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "functions.bash",
                outputPreview: "",
                fullOutput: "before data:audio/wav;base64,UklGRg== after"
            )
        )

        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "bash\n",
                outputPreview: "plain output",
                fullOutput: ""
            )
        )
    }

    @MainActor
    @Test func inlineMediaWarningHeuristicDetectsDataURIsForNonBashTools() {
        #expect(
            ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "grep",
                outputPreview: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==",
                fullOutput: ""
            )
        )

        #expect(
            ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "find",
                outputPreview: "",
                fullOutput: "before data:audio/wav;base64,UklGRg== after"
            )
        )
    }

    @MainActor
    @Test func inlineMediaToolsStayNativeAndSurfaceWarningBadge() throws {
        let harness = makeHarness(sessionId: "session-a")
        let item = ChatItem.toolCall(
            id: "grep-media-1",
            tool: "grep",
            argsSummary: "pattern: data",
            outputPreview: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==",
            outputByteCount: 128,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.languageBadge == "⚠︎media")
    }

    @MainActor
    @Test func collapsedParityToolsUseNativeToolConfiguration() {
        let harness = makeHarness(sessionId: "session-a")

        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "read-1")
        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "read-2")
        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "write-1")
        harness.toolArgsStore.set([
            "path": .string("src/main.swift"),
            "oldText": .string("let value = 1\n"),
            "newText": .string("let value = 2\n"),
        ], for: "edit-1")

        let rows: [ChatItem] = [
            .toolCall(id: "read-1", tool: "read", argsSummary: "path: src/main.swift", outputPreview: "line1\nline2", outputByteCount: 32, isError: false, isDone: true),
            .toolCall(id: "read-2", tool: "functions.read", argsSummary: "path: src/main.swift", outputPreview: "line1\nline2", outputByteCount: 32, isError: false, isDone: true),
            .toolCall(id: "write-1", tool: "write", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 16, isError: false, isDone: true),
            .toolCall(id: "edit-1", tool: "edit", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 16, isError: false, isDone: true),
            .toolCall(id: "todo-1", tool: "todo", argsSummary: "action: list-all", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
        ]

        for row in rows {
            #expect(harness.coordinator.nativeToolConfiguration(itemID: row.id, item: row) != nil)
        }
    }

    @MainActor
    @Test func toolRowsRenderWithNativeToolConfigurationAcrossStates() throws {
        let harness = makeHarness(sessionId: "session-a")

        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "read-1")
        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "write-1")
        harness.toolArgsStore.set([
            "path": .string("src/main.swift"),
            "oldText": .string("let value = 1\n"),
            "newText": .string("let value = 2\n"),
        ], for: "edit-1")
        harness.toolArgsStore.set(["command": .string("echo hi")], for: "bash-1")

        let rows: [ChatItem] = [
            .toolCall(id: "bash-1", tool: "bash", argsSummary: "command: echo hi", outputPreview: "", outputByteCount: 0, isError: false, isDone: false),
            .toolCall(id: "read-1", tool: "read", argsSummary: "path: src/main.swift", outputPreview: "line1\nline2", outputByteCount: 32, isError: false, isDone: true),
            .toolCall(id: "write-1", tool: "write", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 16, isError: false, isDone: true),
            .toolCall(id: "edit-1", tool: "edit", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 16, isError: false, isDone: true),
            .toolCall(id: "todo-1", tool: "todo", argsSummary: "action: list-all", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
        ]

        let config = makeConfiguration(
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

        for index in rows.indices {
            let cell = try configuredCell(in: harness.collectionView, item: index)
            #expect(cell.contentConfiguration is ToolTimelineRowConfiguration)
        }
    }

    @MainActor
    @Test func editToolWithoutDiffArgsUsesModifiedTrailingFallback() throws {
        let harness = makeHarness(sessionId: "session-a")
        let item = ChatItem.toolCall(
            id: "edit-unknown-diff",
            tool: "edit",
            argsSummary: "path: src/main.swift",
            outputPreview: "",
            outputByteCount: 0,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.editAdded == nil)
        #expect(config.editRemoved == nil)
        #expect(config.trailing == "modified")
    }

    @MainActor
    @Test func expandedEditToolUsesNativeDiffLines() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("edit-diff")
        harness.toolArgsStore.set([
            "oldText": .string("let value = 1\nlet unchanged = true\n"),
            "newText": .string("let value = 2\nlet unchanged = true\nlet added = true\n"),
            "path": .string("src/main.swift"),
        ], for: "edit-diff")

        let item = ChatItem.toolCall(
            id: "edit-diff",
            tool: "edit",
            argsSummary: "path: src/main.swift",
            outputPreview: "",
            outputByteCount: 0,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        let diffLines = try #require(config.expandedDiffLines)

        let stats = diffLines.reduce(into: (added: 0, removed: 0)) { acc, line in
            switch line.kind {
            case .added:
                acc.added += 1
            case .removed:
                acc.removed += 1
            case .context:
                break
            }
        }

        #expect(stats.added > 0)
        #expect(stats.removed > 0)
        #expect(config.expandedText == nil)
    }

    @MainActor
    @Test func expandedEditToolFallbackOutputKeepsSyntaxLanguageFromPath() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("edit-fallback")
        harness.toolArgsStore.set([
            "path": .string("src/feature.ts"),
        ], for: "edit-fallback")

        let item = ChatItem.toolCall(
            id: "edit-fallback",
            tool: "edit",
            argsSummary: "path: src/feature.ts",
            outputPreview: "const value = 1",
            outputByteCount: 16,
            isError: true,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.expandedDiffLines == nil)
        #expect(config.expandedOutputLanguage == .typescript)
        #expect(config.expandedCodeFilePath == "src/feature.ts")
    }

    @MainActor
    @Test func expandedReadToolDetectsSyntaxLanguageFromFilePath() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("read-swift")
        harness.toolArgsStore.set([
            "path": .string("Runtime/TimelineReducer.swift"),
            "offset": .number(270),
            "limit": .number(60),
        ], for: "read-swift")

        let item = ChatItem.toolCall(
            id: "read-swift",
            tool: "read",
            argsSummary: "path: Runtime/TimelineReducer.swift",
            outputPreview: "guard value else { return }",
            outputByteCount: 42,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.expandedOutputLanguage == .swift)
        #expect(config.languageBadge == "Swift")
        #expect(config.expandedText != nil)
        #expect(config.expandedCodeStartLine == 270)
        #expect(config.expandedCodeFilePath == "Runtime/TimelineReducer.swift")
    }

    @MainActor
    @Test func expandedReadToolFallsBackToArgsSummaryPathWhenArgsMissing() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("read-fallback")

        let item = ChatItem.toolCall(
            id: "read-fallback",
            tool: "read",
            argsSummary: "path: Sources/Agent.swift",
            outputPreview: "let value = 1",
            outputByteCount: 12,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.expandedCodeStartLine == 1)
        #expect(config.expandedCodeFilePath == "Sources/Agent.swift")
    }

    @MainActor
    @Test func expandedWriteToolDetectsSyntaxLanguageFromPath() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("write-swift")
        harness.toolArgsStore.set([
            "path": .string("Sources/Generated.swift"),
        ], for: "write-swift")

        let item = ChatItem.toolCall(
            id: "write-swift",
            tool: "write",
            argsSummary: "path: Sources/Generated.swift",
            outputPreview: "struct Generated {}",
            outputByteCount: 20,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.expandedOutputLanguage == .swift)
        #expect(config.expandedCodeStartLine == nil)
        #expect(config.expandedCodeFilePath == "Sources/Generated.swift")
    }

    @MainActor
    @Test func expandedReadMarkdownUsesMarkdownRendererAndSkipsCodeLineNumbers() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("read-md")
        harness.toolArgsStore.set([
            "path": .string("docs/README.md"),
            "offset": .number(1),
            "limit": .number(80),
        ], for: "read-md")

        let item = ChatItem.toolCall(
            id: "read-md",
            tool: "read",
            argsSummary: "path: docs/README.md",
            outputPreview: "# Title",
            outputByteCount: 80,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.expandedTextUsesMarkdown)
        #expect(config.expandedCodeStartLine == nil)
        #expect(config.languageBadge == "Markdown")
    }

    @MainActor
    @Test func expandedParityToolsUseNativeToolConfiguration() {
        let harness = makeHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .toolCall(id: "read-1", tool: "read", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "read-2", tool: "functions.read", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "write-1", tool: "write", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "edit-1", tool: "edit", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "todo-1", tool: "todo", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
        ]

        for row in rows {
            harness.reducer.expandedItemIDs.insert(row.id)
            #expect(harness.coordinator.nativeToolConfiguration(itemID: row.id, item: row) != nil)
        }
    }

    @MainActor
    @Test func expandedTodoToolFormatsListOutputForReadableNativeRendering() throws {
        let harness = makeHarness(sessionId: "session-a")
        let itemID = "todo-list-1"
        harness.reducer.expandedItemIDs.insert(itemID)
        harness.toolArgsStore.set(["action": .string("list-all")], for: itemID)
        harness.toolOutputStore.append(
            """
            {
              "assigned": [
                {
                  "id": "TODO-a27df231",
                  "title": "Control tower Live Activity",
                  "status": "in_progress"
                }
              ],
              "open": [
                {
                  "id": "TODO-9a0c8c1c",
                  "title": "MAC phase",
                  "status": "open"
                }
              ],
              "closed": []
            }
            """,
            to: itemID
        )

        let item = ChatItem.toolCall(
            id: itemID,
            tool: "todo",
            argsSummary: "action: list-all",
            outputPreview: "",
            outputByteCount: 512,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: itemID, item: item))
        #expect(config.expandedTextUsesMarkdown)
        #expect(config.expandedText?.contains("### Assigned (1)") == true)
        #expect(config.expandedText?.contains("TODO-a27df231") == true)
        #expect(config.trailing == "A1 O1 C0")
    }

    @MainActor
    @Test func expandedTodoAppendUsesAddedOnlyDiffPresentation() throws {
        let harness = makeHarness(sessionId: "session-a")
        let itemID = "todo-append-1"
        harness.reducer.expandedItemIDs.insert(itemID)
        harness.toolArgsStore.set([
            "action": .string("append"),
            "id": .string("TODO-463187a1"),
            "body": .string("Investigate smooth scroll follow\nAdd regression tests")
        ], for: itemID)

        let item = ChatItem.toolCall(
            id: itemID,
            tool: "todo",
            argsSummary: "action: append, id: TODO-463187a1",
            outputPreview: "",
            outputByteCount: 4096,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: itemID, item: item))
        #expect(config.editAdded == 2)
        #expect(config.editRemoved == 0)
        #expect(config.trailing == nil)
        #expect(config.expandedText == nil)
        #expect(config.expandedDiffLines?.count == 2)
        #expect(config.copyOutputText?.contains("+ Investigate smooth scroll follow") == true)
    }

    @MainActor
    @Test func expandedTodoUpdateUsesDiffPresentationForChangedFields() throws {
        let harness = makeHarness(sessionId: "session-a")
        let itemID = "todo-update-1"
        harness.reducer.expandedItemIDs.insert(itemID)
        harness.toolArgsStore.set([
            "action": .string("update"),
            "id": .string("TODO-463187a1"),
            "status": .string("closed"),
            "title": .string("Refine auto-follow scrolling during streaming"),
            "body": .string("Done.\nValidated on simulator and device.")
        ], for: itemID)

        let item = ChatItem.toolCall(
            id: itemID,
            tool: "todo",
            argsSummary: "action: update, id: TODO-463187a1",
            outputPreview: "",
            outputByteCount: 2048,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: itemID, item: item))
        let diffLines = try #require(config.expandedDiffLines)

        #expect(config.editAdded == 5)
        #expect(config.editRemoved == 0)
        #expect(config.trailing == nil)
        #expect(config.expandedText == nil)
        #expect(diffLines.contains(where: { line in
            switch line.kind {
            case .added:
                return line.text == "status: closed"
            case .context, .removed:
                return false
            }
        }))
        #expect(config.copyOutputText?.contains("+ status: closed") == true)
    }

    @MainActor
    @Test func assistantMarkdownRowsRenderNatively() throws {
        let harness = makeHarness(sessionId: "session-a")

        let markdownItem = ChatItem.assistantMessage(
            id: "assistant-md-1",
            text: "# Heading\n\n```swift\nprint(\"hi\")\n```",
            timestamp: Date()
        )

        let config = makeConfiguration(
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

        let cell = try configuredCell(in: harness.collectionView, item: 0)
        // Markdown-bearing assistant messages now render natively via
        // AssistantTimelineRowConfiguration — no SwiftUI fallback needed.
        let nativeConfig = try #require(cell.contentConfiguration as? AssistantTimelineRowConfiguration)
        #expect(nativeConfig.text.contains("# Heading"))
    }

    @MainActor
    @Test func userRowsWithImagesRenderNatively() throws {
        let harness = makeHarness(sessionId: "session-a")

        let imageItem = ChatItem.userMessage(
            id: "user-image-1",
            text: "",
            images: [ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")],
            timestamp: Date()
        )

        let config = makeConfiguration(
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

        let cell = try configuredCell(in: harness.collectionView, item: 0)
        let nativeConfig = try #require(cell.contentConfiguration as? UserTimelineRowConfiguration)
        #expect(nativeConfig.images.count == 1)
    }

    @MainActor
    @Test func expandedFileAndDiffToolsRenderViaNativePathWithoutFailsafe() throws {
        let harness = makeHarness(sessionId: "session-a")
        ChatTimelinePerf.reset()

        harness.reducer.expandedItemIDs.insert("read-tool-1")
        harness.reducer.expandedItemIDs.insert("edit-tool-1")

        let rows: [ChatItem] = [
            .toolCall(id: "read-tool-1", tool: "read", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 64, isError: false, isDone: true),
            .toolCall(id: "edit-tool-1", tool: "edit", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 128, isError: false, isDone: true),
        ]

        let config = makeConfiguration(
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

        let firstCell = try configuredCell(in: harness.collectionView, item: 0)
        let secondCell = try configuredCell(in: harness.collectionView, item: 1)

        #expect(firstCell.contentConfiguration is ToolTimelineRowConfiguration)
        #expect(secondCell.contentConfiguration is ToolTimelineRowConfiguration)

        let snapshot = ChatTimelinePerf.snapshot()
        #expect(snapshot.failsafeConfigureCount == 0)
    }

    @MainActor
    @Test func collapsedParityToolsRenderViaNativeShellWithoutFailsafe() throws {
        let harness = makeHarness(sessionId: "session-a")
        ChatTimelinePerf.reset()

        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "read-tool-1")
        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "write-tool-1")
        harness.toolArgsStore.set([
            "path": .string("src/main.swift"),
            "oldText": .string("let value = 1\n"),
            "newText": .string("let value = 2\n"),
        ], for: "edit-tool-1")

        let rows: [ChatItem] = [
            .toolCall(id: "read-tool-1", tool: "functions.read", argsSummary: "path: src/main.swift", outputPreview: "line1\nline2", outputByteCount: 64, isError: false, isDone: true),
            .toolCall(id: "write-tool-1", tool: "write", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 128, isError: false, isDone: true),
            .toolCall(id: "edit-tool-1", tool: "edit", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 128, isError: false, isDone: true),
            .toolCall(id: "todo-tool-1", tool: "todo", argsSummary: "action: list", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
        ]

        let config = makeConfiguration(
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

        for index in rows.indices {
            let cell = try configuredCell(in: harness.collectionView, item: index)
            #expect(cell.contentConfiguration is ToolTimelineRowConfiguration)
        }

        let snapshot = ChatTimelinePerf.snapshot()
        #expect(snapshot.failsafeConfigureCount == 0)
    }

    @MainActor
    @Test func permissionRowsRenderWithNativeConfiguration() throws {
        let harness = makeHarness(sessionId: "session-a")

        let pending = PermissionRequest(
            id: "perm-pending-1",
            sessionId: "session-a",
            tool: "bash",
            input: [:],
            displaySummary: "command: rm -rf /tmp/demo",
            risk: .high,
            reason: "filesystem write",
            timeoutAt: Date().addingTimeInterval(60),
            expires: true,
            resolutionOptions: nil
        )

        let rows: [ChatItem] = [
            .permission(pending),
            .permissionResolved(id: "perm-resolved-1", outcome: .allowed, tool: "bash", summary: "command: ls"),
        ]

        let config = makeConfiguration(
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

        let firstCell = try configuredCell(in: harness.collectionView, item: 0)
        let secondCell = try configuredCell(in: harness.collectionView, item: 1)

        #expect(firstCell.contentConfiguration is PermissionTimelineRowConfiguration)
        #expect(secondCell.contentConfiguration is PermissionTimelineRowConfiguration)
    }

    @MainActor
    @Test func systemAndErrorRowsRenderWithNativeConfiguration() throws {
        let harness = makeHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .systemEvent(id: "system-1", message: "Model changed"),
            .error(id: "error-1", message: "Permission denied"),
        ]

        let config = makeConfiguration(
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

        let firstCell = try configuredCell(in: harness.collectionView, item: 0)
        let secondCell = try configuredCell(in: harness.collectionView, item: 1)

        #expect(firstCell.contentConfiguration is SystemTimelineRowConfiguration)
        #expect(secondCell.contentConfiguration is ErrorTimelineRowConfiguration)
    }

    @MainActor
    @Test func compactionRowsRenderWithNativeConfiguration() throws {
        let harness = makeHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .systemEvent(
                id: "compaction-1",
                message: "Context compacted (12,345 tokens): ## Goal\n1. Keep calm"
            ),
        ]

        let config = makeConfiguration(
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

        let cell = try configuredCell(in: harness.collectionView, item: 0)
        let compactionConfig = try #require(cell.contentConfiguration as? CompactionTimelineRowConfiguration)
        #expect(compactionConfig.presentation.phase == .completed)
        #expect(compactionConfig.presentation.tokensBefore == 12_345)
        #expect(compactionConfig.canExpand)
    }

    @MainActor
    @Test func thinkingRowsAutoRenderExpandedWithNativeConfiguration() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.toolOutputStore.append("full reasoning block", to: "thinking-1")

        let rows: [ChatItem] = [
            .thinking(id: "thinking-1", preview: "preview text", hasMore: false, isDone: true),
        ]

        let config = makeConfiguration(
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

        let cell = try configuredCell(in: harness.collectionView, item: 0)
        let thinkingConfig = try #require(cell.contentConfiguration as? ThinkingTimelineRowConfiguration)
        #expect(thinkingConfig.isExpanded)
        #expect(thinkingConfig.displayText == "full reasoning block")
    }

    @MainActor
    @Test func audioClipRowsRenderWithNativeConfiguration() throws {
        let harness = makeHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(
                id: "audio-1",
                title: "Harness Clip",
                fileURL: URL(fileURLWithPath: "/tmp/harness-audio.wav"),
                timestamp: Date()
            ),
        ]

        let config = makeConfiguration(
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

        let cell = try configuredCell(in: harness.collectionView, item: 0)
        #expect(cell.contentConfiguration is AudioClipTimelineRowConfiguration)
    }

    @MainActor
    @Test func loadMoreAndWorkingRowsRenderWithNativeConfiguration() throws {
        var showEarlierTapped = 0

        do {
            let harness = makeHarness(sessionId: "session-a")
            let withHiddenRows = makeConfiguration(
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

            let loadMoreCell = try configuredCell(in: harness.collectionView, item: 0)
            #expect(loadMoreCell.contentConfiguration is LoadMoreTimelineRowConfiguration)

            // sanity check closure is wired in config payload
            if let config = loadMoreCell.contentConfiguration as? LoadMoreTimelineRowConfiguration {
                config.onTap()
            }
            #expect(showEarlierTapped == 1)
        }

        do {
            let harness = makeHarness(sessionId: "session-a")
            let busy = makeConfiguration(
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

            let workingCell = try configuredCell(in: harness.collectionView, item: 0)
            #expect(workingCell.contentConfiguration is WorkingIndicatorTimelineRowConfiguration)
        }
    }

    @MainActor
    @Test func tappingToolRowTogglesExpansionEvenWithoutMaterializedCell() {
        let harness = makeHarness(sessionId: "session-a")
        let toolID = "tool-read-1"

        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: toolID)
        let config = makeConfiguration(
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

        // Intentionally do not materialize the cell via `configuredCell(...)`.
        // Selection handling should still toggle expansion state based on item ID.
        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
    }

    @MainActor
    @Test func tappingCompactionRowTogglesExpansionWhenSummaryIsLong() {
        let harness = makeHarness(sessionId: "session-a")
        let itemID = "compaction-expand-1"
        let summary = String(repeating: "keep-calm ", count: 24)

        let config = makeConfiguration(
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
        #expect(harness.reducer.expandedItemIDs.contains(itemID))

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
            themeID: .tokyoNight
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
            themeID: .tokyoNight
        )

        let view = CompactionTimelineRowContentView(configuration: config)
        let fitting = fittedSize(for: view, width: 338)

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
            themeID: .tokyoNight
        )

        let view = CompactionTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 338)

        let detailLabel = try #require(allLabels(in: view).first {
            renderedText(of: $0).contains("Goal") || renderedText(of: $0).contains("Continue migration")
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
            themeID: .tokyoNight
        )

        let view = CompactionTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 338)

        let markdownView = try #require(firstView(ofType: AssistantMarkdownContentView.self, in: view))
        #expect(!markdownView.isHidden)

        let rendered = allTextViews(in: markdownView)
            .map { $0.attributedText?.string ?? $0.text ?? "" }
            .joined(separator: "\n")
        #expect(rendered.contains("Goal"))
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
            themeID: .tokyoNight
        )

        let view = AssistantTimelineRowContentView(configuration: config)
        let fitting = fittedSize(for: view, width: 338)

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
            themeID: .tokyoNight
        )

        let view = AudioClipTimelineRowContentView(configuration: config)
        let fitting = fittedSize(for: view, width: 338)

        #expect(fitting.width.isFinite)
        #expect(fitting.height.isFinite)
        #expect(fitting.height < 10_000)
    }

    @MainActor
    @Test func thinkingRowContentViewExpandedReportsFiniteFittingSize() {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            isExpanded: true,
            previewText: "preview",
            fullText: String(repeating: "reasoning line\n", count: 500),
            themeID: .tokyoNight
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        let fitting = fittedSize(for: view, width: 338)

        #expect(fitting.width.isFinite)
        #expect(fitting.height.isFinite)
        #expect(fitting.height < 10_000)
    }

    @MainActor
    @Test func thinkingRowExpandedUsesCappedViewportHeight() {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            isExpanded: true,
            previewText: "preview",
            fullText: String(repeating: "reasoning line\n", count: 900),
            themeID: .tokyoNight
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        let fitting = fittedSize(for: view, width: 338)

        #expect(fitting.height < 280)
        #expect(fitting.height > 140)
    }

    @MainActor
    @Test func thinkingRowExpandedShrinksForShortText() {
        let short = ThinkingTimelineRowConfiguration(
            isDone: true,
            isExpanded: true,
            previewText: "preview",
            fullText: "short thought",
            themeID: .tokyoNight
        )
        let long = ThinkingTimelineRowConfiguration(
            isDone: true,
            isExpanded: true,
            previewText: "preview",
            fullText: String(repeating: "reasoning line\n", count: 900),
            themeID: .tokyoNight
        )

        let shortView = ThinkingTimelineRowContentView(configuration: short)
        let longView = ThinkingTimelineRowContentView(configuration: long)

        let shortSize = fittedSize(for: shortView, width: 338)
        let longSize = fittedSize(for: longView, width: 338)

        #expect(shortSize.height < longSize.height)
    }

    @MainActor
    @Test func thinkingRowMarkdownPreviewStripsFormattingMarkers() throws {
        let config = ThinkingTimelineRowConfiguration(
            isDone: true,
            isExpanded: true,
            previewText: "**Reviewing checklist for updates**",
            fullText: nil,
            themeID: .tokyoNight
        )

        let view = ThinkingTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 338)

        let textView = try #require(allTextViews(in: view).first)
        let rendered = textView.attributedText?.string ?? ""

        #expect(rendered.contains("Reviewing checklist for updates"))
        #expect(!rendered.contains("**"))
    }

    @MainActor
    @Test func nativeBashToolConfigurationOmitsCollapsedOutputPreview() throws {
        let harness = makeHarness(sessionId: "session-a")
        let item = ChatItem.toolCall(
            id: "tool-1",
            tool: "bash",
            argsSummary: "command: echo hi",
            outputPreview: "hi",
            outputByteCount: 32,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: "tool-1", item: item))

        #expect(config.preview == nil)
        #expect(config.trailing == nil)
        #expect(config.toolNamePrefix == "$")
        #expect(!config.title.hasPrefix("$"))
    }

    @MainActor
    @Test func nativeReadToolConfigurationUsesSingleLineHeaderAndHidesCollapsedByteCount() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "read-1")

        let item = ChatItem.toolCall(
            id: "read-1",
            tool: "read",
            argsSummary: "path: src/main.swift",
            outputPreview: "line1\nline2",
            outputByteCount: 0,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: "read-1", item: item))
        #expect(config.preview == nil)
        #expect(config.trailing == nil)
    }

    @MainActor
    @Test func expandedReadImageToolConfigurationUsesMediaRenderer() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("read-image-1")
        harness.toolArgsStore.set(["path": .string("screens/harness-initial.png")], for: "read-image-1")
        harness.toolOutputStore.append(
            "Read image file [image/png]\ndata:image/png;base64,iVBORw0KGgoAAAANSUhEUg==",
            to: "read-image-1"
        )

        let item = ChatItem.toolCall(
            id: "read-image-1",
            tool: "read",
            argsSummary: "path: screens/harness-initial.png",
            outputPreview: "",
            outputByteCount: 128,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: "read-image-1", item: item))
        #expect(config.expandedUsesReadMediaRenderer)
        #expect(config.expandedCodeStartLine == nil)
    }

    @MainActor
    @Test func collapsedToolRowsHideByteCountTrailingByDefault() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "read-1")

        let bash = ChatItem.toolCall(
            id: "bash-1",
            tool: "bash",
            argsSummary: "command: ls",
            outputPreview: "line",
            outputByteCount: 1024,
            isError: false,
            isDone: true
        )
        let read = ChatItem.toolCall(
            id: "read-1",
            tool: "read",
            argsSummary: "path: src/main.swift",
            outputPreview: "line",
            outputByteCount: 2048,
            isError: false,
            isDone: true
        )
        let write = ChatItem.toolCall(
            id: "write-1",
            tool: "write",
            argsSummary: "path: src/main.swift",
            outputPreview: "ok",
            outputByteCount: 4096,
            isError: false,
            isDone: true
        )

        let bashConfig = try #require(harness.coordinator.nativeToolConfiguration(itemID: "bash-1", item: bash))
        let readConfig = try #require(harness.coordinator.nativeToolConfiguration(itemID: "read-1", item: read))
        let writeConfig = try #require(harness.coordinator.nativeToolConfiguration(itemID: "write-1", item: write))

        #expect(bashConfig.trailing == nil)
        #expect(readConfig.trailing == nil)
        #expect(writeConfig.trailing == nil)
    }

    @MainActor
    @Test func collapsedTodoToolConfigurationOmitsPreviewForSingleLineConsistency() throws {
        let harness = makeHarness(sessionId: "session-a")
        let toolID = "todo-preview-1"

        harness.toolArgsStore.set([
            "action": .string("append"),
            "title": .string("Refine timeline behavior"),
            "body": .string("First line\nSecond line"),
        ], for: toolID)

        let item = ChatItem.toolCall(
            id: toolID,
            tool: "todo",
            argsSummary: "action: append",
            outputPreview: "",
            outputByteCount: 0,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: toolID, item: item))
        #expect(config.preview == nil)
    }

    @MainActor
    @Test func readOutputFileTypeDetectsFromRawSummaryWithLineRange() {
        let fileType = ToolPresentationBuilder.readOutputFileType(
            args: nil,
            argsSummary: "Chat/ChatTimelineCollectionView.swift:440-499"
        )

        #expect(fileType == .code(language: .swift))
    }

    @MainActor
    @Test func nativeReadToolConfigurationInfersLanguageBadgeFromRawSummaryWhenArgsMissing() throws {
        let harness = makeHarness(sessionId: "session-a")

        let item = ChatItem.toolCall(
            id: "read-summary-only",
            tool: "read",
            argsSummary: "Chat/ChatTimelineCollectionView.swift:440-499",
            outputPreview: "data:image/png literal inside source",
            outputByteCount: 2048,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: item.id, item: item))
        #expect(config.languageBadge == "Swift")
    }

    @MainActor
    @Test func expandedBashToolConfigurationPrefersUnwrappedOutput() throws {
        let harness = makeHarness(sessionId: "session-a")
        harness.reducer.expandedItemIDs.insert("bash-1")

        let item = ChatItem.toolCall(
            id: "bash-1",
            tool: "bash",
            argsSummary: "command: tail -16 build.log",
            outputPreview: "line",
            outputByteCount: 10,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.nativeToolConfiguration(itemID: "bash-1", item: item))
        #expect(config.showSeparatedCommandAndOutput)
        #expect(config.prefersUnwrappedOutput)
    }

    @MainActor
    @Test func sessionSwitchCancelsInFlightToolOutputLoad() async {
        let harness = makeHarness(sessionId: "session-a")
        let probe = FetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(5))
                return "late output"
            } catch is CancellationError {
                await probe.markCanceled()
                throw CancellationError()
            }
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "bash",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting == 1
            }
        })

        let sessionB = makeConfiguration(
            sessionId: "session-b",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: sessionB, to: harness.collectionView)

        #expect(await waitForCondition(timeoutMs: 800) {
            let counts = await probe.snapshot()
            let taskCount = await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting
            }
            return counts.canceled == 1 && taskCount == 0
        })

        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
        #expect(harness.toolOutputStore.fullOutput(for: "tool-1").isEmpty)
        #expect(harness.coordinator._toolOutputCanceledCountForTesting >= 1)
    }

    @MainActor
    @Test func removedItemCancelsInFlightToolOutputLoad() async {
        let harness = makeHarness(sessionId: "session-a")
        let probe = FetchProbe()

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(5))
                return "late output"
            } catch is CancellationError {
                await probe.markCanceled()
                throw CancellationError()
            }
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "bash",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting == 1
            }
        })

        let removed = makeConfiguration(
            items: [],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: removed, to: harness.collectionView)

        #expect(await waitForCondition(timeoutMs: 800) {
            let counts = await probe.snapshot()
            let taskCount = await MainActor.run {
                harness.coordinator._toolOutputLoadTaskCountForTesting
            }
            return counts.canceled == 1 && taskCount == 0
        })

        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
        #expect(harness.toolOutputStore.fullOutput(for: "tool-1").isEmpty)
        #expect(harness.coordinator._toolOutputCanceledCountForTesting >= 1)
    }

    @MainActor
    @Test func successfulToolOutputFetchAppendsAndClearsTaskState() async {
        let harness = makeHarness(sessionId: "session-a")

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return "full output body"
        }

        harness.coordinator._triggerLoadFullToolOutputForTesting(
            itemID: "tool-1",
            tool: "bash",
            outputByteCount: 128,
            in: harness.collectionView
        )

        #expect(await waitForCondition(timeoutMs: 800) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: "tool-1") == "full output body"
            }
        })

        #expect(harness.coordinator._toolOutputAppliedCountForTesting == 1)
        #expect(harness.coordinator._toolOutputStaleDiscardCountForTesting == 0)
        #expect(harness.coordinator._toolOutputLoadTaskCountForTesting == 0)
        #expect(harness.coordinator._loadingToolOutputIDsForTesting.isEmpty)
    }

    @MainActor
    @Test func readToolWithUnknownByteCountStillFetchesFullOutputOnExpand() async {
        let harness = makeHarness(sessionId: "session-a")
        let toolID = "tool-read-unknown-bytes"

        let readConfig = makeConfiguration(
            items: [
                .toolCall(
                    id: toolID,
                    tool: "read",
                    argsSummary: "path: src/main.swift",
                    outputPreview: "",
                    outputByteCount: 0,
                    isError: false,
                    isDone: true
                ),
            ],
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: readConfig, to: harness.collectionView)

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            "full read output"
        }

        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
        #expect(await waitForCondition(timeoutMs: 600) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: toolID) == "full read output"
            }
        })
    }

    @MainActor
    @Test func readToolRetriesFetchWhenStreamingInitiallyReturnsEmptyOutput() async {
        actor Attempts {
            var value = 0
            func next() -> Int {
                value += 1
                return value
            }

            func current() -> Int { value }
        }

        let harness = makeHarness(sessionId: "session-a")
        let toolID = "tool-read-stream-retry"
        let attempts = Attempts()

        let readConfig = makeConfiguration(
            items: [
                .toolCall(
                    id: toolID,
                    tool: "read",
                    argsSummary: "path: src/main.swift",
                    outputPreview: "",
                    outputByteCount: 0,
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
        harness.coordinator.apply(configuration: readConfig, to: harness.collectionView)

        harness.coordinator._fetchToolOutputForTesting = { _, _ in
            let attempt = await attempts.next()
            return attempt == 1 ? "" : "full read output (retry)"
        }

        harness.coordinator.collectionView(
            harness.collectionView,
            didSelectItemAt: IndexPath(item: 0, section: 0)
        )

        #expect(harness.reducer.expandedItemIDs.contains(toolID))
        #expect(await waitForCondition(timeoutMs: 3_500) {
            await MainActor.run {
                harness.toolOutputStore.fullOutput(for: toolID) == "full read output (retry)"
            }
        })
        #expect(await attempts.current() >= 2)
    }

    @MainActor
    @Test func nearBottomHysteresisKeepsFollowStableForSmallTailGrowth() {
        // Thresholds: enter=120, exit=200.
        // When already near-bottom, distances ≤ 200 keep follow stable.
        let harness = makeHarness(sessionId: "session-a")
        let metricsView = ScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(true)

        // Distance 150 — within exit threshold (200), stays near-bottom.
        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 150, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(harness.scrollController.isCurrentlyNearBottom)

        // Distance 250 — exceeds exit threshold (200), detaches.
        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 250, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func upwardUserScrollDetachesFollowBeforeExitThreshold() {
        let harness = makeHarness(sessionId: "session-a")
        let metricsView = ScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(true)

        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 0, in: metricsView))
        metricsView.testIsTracking = true
        harness.coordinator.scrollViewWillBeginDragging(metricsView)

        // Move up 150pt from bottom — past the enter threshold (120pt) so
        // the detach sticks even after updateScrollState re-evaluates.
        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 150, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)

        #expect(!harness.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func nearBottomHysteresisRequiresCloserReentryAfterDetach() {
        // Thresholds: enter=120, exit=200.
        // When detached, must get within enter threshold (120) to re-attach.
        let harness = makeHarness(sessionId: "session-a")
        let metricsView = ScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        harness.scrollController.updateNearBottom(false)

        // Distance 150 — beyond enter threshold (120), stays detached.
        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 150, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(!harness.scrollController.isCurrentlyNearBottom)

        // Distance 80 — within enter threshold (120), re-attaches.
        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 80, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(harness.scrollController.isCurrentlyNearBottom)
    }

    @MainActor
    @Test func detachedStreamingHintTracksOffscreenStreamingState() {
        let harness = makeHarness(sessionId: "session-a")
        let streamingConfig = makeConfiguration(
            items: [
                .assistantMessage(id: "assistant-stream", text: "token", timestamp: Date()),
            ],
            streamingAssistantID: "assistant-stream",
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: streamingConfig, to: harness.collectionView)

        let metricsView = ScrollMetricsCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        metricsView.testContentSize = CGSize(width: 390, height: 1_100)
        metricsView.testVisibleIndexPaths = [IndexPath(item: 0, section: 0)]

        // Distance 250 — beyond enter threshold (120), detached from bottom.
        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 250, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(harness.scrollController.isDetachedStreamingHintVisible)

        let nonStreamingConfig = makeConfiguration(
            items: [
                .assistantMessage(id: "assistant-stream", text: "done", timestamp: Date()),
            ],
            streamingAssistantID: nil,
            sessionId: "session-a",
            reducer: harness.reducer,
            toolOutputStore: harness.toolOutputStore,
            toolArgsStore: harness.toolArgsStore,
            connection: harness.connection,
            scrollController: harness.scrollController,
            audioPlayer: harness.audioPlayer
        )
        harness.coordinator.apply(configuration: nonStreamingConfig, to: harness.collectionView)
        #expect(!harness.scrollController.isDetachedStreamingHintVisible)

        harness.coordinator.apply(configuration: streamingConfig, to: harness.collectionView)
        metricsView.contentOffset = CGPoint(x: 0, y: offsetY(forDistanceFromBottom: 0, in: metricsView))
        harness.coordinator.scrollViewDidScroll(metricsView)
        #expect(!harness.scrollController.isDetachedStreamingHintVisible)
    }

    @MainActor
    @Test func audioStateChangeReconfiguresAffectedAudioRows() async {
        let harness = makeHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(id: "audio-1", title: "Clip 1", fileURL: URL(fileURLWithPath: "/tmp/audio-1.wav"), timestamp: Date()),
            .systemEvent(id: "system-1", message: "separator"),
            .audioClip(id: "audio-2", title: "Clip 2", fileURL: URL(fileURLWithPath: "/tmp/audio-2.wav"), timestamp: Date()),
        ]
        let config = makeConfiguration(
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

        #expect(await waitForCondition(timeoutMs: 300) {
            await MainActor.run {
                harness.coordinator._audioStateRefreshCountForTesting == 1
            }
        })

        #expect(harness.coordinator._audioStateRefreshedItemIDsForTesting == ["audio-1", "audio-2"])
    }

    @MainActor
    @Test func audioStateChangeWithoutIDsRefreshesAllVisibleAudioRows() async {
        let harness = makeHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(id: "audio-1", title: "Clip 1", fileURL: URL(fileURLWithPath: "/tmp/audio-1.wav"), timestamp: Date()),
            .audioClip(id: "audio-2", title: "Clip 2", fileURL: URL(fileURLWithPath: "/tmp/audio-2.wav"), timestamp: Date()),
        ]
        let config = makeConfiguration(
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

        #expect(await waitForCondition(timeoutMs: 300) {
            await MainActor.run {
                harness.coordinator._audioStateRefreshCountForTesting == 1
            }
        })

        #expect(harness.coordinator._audioStateRefreshedItemIDsForTesting == ["audio-1", "audio-2"])
    }

    @MainActor
    @Test func audioStateChangeFromDifferentPlayerIsIgnored() async {
        let harness = makeHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .audioClip(id: "audio-1", title: "Clip 1", fileURL: URL(fileURLWithPath: "/tmp/audio-1.wav"), timestamp: Date()),
        ]
        let config = makeConfiguration(
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

@Suite("ToolTimelineRowContentView")
struct ToolTimelineRowContentViewTests {

    @MainActor
    @Test func emptyCollapsedBodyProducesFiniteCompactHeight() {
        let config = makeToolConfiguration(isExpanded: false)
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func collapsedTitleStaysSingleLineForConsistency() throws {
        let config = makeToolConfiguration(
            title: "todo Refine compaction row preview behavior for consistency across timeline",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedSize(for: view, width: 320)

        let labels = allLabels(in: view)
        let titleLabel = try #require(labels.first {
            renderedText(of: $0).contains("todo Refine compaction row preview behavior")
        })

        #expect(titleLabel.numberOfLines == 1)
    }

    @MainActor
    @Test func trailingByteCountAlignsWithCollapsedTitleRow() throws {
        let config = makeToolConfiguration(
            title: "$ pwd",
            trailing: "29B",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedSize(for: view, width: 370)

        let labels = allLabels(in: view)
        let titleLabel = try #require(labels.first { renderedText(of: $0) == "$ pwd" })
        let trailingLabel = try #require(labels.first { renderedText(of: $0) == "29B" })

        let titleRect = titleLabel.convert(titleLabel.bounds, to: view)
        let trailingRect = trailingLabel.convert(trailingLabel.bounds, to: view)

        #expect(abs(trailingRect.minY - titleRect.minY) <= 2)
        #expect(abs(trailingRect.midY - titleRect.midY) <= 3)
    }

    @MainActor
    @Test func dollarPrefixRendersToolIconCenteredWithTitleRow() throws {
        let config = makeToolConfiguration(
            title: "cd /Users/chenda/workspace/oppi",
            trailing: nil,
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedSize(for: view, width: 370)

        let labels = allLabels(in: view)
        let titleLabel = try #require(labels.first {
            renderedText(of: $0).contains("cd /Users/chenda/workspace/oppi")
        })
        let titleRect = titleLabel.convert(titleLabel.bounds, to: view)

        let imageViews = allImageViews(in: view).filter { !$0.isHidden && $0.image != nil }
        let toolIconRect = imageViews
            .map { $0.convert($0.bounds, to: view) }
            .first { rect in
                rect.maxX <= titleRect.minX && rect.width <= 13
            }

        let iconRect = try #require(toolIconRect)
        #expect(abs(iconRect.midY - titleRect.midY) <= 3)
    }

    @MainActor
    @Test func languageBadgeRendersIconInHeaderTrailingArea() throws {
        let config = makeToolConfiguration(
            title: "read Runtime/TimelineReducer.swift:220-329",
            languageBadge: "Swift",
            toolNamePrefix: "read",
            isExpanded: false
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedSize(for: view, width: 370)

        // Language badge is now an SF Symbol icon (UIImageView), not a text label.
        let imageViews = allImageViews(in: view)
        let visibleBadge = imageViews.first { !$0.isHidden && $0.image != nil }
        #expect(visibleBadge != nil)
    }

    @MainActor
    @Test func expandedReadMarkdownAddsPinchGestureForFullScreenReader() {
        let config = makeToolConfiguration(
            expandedText: "# Notes\n\n- item",
            expandedTextUsesMarkdown: true,
            expandedCodeFilePath: "docs/README.md",
            toolNamePrefix: "read",
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        _ = fittedSize(for: view, width: 370)

        let recognizers = allGestureRecognizers(in: view)
        let hasPinch = recognizers.contains { $0 is UIPinchGestureRecognizer }
        #expect(hasPinch)
    }

    @MainActor
    @Test func emptyExpandedBodyProducesFiniteCompactHeight() {
        let config = makeToolConfiguration(
            expandedText: nil,
            expandedCommandText: nil,
            expandedOutputText: nil,
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let size = fittedSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func transitionFromExpandedContentToEmptyBodyStaysFinite() {
        let expanded = makeToolConfiguration(
            expandedCommandText: "echo hi",
            expandedOutputText: "hi",
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )
        let emptyExpanded = makeToolConfiguration(
            expandedCommandText: nil,
            expandedOutputText: nil,
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: expanded)
        _ = fittedSize(for: view, width: 370)

        view.configuration = emptyExpanded
        let size = fittedSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height < 220)
    }

    @MainActor
    @Test func expandedOutputUsesCappedViewportHeight() {
        let longOutput = Array(repeating: "line", count: 600).joined(separator: "\n")
        let config = makeToolConfiguration(
            expandedCommandText: "echo hi",
            expandedOutputText: longOutput,
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        let size = fittedSize(for: view, width: 370)

        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
        #expect(size.height > 300)
        #expect(size.height < 760)
    }

    @MainActor
    @Test func expandedOutputCanUseUnwrappedTerminalLayout() throws {
        let config = makeToolConfiguration(
            expandedCommandText: "tail -16 build.log",
            expandedOutputText: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
            prefersUnwrappedOutput: true,
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 280)

        let outputLabel = try #require(allLabels(in: view).first {
            renderedText(of: $0).contains("0123456789abcdefghijklmnopqrstuvwxyz")
        })
        #expect(outputLabel.lineBreakMode == .byClipping)

        let horizontalScroll = allScrollViews(in: view).first { $0.showsHorizontalScrollIndicator }
        #expect(horizontalScroll != nil)
    }

    @MainActor
    @Test func expandedMarkdownReadUsesNativeMarkdownViewWithCodeBlockSubview() {
        let markdown = """
        # Header

        Wrapped prose paragraph that should render as markdown text.

        ```swift
        let reallyLongLine = \"this code line should not soft wrap inside markdown code block rendering\"
        ```
        """

        let config = makeToolConfiguration(
            expandedText: markdown,
            expandedTextUsesMarkdown: true,
            expandedOutputLanguage: nil,
            expandedCodeStartLine: nil,
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 300)

        let markdownView = firstView(ofType: AssistantMarkdownContentView.self, in: view)
        #expect(markdownView != nil)

        let codeBlockView = firstView(ofType: NativeCodeBlockView.self, in: view)
        #expect(codeBlockView != nil)
    }

    @MainActor
    @Test func expandedMarkdownReadPreservesTailContentPastGenericTruncationLimit() {
        let longParagraph = String(repeating: "markdown-content-", count: 160)
        let markdown = """
        # Header

        \(longParagraph)

        ## Tail Marker
        Tail content should remain visible in markdown mode.
        """

        let config = makeToolConfiguration(
            expandedText: markdown,
            expandedTextUsesMarkdown: true,
            expandedOutputLanguage: nil,
            expandedCodeStartLine: nil,
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 300)

        let rendered = allTextViews(in: view)
            .map { $0.attributedText?.string ?? $0.text ?? "" }
            .joined(separator: "\n")

        #expect(rendered.contains("Tail Marker"))
        #expect(!rendered.contains("output truncated for display"))
    }

    @MainActor
    @Test func expandedOutputDisplayTruncatesLargePayloads() throws {
        let longOutput = String(repeating: "x", count: 12_000)
        let config = makeToolConfiguration(
            expandedOutputText: longOutput,
            showSeparatedCommandAndOutput: true,
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 370)

        let renderedTexts = allLabels(in: view).map { renderedText(of: $0) }
        let longest = try #require(renderedTexts.max(by: { $0.count < $1.count }))

        #expect(longest.count < longOutput.count)
        #expect(longest.contains("output truncated for display"))
        #expect(longest.hasPrefix(String(repeating: "x", count: 128)))
    }

    @MainActor
    @Test func expandedDiffIncreasesBodyHeight() {
        let collapsed = makeToolConfiguration(isExpanded: false)
        let expanded = makeToolConfiguration(
            expandedDiffLines: [
                DiffLine(kind: .removed, text: "let value = 1"),
                DiffLine(kind: .added, text: "let value = 2"),
                DiffLine(kind: .context, text: "let unchanged = true"),
            ],
            expandedDiffPath: "src/main.swift",
            isExpanded: true
        )

        let collapsedView = ToolTimelineRowContentView(configuration: collapsed)
        let expandedView = ToolTimelineRowContentView(configuration: expanded)

        let collapsedSize = fittedSize(for: collapsedView, width: 370)
        let expandedSize = fittedSize(for: expandedView, width: 370)

        #expect(expandedSize.height > collapsedSize.height)
    }

    @MainActor
    @Test func expandedDiffShowsGutterBarsAndPrefixes() {
        let config = makeToolConfiguration(
            expandedDiffLines: [
                DiffLine(kind: .removed, text: "let value = 1"),
                DiffLine(kind: .added, text: "let value = 2"),
            ],
            expandedDiffPath: "src/main.swift",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 370)

        // Diff text is rendered into a UILabel (expandedLabel) inside the scroll view.
        let rendered = allLabels(in: view)
            .compactMap { $0.attributedText?.string ?? $0.text }
            .joined(separator: "\n")

        // Gutter bar with prefix (▎+ / ▎−) should be present.
        #expect(rendered.contains("▎+"))
        #expect(rendered.contains("▎−"))
        #expect(rendered.contains("let value"))
    }

    @MainActor
    @Test func expandedEmptyDiffShowsNoTextualChangesMessage() {
        let config = makeToolConfiguration(
            expandedDiffLines: [],
            expandedDiffPath: "src/main.swift",
            isExpanded: true
        )

        let view = ToolTimelineRowContentView(configuration: config)
        _ = fittedSize(for: view, width: 370)

        let rendered = allLabels(in: view)
            .map { renderedText(of: $0) }
            .joined(separator: "\n")

        #expect(rendered.contains("No textual changes"))
    }

    @MainActor
    @Test func errorOutputPresentationStripsANSIEscapeCodes() {
        let input = "\u{001B}[31mFAIL\u{001B}[39m tests/workspace-crud.test.ts"

        let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
            input,
            isError: true
        )

        let rendered = presentation.attributedText?.string ?? presentation.plainText ?? ""
        #expect(rendered == "FAIL tests/workspace-crud.test.ts")
        #expect(!rendered.contains("[31m"))
        #expect(!rendered.contains("[39m"))
    }

    @MainActor
    @Test func errorOutputFallbackStillStripsANSIWhenHighlightingSkipped() {
        let input = "\u{001B}[31mFAIL\u{001B}[39m " + String(repeating: "x", count: 80)

        let presentation = ToolRowTextRenderer.makeANSIOutputPresentation(
            input,
            isError: true,
            maxHighlightBytes: 8
        )

        #expect(presentation.attributedText == nil)
        let rendered = presentation.plainText ?? ""
        #expect(rendered.hasPrefix("FAIL "))
        #expect(!rendered.contains("[31m"))
        #expect(!rendered.contains("[39m"))
    }

    @MainActor
    @Test func syntaxOutputPresentationHighlightsKnownLanguage() {
        let source = "guard value else { return }"

        let presentation = ToolRowTextRenderer.makeSyntaxOutputPresentation(
            source,
            language: .swift
        )

        #expect(presentation.plainText == nil)
        #expect(presentation.attributedText?.string == source)
    }

    @MainActor
    @Test func ansiHighlightedSeparatedOutputRemainsVisible() {
        let config = makeToolConfiguration(
            expandedCommandText: "echo hi",
            expandedOutputText: "\u{001B}[31mFAIL\u{001B}[39m tests/workspace-crud.test.ts",
            showSeparatedCommandAndOutput: true,
            isExpanded: true,
            isError: true
        )
        let view = ToolTimelineRowContentView(configuration: config)

        let renderedTexts = allLabels(in: view)
            .map { label in
                label.attributedText?.string ?? label.text ?? ""
            }

        #expect(renderedTexts.contains { $0.contains("FAIL tests/workspace-crud.test.ts") })
    }
}

@Suite("AssistantTimelineRowContentView")
struct AssistantTimelineRowContentViewTests {
    @MainActor
    @Test func rendersMarkdownLinksAsClickable() throws {
        let text = "See [the docs](https://example.com) for details"
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration(text: text))
        let textView = try #require(firstTextView(in: view))

        // Markdown parser produces attributed text with .link attribute on "the docs".
        let fullText = textView.attributedText.string
        let nsText = fullText as NSString
        let docsRange = nsText.range(of: "the docs")
        #expect(docsRange.location != NSNotFound)

        let linkedValue = textView.attributedText.attribute(.link, at: docsRange.location, effectiveRange: nil)
        let linkedURL = try #require(linkedValue as? URL)
        #expect(linkedURL.absoluteString == "https://example.com")
    }

    @MainActor
    @Test func rendersInlineCodeWithMonospacedFont() throws {
        let text = "Use `parseCommonMark()` to parse"
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration(text: text))
        let textView = try #require(firstTextView(in: view))

        let fullText = textView.attributedText.string
        let nsText = fullText as NSString
        let codeRange = nsText.range(of: "parseCommonMark()")
        #expect(codeRange.location != NSNotFound)
    }

    @MainActor
    @Test func rendersCodeBlockInSeparateView() throws {
        let text = "Here is code:\n\n```swift\nlet x = 1\n```\n\nDone."
        let view = AssistantTimelineRowContentView(configuration: makeAssistantConfiguration(text: text))
        let codeBlockView = firstView(ofType: NativeCodeBlockView.self, in: view)
        #expect(codeBlockView != nil)
    }

    @MainActor
    @Test func trimsTrailingEncodedBacktickBeforeRoutingInviteLink() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "oppi://connect?v=2&invite=test-payload%60"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = markdownView.shouldOpenLinkExternally(url)

        #expect(!shouldOpenExternally)
        let routedURL = try #require(observed.value)
        #expect(routedURL.absoluteString == "oppi://connect?v=2&invite=test-payload")
    }

    @MainActor
    @Test func interceptsInviteLinksAndRoutesInternally() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "oppi://connect?v=2&invite=test-payload"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = markdownView.shouldOpenLinkExternally(url)

        #expect(!shouldOpenExternally)
        #expect(observed.value == url)
    }

    @MainActor
    @Test func allowsHttpLinksToOpenWithSystemDefault() throws {
        let markdownView = makeMarkdownView()
        let url = try #require(URL(string: "https://example.com/docs"))

        final class URLCapture: @unchecked Sendable {
            var value: URL?
        }
        let observed = URLCapture()

        let observer = NotificationCenter.default.addObserver(
            forName: .inviteDeepLinkTapped,
            object: nil,
            queue: nil
        ) { notification in
            observed.value = notification.object as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let shouldOpenExternally = markdownView.shouldOpenLinkExternally(url)

        #expect(shouldOpenExternally)
        #expect(observed.value == nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeMarkdownView() -> AssistantMarkdownContentView {
        let mdView = AssistantMarkdownContentView()
        mdView.apply(configuration: .init(
            content: "Test content",
            isStreaming: false,
            themeID: .tokyoNight
        ))
        return mdView
    }
}

@MainActor
private func allLabels(in root: UIView) -> [UILabel] {
    var labels: [UILabel] = []
    if let label = root as? UILabel {
        labels.append(label)
    }

    for child in root.subviews {
        labels.append(contentsOf: allLabels(in: child))
    }

    return labels
}

@MainActor
private func allTextViews(in root: UIView) -> [UITextView] {
    var textViews: [UITextView] = []
    if let textView = root as? UITextView {
        textViews.append(textView)
    }

    for child in root.subviews {
        textViews.append(contentsOf: allTextViews(in: child))
    }

    return textViews
}

/// Find the first UITextView anywhere in the view hierarchy.
@MainActor
private func firstTextView(in root: UIView) -> UITextView? {
    allTextViews(in: root).first
}

/// Find the first view of a specific type anywhere in the view hierarchy.
@MainActor
private func firstView<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
    if let match = root as? T { return match }
    for child in root.subviews {
        if let found = firstView(ofType: type, in: child) { return found }
    }
    return nil
}

@MainActor
private func allImageViews(in root: UIView) -> [UIImageView] {
    var views: [UIImageView] = []
    if let iv = root as? UIImageView { views.append(iv) }
    for child in root.subviews { views.append(contentsOf: allImageViews(in: child)) }
    return views
}

@MainActor
private func allGestureRecognizers(in root: UIView) -> [UIGestureRecognizer] {
    var recognizers: [UIGestureRecognizer] = root.gestureRecognizers ?? []
    for child in root.subviews {
        recognizers.append(contentsOf: allGestureRecognizers(in: child))
    }
    return recognizers
}

@MainActor
private func allScrollViews(in root: UIView) -> [UIScrollView] {
    var views: [UIScrollView] = []
    if let scrollView = root as? UIScrollView { views.append(scrollView) }
    for child in root.subviews { views.append(contentsOf: allScrollViews(in: child)) }
    return views
}

@MainActor
private func renderedText(of label: UILabel) -> String {
    label.attributedText?.string ?? label.text ?? ""
}

private actor FetchProbe {
    private var startedCount = 0
    private var canceledCount = 0

    func markStarted() {
        startedCount += 1
    }

    func markCanceled() {
        canceledCount += 1
    }

    func snapshot() -> (started: Int, canceled: Int) {
        (startedCount, canceledCount)
    }
}

@MainActor
private final class ScrollMetricsCollectionView: UICollectionView {
    var testContentSize: CGSize = .zero
    var testAdjustedContentInset: UIEdgeInsets = .zero
    var testVisibleIndexPaths: [IndexPath] = []
    var testIsTracking = false
    var testIsDragging = false
    var testIsDecelerating = false

    override var contentSize: CGSize {
        get { testContentSize }
        set { testContentSize = newValue }
    }

    override var adjustedContentInset: UIEdgeInsets {
        testAdjustedContentInset
    }

    override var indexPathsForVisibleItems: [IndexPath] {
        testVisibleIndexPaths
    }

    override var isTracking: Bool {
        testIsTracking
    }

    override var isDragging: Bool {
        testIsDragging
    }

    override var isDecelerating: Bool {
        testIsDecelerating
    }

    init(frame: CGRect) {
        super.init(frame: frame, collectionViewLayout: UICollectionViewFlowLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private func offsetY(forDistanceFromBottom distance: CGFloat, in collectionView: ScrollMetricsCollectionView) -> CGFloat {
    let insets = collectionView.adjustedContentInset
    let visibleHeight = collectionView.bounds.height - insets.top - insets.bottom
    return max(-insets.top, collectionView.contentSize.height - visibleHeight - distance)
}

private struct TimelineHarness {
    let coordinator: ChatTimelineCollectionView.Coordinator
    let collectionView: UICollectionView
    let reducer: TimelineReducer
    let toolOutputStore: ToolOutputStore
    let toolArgsStore: ToolArgsStore
    let connection: ServerConnection
    let scrollController: ChatScrollController
    let audioPlayer: AudioPlayerService
}

@MainActor
private func makeHarness(sessionId: String) -> TimelineHarness {
    let collectionView = UICollectionView(
        frame: CGRect(x: 0, y: 0, width: 390, height: 844),
        collectionViewLayout: UICollectionViewFlowLayout()
    )
    let coordinator = ChatTimelineCollectionView.Coordinator()
    coordinator.configureDataSource(collectionView: collectionView)

    let reducer = TimelineReducer()
    let toolOutputStore = ToolOutputStore()
    let toolArgsStore = ToolArgsStore()
    let connection = ServerConnection()
    let scrollController = ChatScrollController()
    let audioPlayer = AudioPlayerService()

    let initial = makeConfiguration(
        sessionId: sessionId,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        connection: connection,
        scrollController: scrollController,
        audioPlayer: audioPlayer
    )
    coordinator.apply(configuration: initial, to: collectionView)

    return TimelineHarness(
        coordinator: coordinator,
        collectionView: collectionView,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        connection: connection,
        scrollController: scrollController,
        audioPlayer: audioPlayer
    )
}

@MainActor
private func makeConfiguration(
    items: [ChatItem] = [
        .toolCall(
            id: "tool-1",
            tool: "bash",
            argsSummary: "echo hi",
            outputPreview: "hi",
            outputByteCount: 128,
            isError: false,
            isDone: true
        ),
    ],
    hiddenCount: Int = 0,
    renderWindowStep: Int = 50,
    isBusy: Bool = false,
    streamingAssistantID: String? = nil,
    onShowEarlier: @escaping () -> Void = {},
    sessionId: String,
    reducer: TimelineReducer,
    toolOutputStore: ToolOutputStore,
    toolArgsStore: ToolArgsStore,
    connection: ServerConnection,
    scrollController: ChatScrollController,
    audioPlayer: AudioPlayerService
) -> ChatTimelineCollectionView.Configuration {
    ChatTimelineCollectionView.Configuration(
        items: items,
        hiddenCount: hiddenCount,
        renderWindowStep: renderWindowStep,
        isBusy: isBusy,
        streamingAssistantID: streamingAssistantID,
        sessionId: sessionId,
        workspaceId: "ws-test",
        onFork: { _ in },
        onOpenFile: { _ in },
        onShowEarlier: onShowEarlier,
        scrollCommand: nil,
        scrollController: scrollController,
        reducer: reducer,
        toolOutputStore: toolOutputStore,
        toolArgsStore: toolArgsStore,
        connection: connection,
        audioPlayer: audioPlayer,
        theme: .tokyoNight,
        themeID: .tokyoNight
    )
}

@MainActor
private func configuredCell(
    in collectionView: UICollectionView,
    item: Int,
    section: Int = 0
) throws -> UICollectionViewCell {
    let dataSource = try #require(collectionView.dataSource)
    return dataSource.collectionView(collectionView, cellForItemAt: IndexPath(item: item, section: section))
}

private func waitForCondition(
    timeoutMs: Int,
    pollMs: Int = 10,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))

    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }

    return await condition()
}

private func makeToolConfiguration(
    title: String = "$ bash",
    preview: String? = nil,
    expandedText: String? = nil,
    expandedTextUsesMarkdown: Bool = false,
    expandedDiffLines: [DiffLine]? = nil,
    expandedDiffPath: String? = nil,
    expandedCommandText: String? = nil,
    expandedOutputText: String? = nil,
    expandedOutputLanguage: SyntaxLanguage? = nil,
    expandedCodeStartLine: Int? = nil,
    expandedCodeFilePath: String? = nil,
    prefersUnwrappedOutput: Bool = false,
    showSeparatedCommandAndOutput: Bool = false,
    languageBadge: String? = nil,
    trailing: String? = nil,
    toolNamePrefix: String? = "$",
    toolNameColor: UIColor = .systemGreen,
    isExpanded: Bool,
    isDone: Bool = true,
    isError: Bool = false
) -> ToolTimelineRowConfiguration {
    ToolTimelineRowConfiguration(
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
        prefersUnwrappedOutput: prefersUnwrappedOutput,
        showSeparatedCommandAndOutput: showSeparatedCommandAndOutput,
        copyCommandText: nil,
        copyOutputText: nil,
        languageBadge: languageBadge,
        trailing: trailing,
        titleLineBreakMode: .byTruncatingTail,
        toolNamePrefix: toolNamePrefix,
        toolNameColor: toolNameColor,
        editAdded: nil,
        editRemoved: nil,
        isExpanded: isExpanded,
        isDone: isDone,
        isError: isError
    )
}

private func makeAssistantConfiguration(
    text: String = "Assistant response with https://example.com"
) -> AssistantTimelineRowConfiguration {
    AssistantTimelineRowConfiguration(
        text: text,
        isStreaming: false,
        canFork: false,
        onFork: nil,
        themeID: .tokyoNight
    )
}

@MainActor
private func fittedSize(for view: UIView, width: CGFloat) -> CGSize {
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)

    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
    ])

    container.setNeedsLayout()
    container.layoutIfNeeded()

    return view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
    )
}
