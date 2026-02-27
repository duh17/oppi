import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Tool presentation configuration")
struct ToolPresentationConfigTests {
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
    @Test func inlineMediaWarningHeuristicDoesNotFlagRememberRecallOrPlot() {
        let sample = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=="

        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "remember",
                outputPreview: sample,
                fullOutput: ""
            )
        )
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "recall",
                outputPreview: sample,
                fullOutput: ""
            )
        )
        #expect(
            !ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "plot",
                outputPreview: sample,
                fullOutput: ""
            )
        )
    }

    @MainActor
    @Test func inlineMediaWarningHeuristicIsCaseInsensitiveForUnknownTools() {
        #expect(
            ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "grep",
                outputPreview: "DATA:IMAGE/PNG;BASE64,iVBORw0KGgoAAAANSUhEUg==",
                fullOutput: ""
            )
        )

        #expect(
            ToolPresentationBuilder.shouldWarnInlineMediaForToolOutput(
                normalizedTool: "grep",
                outputPreview: "",
                fullOutput: "before DaTa:AuDiO/WaV;BaSe64,UklGRg== after"
            )
        )
    }

    @MainActor
    @Test func inlineMediaToolsStayNativeAndSurfaceWarningBadge() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let item = ChatItem.toolCall(
            id: "grep-media-1",
            tool: "grep",
            argsSummary: "pattern: data",
            outputPreview: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==",
            outputByteCount: 128,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        #expect(config.languageBadge == "⚠︎media")
    }

    @MainActor
    @Test func collapsedParityToolsUseNativeToolConfiguration() {
        let harness = makeTimelineHarness(sessionId: "session-a")
        seedCollapsedParityToolArgs(in: harness)

        for row in collapsedParityToolRows {
            #expect(harness.coordinator.toolRowConfiguration(itemID: row.id, item: row) != nil)
        }
    }

    @MainActor
    @Test func toolRowsRenderWithNativeToolConfigurationAcrossStates() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")

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

        harness.applyAndLayout(items: rows)

        try expectTimelineRowsUseConfigurationType(
            in: harness.collectionView,
            items: Array(rows.indices),
            as: ToolTimelineRowConfiguration.self
        )
    }

    @MainActor
    @Test func editToolWithoutDiffArgsUsesModifiedTrailingFallback() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let item = ChatItem.toolCall(
            id: "edit-unknown-diff",
            tool: "edit",
            argsSummary: "path: src/main.swift",
            outputPreview: "",
            outputByteCount: 0,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        #expect(config.editAdded == nil)
        #expect(config.editRemoved == nil)
        #expect(config.trailing == "modified")
    }

    @MainActor
    @Test func expandedEditToolUsesNativeDiffLines() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        guard case .diff(let diffLines, _) = config.expandedContent else { Issue.record("Expected .diff"); return }

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
        // expandedText == nil is now implicit (content is .diff not .text)
    }

    @MainActor
    @Test func expandedEditToolFallbackOutputKeepsSyntaxLanguageFromPath() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        // Error edit falls back to code viewer with language from file path
        guard case .code(_, let language, _, let filePath) = config.expandedContent else { Issue.record("Expected .code for error edit fallback"); return }
        #expect(language == .typescript)
        #expect(filePath == "src/feature.ts")
    }

    @MainActor
    @Test func expandedReadToolDetectsSyntaxLanguageFromFilePath() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        guard case .code(_, let language, _, _) = config.expandedContent else { Issue.record("Expected .code"); return }
        #expect(language == .swift)
        #expect(config.languageBadge == "Swift")
        // expandedText != nil is now implicit in content case
        if case .code(_, _, let startLine, _) = config.expandedContent { #expect(startLine == 270) }
        if case .code(_, _, _, let filePath) = config.expandedContent { #expect(filePath == "Runtime/TimelineReducer.swift") }
    }

    @MainActor
    @Test func expandedReadToolFallsBackToArgsSummaryPathWhenArgsMissing() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        if case .code(_, _, let startLine, _) = config.expandedContent { #expect(startLine == 1) }
        if case .code(_, _, _, let filePath) = config.expandedContent { #expect(filePath == "Sources/Agent.swift") }
    }

    @MainActor
    @Test func collapsedReadImageToolExtractsImagePreviewFromOutput() throws {
        // End-to-end: simulates the real data flow where the server sends
        // text + data URI as tool_output, ToolOutputStore accumulates them,
        // and ToolPresentationBuilder extracts the first image for collapsed preview.
        let harness = makeTimelineHarness(sessionId: "session-a")
        let fakeBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        let serverOutput = "Read image file [image/png]\ndata:image/png;base64,\(fakeBase64)"

        harness.toolArgsStore.set(["path": .string("icon-design/pi-icon.png")], for: "read-img")
        harness.toolOutputStore.append(serverOutput, to: "read-img")

        let item = ChatItem.toolCall(
            id: "read-img",
            tool: "read",
            argsSummary: "path: icon-design/pi-icon.png",
            outputPreview: String(serverOutput.prefix(500)),
            outputByteCount: serverOutput.utf8.count,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        #expect(config.collapsedImageBase64 == fakeBase64, "Builder must extract base64 from data URI in tool output")
        #expect(config.collapsedImageMimeType == "image/png")
    }

    @MainActor
    @Test func collapsedReadImageToolWithEmptyOutputHasNoPreview() throws {
        // When the tool output hasn't arrived yet (streaming), no image preview.
        let harness = makeTimelineHarness(sessionId: "session-a")
        harness.toolArgsStore.set(["path": .string("icon.png")], for: "read-img-empty")

        let item = ChatItem.toolCall(
            id: "read-img-empty",
            tool: "read",
            argsSummary: "path: icon.png",
            outputPreview: "",
            outputByteCount: 0,
            isError: false,
            isDone: false
        )

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        #expect(config.collapsedImageBase64 == nil, "No image preview before output arrives")
    }

    @MainActor
    @Test func expandedWriteToolDetectsSyntaxLanguageFromPath() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        // Write without content arg falls back to code viewer with language from file path
        guard case .code(_, let language, _, let filePath) = config.expandedContent else { Issue.record("Expected .code for write fallback"); return }
        #expect(language == .swift)
        #expect(filePath == "Sources/Generated.swift")
    }

    @MainActor
    @Test func expandedReadMarkdownUsesMarkdownRendererAndSkipsCodeLineNumbers() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        guard case .markdown = config.expandedContent else { Issue.record("Expected .markdown"); return }
        // startLine is implicit in content case
        #expect(config.languageBadge == "Markdown")
    }

    @MainActor
    @Test func expandedParityToolsUseNativeToolConfiguration() {
        let harness = makeTimelineHarness(sessionId: "session-a")

        let rows: [ChatItem] = [
            .toolCall(id: "read-1", tool: "read", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "read-2", tool: "functions.read", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "write-1", tool: "write", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "edit-1", tool: "edit", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
            .toolCall(id: "todo-1", tool: "todo", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true),
        ]

        for row in rows {
            harness.reducer.expandedItemIDs.insert(row.id)
            #expect(harness.coordinator.toolRowConfiguration(itemID: row.id, item: row) != nil)
        }
    }

    @MainActor
    @Test func expandedTodoToolFormatsListOutputForReadableNativeRendering() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: itemID, item: item))
        // Now uses the rich card renderer instead of markdown text
        guard case .todoCard = config.expandedContent else { Issue.record("Expected .todoCard"); return }
        if case .todoCard(let output) = config.expandedContent { #expect(output.contains("TODO-a27df231")) }
        // Trailing now comes from server resultSegments, not hardcoded. Without segments, it's nil.
        #expect(config.trailing == nil)
    }

    @MainActor
    @Test func expandedTodoAppendUsesAddedOnlyDiffPresentation() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: itemID, item: item))
        // editAdded/editRemoved now come from server segments, not hardcoded todo diff stats
        #expect(config.trailing == nil)
        // expandedText == nil is now implicit (content is .diff not .text)
        guard case .diff(let diffLines, _) = config.expandedContent else { Issue.record("Expected .diff"); return }
        #expect(diffLines.count == 2)
        #expect(config.copyOutputText?.contains("+ Investigate smooth scroll follow") == true)
    }

    @MainActor
    @Test func expandedTodoUpdateUsesDiffPresentationForChangedFields() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: itemID, item: item))
        guard case .diff(let diffLines, _) = config.expandedContent else { Issue.record("Expected .diff"); return }

        // editAdded/editRemoved now come from server segments, not hardcoded todo diff stats
        #expect(config.trailing == nil)
        // expandedText == nil is now implicit (content is .diff not .text)
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
    @Test func expandedFileAndDiffToolsRenderViaNativePathWithoutFailsafe() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
        ChatTimelinePerf.reset()

        harness.reducer.expandedItemIDs.insert("read-tool-1")
        harness.reducer.expandedItemIDs.insert("edit-tool-1")

        let rows: [ChatItem] = [
            .toolCall(id: "read-tool-1", tool: "read", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 64, isError: false, isDone: true),
            .toolCall(id: "edit-tool-1", tool: "edit", argsSummary: "path: src/main.swift", outputPreview: "", outputByteCount: 128, isError: false, isDone: true),
        ]

        harness.applyAndLayout(items: rows)

        try expectTimelineRowsUseConfigurationType(
            in: harness.collectionView,
            items: Array(rows.indices),
            as: ToolTimelineRowConfiguration.self
        )

        let snapshot = ChatTimelinePerf.snapshot()
        #expect(snapshot.failsafeConfigureCount == 0)
    }

    @MainActor
    @Test func collapsedParityToolsRenderViaNativeShellWithoutFailsafe() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
        ChatTimelinePerf.reset()
        seedCollapsedParityToolArgs(in: harness)

        harness.applyAndLayout(items: collapsedParityToolRows)

        try expectTimelineRowsUseConfigurationType(
            in: harness.collectionView,
            items: Array(collapsedParityToolRows.indices),
            as: ToolTimelineRowConfiguration.self
        )

        let snapshot = ChatTimelinePerf.snapshot()
        #expect(snapshot.failsafeConfigureCount == 0)
    }

    @MainActor
    @Test func nativeBashToolConfigurationOmitsCollapsedOutputPreview() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
        let item = ChatItem.toolCall(
            id: "tool-1",
            tool: "bash",
            argsSummary: "command: echo hi",
            outputPreview: "hi",
            outputByteCount: 32,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: "tool-1", item: item))

        #expect(config.preview == nil)
        #expect(config.trailing == nil)
        #expect(config.toolNamePrefix == "$")
        #expect(!config.title.hasPrefix("$"))
    }

    @MainActor
    @Test func nativeReadToolConfigurationUsesSingleLineHeaderAndHidesCollapsedByteCount() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: "read-1", item: item))
        #expect(config.preview == nil)
        #expect(config.trailing == nil)
    }

    @MainActor
    @Test func expandedReadImageToolConfigurationUsesMediaRenderer() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: "read-image-1", item: item))
        guard case .readMedia = config.expandedContent else { Issue.record("Expected .readMedia"); return }
        // startLine is implicit in content case
    }

    @MainActor
    @Test func collapsedToolRowsHideByteCountTrailingByDefault() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let bashConfig = try #require(harness.coordinator.toolRowConfiguration(itemID: "bash-1", item: bash))
        let readConfig = try #require(harness.coordinator.toolRowConfiguration(itemID: "read-1", item: read))
        let writeConfig = try #require(harness.coordinator.toolRowConfiguration(itemID: "write-1", item: write))

        #expect(bashConfig.trailing == nil)
        #expect(readConfig.trailing == nil)
        #expect(writeConfig.trailing == nil)
    }

    @MainActor
    @Test func collapsedTodoToolConfigurationOmitsPreviewForSingleLineConsistency() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: toolID, item: item))
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
        let harness = makeTimelineHarness(sessionId: "session-a")

        let item = ChatItem.toolCall(
            id: "read-summary-only",
            tool: "read",
            argsSummary: "Chat/ChatTimelineCollectionView.swift:440-499",
            outputPreview: "data:image/png literal inside source",
            outputByteCount: 2048,
            isError: false,
            isDone: true
        )

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: item.id, item: item))
        #expect(config.languageBadge == "Swift")
    }

    @MainActor
    @Test func expandedBashToolConfigurationPrefersUnwrappedOutput() throws {
        let harness = makeTimelineHarness(sessionId: "session-a")
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

        let config = try #require(harness.coordinator.toolRowConfiguration(itemID: "bash-1", item: item))
        guard case .bash = config.expandedContent else { Issue.record("Expected .bash"); return }
        if case .bash(_, _, let unwrapped) = config.expandedContent { #expect(unwrapped) }
        #expect(config.toolNamePrefix == "$")
        #expect(config.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

}

private let collapsedParityToolRows: [ChatItem] = [
    .toolCall(
        id: "parity-read-1",
        tool: "read",
        argsSummary: "path: src/main.swift",
        outputPreview: "line1\nline2",
        outputByteCount: 64,
        isError: false,
        isDone: true
    ),
    .toolCall(
        id: "parity-read-2",
        tool: "functions.read",
        argsSummary: "path: src/main.swift",
        outputPreview: "line1\nline2",
        outputByteCount: 64,
        isError: false,
        isDone: true
    ),
    .toolCall(
        id: "parity-write-1",
        tool: "write",
        argsSummary: "path: src/main.swift",
        outputPreview: "",
        outputByteCount: 128,
        isError: false,
        isDone: true
    ),
    .toolCall(
        id: "parity-edit-1",
        tool: "edit",
        argsSummary: "path: src/main.swift",
        outputPreview: "",
        outputByteCount: 128,
        isError: false,
        isDone: true
    ),
    .toolCall(
        id: "parity-todo-1",
        tool: "todo",
        argsSummary: "action: list-all",
        outputPreview: "",
        outputByteCount: 0,
        isError: false,
        isDone: true
    ),
]

@MainActor
private func seedCollapsedParityToolArgs(in harness: TimelineTestHarness) {
    harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "parity-read-1")
    harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "parity-read-2")
    harness.toolArgsStore.set(["path": .string("src/main.swift")], for: "parity-write-1")
    harness.toolArgsStore.set([
        "path": .string("src/main.swift"),
        "oldText": .string("let value = 1\n"),
        "newText": .string("let value = 2\n"),
    ], for: "parity-edit-1")
}
