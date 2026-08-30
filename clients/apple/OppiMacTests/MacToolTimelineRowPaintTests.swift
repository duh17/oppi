import Foundation
import Testing
@testable import Oppi

@Suite("Mac tool timeline row paint")
struct MacToolTimelineRowPaintTests {
    @Test func collapsedRowsStayHeaderOnlyAndDoNotRepeatStatusText() throws {
        let source = try macSessionTimelineSource()
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )

        #expect(bubble.contains("if isExpanded {\n                expandedBody"))
        let expandedBody = try sourceSlice(
            named: "private var expandedBody: some View {",
            until: "private var toolOutput: some View {",
            in: bubble
        )
        #expect(expandedBody.contains("toolOutput"))
        #expect(!expandedBody.contains("Text(argsSummary)"))
        #expect(!bubble.contains("Text(MacToolTimelineChrome.statusLabel"))
        #expect(bubble.contains("RoundedRectangle(cornerRadius: 10)"))
    }

    @Test func headerUsesCompressibleIdentityThenIOSOrderedTrailingRail() throws {
        let source = try macSessionTimelineSource()
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )
        let header = try sourceSlice(
            named: "private var header: some View {",
            until: "private var headerSummary: some View {",
            in: bubble
        )

        try #require(header.range(of: "headerSummary") != nil)
        try #require(header.range(of: "MacToolAudioPlaybackButton") != nil)
        try #require(header.range(of: "MacToolElapsedLabel") != nil)
        try #require(header.range(of: "trailingMetadata") != nil)
        try #require(header.range(of: "languageMetadata") != nil)
        #expect(try markersAreOrdered(
            [
                "headerSummary",
                "MacToolAudioPlaybackButton",
                "MacToolElapsedLabel",
                "trailingMetadata",
                "languageMetadata",
            ],
            in: header
        ))
        #expect(header.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(bubble.contains(".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)"))
    }

    @Test func structuredRowsExposeDirectDocumentActionWithoutLosingDisclosure() throws {
        let source = try macSessionTimelineSource()
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )

        #expect(bubble.contains("MacToolTimelineChrome.offersDocumentView"))
        #expect(bubble.contains("Open in Document View"))
        #expect(bubble.contains("mac.timeline.openDocument"))
        #expect(bubble.contains("store.applyKeybinding(.commandReturn, toolRowIDs: [itemID])"))
        #expect(bubble.contains("store.setToolRowExpanded"))
    }

    @Test func directDocumentAndDisclosureActionsUseCompactDesktopPointerTargets() throws {
        let source = try macSessionTimelineSource()
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )

        #expect(source.contains("static let compactActionTargetSize: CGFloat = 24"))
        #expect(bubble.components(separatedBy: "MacToolTimelineChrome.compactActionTargetSize").count == 5)
        #expect(bubble.components(separatedBy: ".contentShape(Rectangle())").count >= 3)
        #expect(bubble.contains("mac.timeline.openDocument"))
        #expect(bubble.contains(".accessibilityLabel(isExpanded ? \"Collapse\" : \"Expand\")"))
    }

    @Test func editMetadataUsesSemanticDiffAndCommentThemeRoles() throws {
        let source = try macSessionTimelineSource()
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )

        #expect(bubble.contains(".themeDiffAdded"))
        #expect(bubble.contains(".themeDiffRemoved"))
        #expect(bubble.contains(".themeComment"))
    }

    @Test func stateChromeMatchesIOSSemanticMatrix() {
        let running = MacToolTimelineState.make(isDone: false, isError: false)
        #expect(running == .running)
        #expect(running.surfaceRole == .toolPendingBackground)
        #expect(running.surfaceOpacity == 1)
        #expect(running.borderRole == .blue)
        #expect(running.borderOpacity == 0.25)

        let succeeded = MacToolTimelineState.make(isDone: true, isError: false)
        #expect(succeeded == .succeeded)
        #expect(succeeded.surfaceRole == .toolSuccessBackground)
        #expect(succeeded.surfaceOpacity == 1)
        #expect(succeeded.borderRole == .comment)
        #expect(succeeded.borderOpacity == 0.20)

        let failed = MacToolTimelineState.make(isDone: true, isError: true)
        #expect(failed == .failed)
        #expect(failed.surfaceRole == .toolErrorBackground)
        #expect(failed.surfaceOpacity == 1)
        #expect(failed.borderRole == .red)
        #expect(failed.borderOpacity == 0.25)

        let interrupted = MacToolTimelineState.make(
            isDone: true,
            isError: false,
            isInterrupted: true
        )
        #expect(interrupted == .interrupted)
        #expect(interrupted.surfaceRole == .orange)
        #expect(interrupted.surfaceOpacity == 0.08)
        #expect(interrupted.borderRole == .orange)
        #expect(interrupted.statusRole == .orange)
        #expect(interrupted.borderOpacity == 0.25)
        #expect(MacToolTimelineChrome.statusLabel(
            isDone: true,
            isError: false,
            isInterrupted: true
        ) == "Interrupted")
        #expect(MacToolTimelineChrome.statusSymbolName(
            isDone: true,
            isError: false,
            isInterrupted: true
        ) == "exclamationmark.circle.fill")
    }

    @Test func bubbleReadsInterruptedStateAndIncludesItInAccessibility() throws {
        let source = try macSessionTimelineSource()
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )

        #expect(bubble.contains("store.isToolInterrupted(itemID)"))
        #expect(bubble.contains("isInterrupted: isInterrupted"))
        #expect(bubble.contains("MacToolTimelineChrome.statusLabel"))
        #expect(bubble.contains("MacToolTimelineChrome.statusSymbolName"))
    }

    @Test func completedEmptyReadDoesNotClaimItIsWaiting() {
        let presentation = ToolContentDescriptorBuilder.build(
            tool: "read",
            argsSummary: "path: Empty.swift",
            outputPreview: "",
            isError: false,
            isDone: true,
            context: ToolContentDescriptorBuilder.Context(
                args: ["path": .string("Empty.swift")],
                fullOutput: "",
                isLoadingOutput: false
            )
        )

        #expect(presentation.content == nil)
        #expect(presentation.copyOutputText == nil)
    }

    @Test func timelineParsesWithSharedDescriptorBuilderNotMacClassifiers() throws {
        let source = try macSessionTimelineSource()
        let presentation = try sourceSlice(
            named: "enum MacToolRowPresentation {",
            until: "enum MacBashCommandChrome {",
            in: source
        )
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )

        #expect(presentation.contains("ToolContentDescriptorBuilder.build"))
        #expect(presentation.contains("toolArgsStore.args"))
        #expect(presentation.contains("toolDetailsStore.details"))
        #expect(presentation.contains("MacToolRowOutput.displayed"))
        #expect(presentation.contains("isExpanded: Bool = true"))
        #expect(bubble.contains("MacToolRowPresentation.make"))
        #expect(bubble.contains("store.toolArgsStore"))
        #expect(bubble.contains("store.toolDetailsStore"))
        let makeCall = try sourceSlice(
            named: "MacToolRowPresentation.make(",
            until: "private var displayedOutput: String {",
            in: bubble
        )
        #expect(makeCall.contains("isExpanded: isExpanded"))
        #expect(!bubble.contains("MacDiffOutputModel"))
        #expect(!bubble.contains("MacInlineOutputFormatter"))
        #expect(!bubble.contains("MacCodeOutputModel.shouldRenderStandalone"))
        #expect(!bubble.contains("MacMediaOutputModel.shouldRender"))
        #expect(!bubble.contains("MacMarkdownPaintDispatch.hasStructuredPaint"))
    }

    @Test func timelinePaintsDescriptorDiffsWithSharedLineNumbers() throws {
        let source = try macSessionTimelineSource()
        let bubble = try sourceSlice(
            named: "private struct ToolTimelineBubble: View {",
            until: "private struct MacBashCommandBar: View {",
            in: source
        )

        #expect(bubble.contains("case .diff(let diff)"))
        #expect(bubble.contains("case .terminal(let terminal)"))
        #expect(bubble.contains("case .code(let code)"))
        #expect(bubble.contains("case .markdown(let markdown)"))
        #expect(bubble.contains("case .file(let file)"))
        #expect(bubble.contains("case .media(let media)"))
        #expect(bubble.contains("case .status(let message)"))
        #expect(source.contains("MacToolDocumentDiffLayout.rows(from: diff)"))
        #expect(!source.contains("MacDiffOutputPreview"))
        #expect(!source.contains("MacInlineOutputContent"))
    }

    @Test func chromeLanguageLabelDoesNotReclassifyOutputWithMacDiffModel() throws {
        let source = try macSessionTimelineSource()
        let chrome = try sourceSlice(
            named: "enum MacToolTimelineChrome {",
            until: "enum MacToolRowOutput {",
            in: source
        )

        #expect(!chrome.contains("MacDiffOutputModel"))
        #expect(!chrome.contains("MacCodeOutputModel"))
        #expect(!chrome.contains("MacMarkdownPaintDispatch"))
        #expect(chrome.contains("content: ToolContentDescriptor?"))
    }

    @Test func languageLabelUsesDescriptorDiffWhenPathHasNoTypedLanguage() {
        let diff = ToolContentDescriptor.diff(
            ToolContentDescriptor.Diff(
                lines: [
                    DiffLine(kind: .added, text: "let value = 2", oldLineNumber: nil, newLineNumber: 1),
                ],
                path: nil
            )
        )

        #expect(
            MacToolTimelineChrome.languageLabel(
                tool: "extensions.patch",
                argsSummary: "",
                content: diff
            ) == SyntaxLanguage.diff.displayName
        )
    }
}

