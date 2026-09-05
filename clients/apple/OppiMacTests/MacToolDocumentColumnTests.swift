import AppKit
import Foundation
import Testing
@testable import Oppi

@Suite("Mac tool document column")
struct MacToolDocumentColumnTests {
    private let toolRowIDs = ["tool-a", "tool-b"]

    @Test func timelineReturnOpensTheSelectedDocumentColumn() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .timeline
        )

        #expect(apply(.return, mode: .macDefault, to: &state) == .openViewer)
        #expect(state.openToolDocumentID == "tool-a")
        #expect(state.focus == .timeline)
        #expect(state.expandedToolRowIDs.isEmpty)
    }

    @Test func timelineCommandReturnOpensTheSelectedDocumentColumn() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-b",
            focus: .timeline
        )

        for mode in KeybindingMode.allCases {
            state.openToolDocumentID = nil
            #expect(apply(.commandReturn, mode: mode, to: &state) == .openViewer, "\(mode.rawValue)")
            #expect(state.openToolDocumentID == "tool-b", "\(mode.rawValue)")
            #expect(state.focus == .timeline, "\(mode.rawValue)")
        }
    }

    @Test func vimEnterOpensTheSelectedDocumentColumn() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .timeline
        )

        #expect(apply(.return, mode: .vim, to: &state) == .openViewer)
        #expect(state.openToolDocumentID == "tool-a")
    }

    @Test func escapeClosesTheDocumentColumn() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .timeline,
            openToolDocumentID: "tool-a"
        )

        #expect(apply(.escape, mode: .macDefault, to: &state) == .closeViewer)
        #expect(state.openToolDocumentID == nil)
        #expect(state.focus == .timeline)
        #expect(state.selectedToolRowID == "tool-a")
    }

    @Test func viewerEscapeClosesTheColumnAndRestoresTimelineFocus() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .viewer,
            openToolDocumentID: "tool-a"
        )

        #expect(apply(.escape, mode: .vim, to: &state) == .closeViewer)
        #expect(state.openToolDocumentID == nil)
        #expect(state.focus == .timeline)
    }

    @Test func openViewerWithoutSelectionDoesNotOpenAColumn() {
        var state = MacTimelineKeybinding.State(focus: .timeline)

        #expect(apply(.return, mode: .macDefault, to: &state) == .openViewer)
        #expect(state.openToolDocumentID == nil)
    }

    @Test func composerCommandReturnDoesNotOpenTheColumn() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .composer
        )

        #expect(apply(.commandReturn, mode: .macDefault, to: &state) == .send)
        #expect(state.openToolDocumentID == nil)
        #expect(state.focus == .composer)
    }

    @Test func composerEscapeDoesNotCloseTheColumn() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .composer,
            openToolDocumentID: "tool-a"
        )

        for mode in KeybindingMode.allCases {
            #expect(apply(.escape, mode: mode, to: &state) == nil, "\(mode.rawValue)")
            #expect(state.openToolDocumentID == "tool-a", "\(mode.rawValue)")
            #expect(state.focus == .composer, "\(mode.rawValue)")
        }
    }

    @Test func documentColumnIsWiderThanTheFilesInspector() {
        #expect(MacToolDocumentColumnMetrics.minWidth > 420)
        #expect(MacToolDocumentColumnMetrics.idealWidth >= MacToolDocumentColumnMetrics.minWidth)
        #expect(MacToolDocumentColumnMetrics.minWidth >= 520)
    }

    @Test func documentHeaderKeepsBorderlessActionsVisuallyDistinct() throws {
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        let headerStart = try #require(column.range(of: "private var header: some View"))
        let bodyStart = try #require(column.range(
            of: "private var documentBody: some View",
            range: headerStart.upperBound..<column.endIndex
        ))
        let header = String(column[headerStart.lowerBound..<bodyStart.lowerBound])

        #expect(column.contains("static let headerActionSpacing: CGFloat = 14"))
        #expect(header.contains("HStack(spacing: MacToolDocumentColumnMetrics.headerActionSpacing)"))
        #expect(header.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(header.contains("mac.documentColumn.fullScreen"))
        #expect(header.contains("mac.documentColumn.close"))
        #expect(header.contains("mac.documentColumn.copyPath"))
        #expect(header.contains("documentKindLabel"))
    }

    @Test func diffViewerUsesDedicatedMacGuttersAndChangeMarkers() {
        #expect(MacToolDocumentDiffMetrics.lineNumberWidth == 42)
        #expect(MacToolDocumentDiffMetrics.markerWidth == 22)
        #expect(MacToolDocumentDiffMetrics.rowMinimumHeight >= 20)
    }

    @Test func pathLeadsTheDocumentTitleInsteadOfTheToolName() {
        let model = MacToolDocumentColumnModel(
            toolRowID: "edit-1",
            tool: "edit",
            argsSummary: "path: Sources/App.swift",
            presentation: ToolContentPresentation(
                content: .diff(ToolContentDescriptor.Diff(lines: [], path: "Sources/App.swift")),
                copyCommandText: nil,
                copyOutputText: nil
            )
        )

        #expect(model.title == "App.swift")
    }

    @Test func descriptorDispatchRoutesCodeDiffAndText() {
        let code = ToolContentDescriptor.code(
            ToolContentDescriptor.Code(
                text: "let value = 42",
                language: .swift,
                startLine: 1,
                filePath: "App.swift"
            )
        )
        let diff = ToolContentDescriptor.diff(
            ToolContentDescriptor.Diff(
                lines: [
                    DiffLine(kind: .context, text: "keep", oldLineNumber: 1, newLineNumber: 1),
                    DiffLine(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: 2),
                    DiffLine(kind: .removed, text: "old", oldLineNumber: 2, newLineNumber: nil),
                ],
                path: "App.swift"
            )
        )
        let terminal = ToolContentDescriptor.terminal(
            ToolContentDescriptor.Terminal(
                command: "ls",
                output: "App.swift",
                unwrapped: true,
                language: nil
            )
        )

        #expect(MacToolDocumentColumnPaint.surface(for: code) == .code)
        #expect(MacToolDocumentColumnPaint.surface(for: diff) == .diff)
        #expect(MacToolDocumentColumnPaint.surface(for: terminal) == .terminal)
        #expect(MacToolDocumentColumnPaint.surface(for: nil) == .empty)
    }

    @Test func codePaintUsesMacSyntaxHighlighter() throws {
        let code = ToolContentDescriptor.Code(
            text: "let value = 42\n// comment",
            language: .swift,
            startLine: 1,
            filePath: "App.swift"
        )
        let highlighted = MacSyntaxHighlighter.attributedCode(code.text, language: code.language)
        let keywordRange = (highlighted.string as NSString).range(of: "let")
        let commentRange = (highlighted.string as NSString).range(of: "// comment")
        let keywordColor = try #require(
            highlighted.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor
        )
        let commentColor = try #require(
            highlighted.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor
        )

        #expect(highlighted.string == code.text)
        #expect(!highlighted.string.contains("1  let"))
        #expect(keywordColor == MacSyntaxHighlighter.color(for: .keyword))
        #expect(commentColor == MacSyntaxHighlighter.color(for: .comment))
    }

    @Test func documentSurfaceAndCodeHighlightingFollowLiveThemeChanges() throws {
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        let columnStart = try #require(column.range(of: "struct MacToolDocumentColumn: View"))
        let descriptorStart = try #require(column.range(of: "struct MacToolDocumentDescriptorView: View"))
        let terminalStart = try #require(column.range(of: "private struct MacToolDocumentTerminalView: View"))
        let codeStart = try #require(column.range(of: "private struct MacToolDocumentCodeView: View"))
        let diffStart = try #require(column.range(of: "private struct MacToolDocumentDiffView: View"))
        let columnSource = String(column[columnStart.lowerBound..<descriptorStart.lowerBound])
        let terminalSource = String(column[terminalStart.lowerBound..<codeStart.lowerBound])
        let codeSource = String(column[codeStart.lowerBound..<diffStart.lowerBound])

        #expect(columnSource.contains(".themedScrollSurface()"))
        #expect(columnSource.contains(".foregroundStyle(theme.text.primary)"))
        #expect(terminalSource.contains(".foregroundStyle(theme.accent.green)"))
        #expect(codeSource.contains("@Environment(\\.themeID) private var themeID"))
        #expect(codeSource.contains("let _ = themeID"))
        #expect(codeSource.contains("MacSyntaxHighlighter.attributedCode"))
        #expect(!codeSource.contains("includeLineNumbers"))
    }

    @Test func diffPaintKeepsStructuredLineNumbersInsteadOfPlaintextDump() {
        let diff = ToolContentDescriptor.Diff(
            lines: [
                DiffLine(kind: .context, text: "keep", oldLineNumber: 10, newLineNumber: 10),
                DiffLine(kind: .added, text: "added line", oldLineNumber: nil, newLineNumber: 11),
                DiffLine(kind: .removed, text: "removed line", oldLineNumber: 11, newLineNumber: nil),
            ],
            path: "App.swift"
        )
        let rows = MacToolDocumentDiffLayout.rows(from: diff)

        #expect(MacToolDocumentColumnPaint.surface(for: .diff(diff)) == .diff)
        #expect(rows.map(\.kind) == [.context, .added, .removed])
        #expect(rows[0].oldLineNumber == 10)
        #expect(rows[1].newLineNumber == 11)
        #expect(rows[2].oldLineNumber == 11)
        #expect(!rows.contains { $0.text.hasPrefix("+++") || $0.text.hasPrefix("---") })
        #expect(!MacToolDocumentColumnPaint.paintsDiffAsPlaintextDump)
    }

    @Test func fileWithLanguageUsesSyntaxHighlighter() {
        let file = ToolContentDescriptor.File(
            text: "func main() {}",
            filePath: "main.go",
            fileType: .code(language: .go),
            language: .go,
            startLine: 1,
            attachments: []
        )
        #expect(MacToolDocumentColumnPaint.surface(for: .file(file)) == .file)
        #expect(MacToolDocumentColumnPaint.fileUsesSyntaxHighlighter(file))
    }

    @Test func mediaVisibleOutputPreservesTranscriptAndRemovesInlineAudioPayload() {
        let wav = Data([82, 73, 70, 70, 1, 2, 3, 4]).base64EncodedString()
        let media = ToolContentDescriptor.Media(
            output: "The voice transcript\n\ndata:audio/wav;base64,\(wav)",
            filePath: "Voice message",
            startLine: 1,
            attachments: [],
            audio: nil
        )
        let payloadOnly = ToolContentDescriptor.Media(
            output: "data:audio/wav;base64,\(wav)",
            filePath: "Voice message",
            startLine: 1,
            attachments: [],
            audio: nil
        )

        #expect(MacToolDocumentMediaPaint.visibleOutput(for: media) == "The voice transcript")
        #expect(MacToolDocumentMediaPaint.visibleOutput(for: payloadOnly).isEmpty)
    }

    @Test func shellKeepsFilesInspectorAndHostsAWideDocumentSplit() throws {
        let shell = try source(named: "OppiMac/Views/MacSessionShellViews.swift")
        #expect(shell.contains("HSplitView"))
        #expect(shell.contains("MacToolDocumentColumn"))
        #expect(shell.contains("MacToolDocumentColumnMetrics.minWidth"))
        #expect(shell.contains(".inspectorColumnWidth(min: 260, ideal: 320, max: 420)"))
        #expect(shell.contains("Session Files"))
        #expect(shell.contains("mac.session.toolbar.files"))
        #expect(shell.contains("MacAssistantAvatarView(avatar: .officialPi"))
        #expect(shell.contains("MacWorkspaceFileBrowserView("))
        #expect(!shell.contains("MacWorkspaceFileBrowserPresentation"))
        #expect(shell.contains("MacSessionFilesInspectorSection"))
        #expect(!shell.contains("fullScreenCover"))
        #expect(!shell.contains("WindowGroup"))

        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        #expect(column.contains("MacSyntaxHighlighter"))
        #expect(column.contains("diff.lines"))
        #expect(column.contains("toggleFullScreen"))
        #expect(!column.contains("inspectorColumnWidth"))
        #expect(!column.contains("MacDiffOutputModel"))
        #expect(!column.contains("fullScreenCover"))
        #expect(!column.contains("WindowGroup"))
        #expect(!column.contains(".sheet("))
        #expect(!column.contains(".keyboardShortcut(.escape"))
        #expect(column.contains("toolArgsStore.args"))
        #expect(column.contains("toolDetailsStore.details"))
    }

    private func apply(
        _ chord: KeybindingChord,
        mode: KeybindingMode,
        to state: inout MacTimelineKeybinding.State
    ) -> KeybindingAction? {
        MacTimelineKeybinding.apply(
            chord: chord,
            mode: mode,
            to: &state,
            toolRowIDs: toolRowIDs
        )
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("Mac session document column store")
@MainActor
struct MacSessionDocumentColumnStoreTests {
    @Test func storeOpensAndClosesTheDocumentColumn() {
        let originalMode = UserDefaults.standard.object(forKey: KeybindingMode.preferenceKey)
        defer { UserDefaults.standard.set(originalMode, forKey: KeybindingMode.preferenceKey) }
        let store = MacSessionTraceStore()
        store.keybindingMode = .macDefault
        store.selectToolRow("tool-a")

        #expect(store.openToolDocumentID == nil)
        #expect(store.applyKeybinding(.return, toolRowIDs: ["tool-a", "tool-b"]) == .openViewer)
        #expect(store.openToolDocumentID == "tool-a")

        #expect(store.applyKeybinding(.escape, toolRowIDs: ["tool-a", "tool-b"]) == .closeViewer)
        #expect(store.openToolDocumentID == nil)
        #expect(store.selectedToolRowID == "tool-a")
        #expect(store.keybindingFocus == .timeline)
    }

    @Test func changingSessionsClosesTheDocumentColumn() {
        let store = MacSessionTraceStore()
        store.select(makeDocumentColumnTarget(sessionId: "session-1"))
        store.selectToolRow("tool-a")
        #expect(store.applyKeybinding(.return, toolRowIDs: ["tool-a"]) == .openViewer)
        #expect(store.openToolDocumentID == "tool-a")

        store.select(makeDocumentColumnTarget(sessionId: "session-2"))

        #expect(store.openToolDocumentID == nil)
        #expect(store.selectedToolRowID == nil)
        #expect(store.keybindingFocus == .composer)
    }

    @Test func closeToolDocumentClearsTheColumn() {
        let store = MacSessionTraceStore()
        store.selectToolRow("tool-a")
        #expect(store.applyKeybinding(.commandReturn, toolRowIDs: ["tool-a"]) == .openViewer)
        store.keybindingFocus = .viewer

        store.closeToolDocument()

        #expect(store.openToolDocumentID == nil)
        #expect(store.keybindingFocus == .timeline)
    }

    @Test func modelBuildsADescriptorFromTheSelectedToolRow() {
        let items: [ChatItem] = [
            .toolCall(
                id: "tool-a",
                tool: "read",
                argsSummary: "path: App.swift",
                outputPreview: "let value = 1",
                outputByteCount: 13,
                isError: false,
                isDone: true
            ),
        ]
        let outputs = ToolOutputStore()
        outputs.replace("let value = 1\nlet next = 2", for: "tool-a", previewOnly: false)

        let model = MacToolDocumentColumnModel.make(
            toolRowID: "tool-a",
            items: items,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore()
        )

        #expect(model?.tool == "read")
        #expect(model?.toolRowID == "tool-a")
        guard case .file(let file) = model?.presentation.content else {
            Issue.record("Expected file descriptor, got \(String(describing: model?.presentation.content))")
            return
        }
        #expect(file.text.contains("let next = 2"))
        #expect(file.filePath == "App.swift")
    }

    @Test func editToolUsesArgsAndDetailsForStructuredDiffInsteadOfEditedCode() {
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

        let withoutStores = MacToolDocumentColumnModel.make(
            toolRowID: "edit-1",
            items: items,
            toolOutputStore: outputs,
            toolArgsStore: ToolArgsStore(),
            toolDetailsStore: ToolDetailsStore()
        )
        guard case .code(let code) = withoutStores?.presentation.content else {
            Issue.record("Expected .code without args/details, got \(String(describing: withoutStores?.presentation.content))")
            return
        }
        #expect(code.text == "Edited App.swift")

        let model = MacToolDocumentColumnModel.make(
            toolRowID: "edit-1",
            items: items,
            toolOutputStore: outputs,
            toolArgsStore: args,
            toolDetailsStore: details
        )
        guard case .diff(let diff) = model?.presentation.content else {
            Issue.record("Expected structured .diff, got \(String(describing: model?.presentation.content))")
            return
        }
        #expect(diff.path == "App.swift")
        #expect(diff.lines.contains { $0.kind == .removed && $0.text == "let value = 1" })
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "let value = 2" })
        #expect(MacToolDocumentColumnPaint.surface(for: model?.presentation.content) == .diff)
    }

    @Test func storeComposerEscapeDoesNotCloseTheColumn() {
        let originalMode = UserDefaults.standard.object(forKey: KeybindingMode.preferenceKey)
        defer { UserDefaults.standard.set(originalMode, forKey: KeybindingMode.preferenceKey) }
        let store = MacSessionTraceStore()
        store.keybindingMode = .macDefault
        store.selectToolRow("tool-a")
        #expect(store.applyKeybinding(.return, toolRowIDs: ["tool-a"]) == .openViewer)
        store.keybindingFocus = .composer

        #expect(store.applyKeybinding(.escape, toolRowIDs: ["tool-a"]) == nil)
        #expect(store.openToolDocumentID == "tool-a")
        #expect(store.keybindingFocus == .composer)
    }
}

private func makeDocumentColumnTarget(sessionId: String) -> MacSelectedSessionTarget {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = Session(
        id: sessionId,
        workspaceId: "workspace-document-column",
        workspaceName: "Workspace",
        status: .ready,
        createdAt: now,
        lastActivity: now,
        model: "provider/model",
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        firstMessage: "Hello"
    )
    return MacSelectedSessionTarget(
        workspaceId: "workspace-document-column",
        sessionId: session.id,
        summary: SessionSummary(from: session)
    )
}