@Suite("Mac tool timeline row presentation")
@MainActor
struct MacToolTimelineRowPresentationTests {
    @Test func rowPresentationMatchesDocumentColumnParse() {
        let items: [ChatItem] = [
            .toolCall(
                id: "edit-1",
                tool: "edit",
                argsSummary: "path: App.swift",
                outputPreview: "Edited App.swift",
                outputByteCount: 16,
                isError: false,
                isDone: true
            ),
        ]
        let outputs = ToolOutputStore()
        outputs.replace("Edited App.swift", for: "edit-1", previewOnly: false)
        let args = ToolArgsStore()
        args.set(
            [
                "path": .string("App.swift"),
                "edits": .array([
                    .object([
                        "oldText": .string("let value = 1"),
                        "newText": .string("let value = 2"),
                    ]),
                ]),
            ],
            for: "edit-1"
        )
        let details = ToolDetailsStore()
        details.set(
            .object([
                "patch": .string("""
                --- App.swift
                +++ App.swift
                @@ -1,1 +1,1 @@
                -let value = 1
                +let value = 2
                """),
            ]),
            for: "edit-1"
        )

        let column = MacToolDocumentColumnModel.make(
            toolRowID: "edit-1",
            items: items,
            toolOutputStore: outputs,
            toolArgsStore: args,
            toolDetailsStore: details
        )
        let row = MacToolRowPresentation.make(
            toolRowID: "edit-1",
            tool: "edit",
            argsSummary: "path: App.swift",
            outputPreview: "Edited App.swift",
            isError: false,
            isDone: true,
            toolOutputStore: outputs,
            toolArgsStore: args,
            toolDetailsStore: details
        )

        #expect(row == column?.presentation)
        #expect(MacToolDocumentColumnPaint.surface(for: row.content) == .diff)
        guard case .diff(let diff) = row.content else {
            Issue.record("Expected structured .diff, got \(String(describing: row.content))")
            return
        }
        #expect(diff.path == "App.swift")
        #expect(diff.lines.contains { $0.kind == .removed && $0.text == "let value = 1" })
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "let value = 2" })
        #expect(MacToolDocumentDiffLayout.rows(from: diff).map(\.kind) == diff.lines.map(\.kind))
    }

    @Test func bashRowStaysTerminalInsteadOfMacInlineReclassification() {
        let outputs = ToolOutputStore()
        outputs.replace(
            """
            $ npm test
            SwiftCompile normal arm64 File.swift
            Ld Oppi.app
            """,
            for: "bash-1",
            previewOnly: false
        )

        let row = MacToolRowPresentation.make(
            toolRowID: "bash-1",
            tool: "bash",
            argsSummary: "command: npm test",
            outputPreview: "$ npm test\nPASS",
            isError: false,
            isDone: true,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore()
        )

        #expect(MacToolDocumentColumnPaint.surface(for: row.content) == .terminal)
        guard case .terminal(let terminal) = row.content else {
            Issue.record("Expected .terminal, got \(String(describing: row.content))")
            return
        }
        #expect(terminal.command == "npm test")
        #expect(terminal.output?.contains("SwiftCompile") == true)
    }

    @Test func collapsedPresentationUsesChatPreviewExpandedUsesPreviewOnlyStore() {
        let storeSnapshot = String(repeating: "x", count: 1_200)
        let chatPreview = String(repeating: "p", count: ChatItem.maxPreviewLength)
        let outputs = ToolOutputStore()
        outputs.replace(
            storeSnapshot,
            for: "bash-preview",
            previewOnly: true,
            totalBytes: storeSnapshot.utf8.count
        )

        let collapsed = MacToolRowPresentation.make(
            toolRowID: "bash-preview",
            tool: "bash",
            argsSummary: "command: npm test",
            outputPreview: chatPreview,
            isError: false,
            isDone: true,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore(),
            isExpanded: false
        )
        let expanded = MacToolRowPresentation.make(
            toolRowID: "bash-preview",
            tool: "bash",
            argsSummary: "command: npm test",
            outputPreview: chatPreview,
            isError: false,
            isDone: true,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore(),
            isExpanded: true
        )
        let omitted = MacToolRowPresentation.make(
            toolRowID: "bash-preview",
            tool: "bash",
            argsSummary: "command: npm test",
            outputPreview: chatPreview,
            isError: false,
            isDone: true,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore()
        )

        guard case .terminal(let collapsedTerminal) = collapsed.content else {
            Issue.record("Expected collapsed .terminal, got \(String(describing: collapsed.content))")
            return
        }
        guard case .terminal(let expandedTerminal) = expanded.content else {
            Issue.record("Expected expanded .terminal, got \(String(describing: expanded.content))")
            return
        }
        #expect(collapsedTerminal.output == chatPreview)
        #expect(expandedTerminal.output == storeSnapshot)
        #expect(omitted.content == expanded.content)
    }
}

private func macSessionTimelineSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "OppiMac/Views/MacSessionTimelineViews.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func sourceSlice(named marker: String, until endMarker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw SourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw SourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}

private func markersAreOrdered(_ markers: [String], in source: String) throws -> Bool {
    var searchStart = source.startIndex
    for marker in markers {
        guard let range = source.range(of: marker, range: searchStart..<source.endIndex) else {
            throw SourceSliceError.missingMarker(marker)
        }
        searchStart = range.upperBound
    }
    return true
}
