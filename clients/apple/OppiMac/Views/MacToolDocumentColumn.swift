import AppKit
import SwiftUI

/// Document column is a reading surface, not the Files inspector (260–420).
enum MacToolDocumentColumnMetrics {
    static let minWidth: CGFloat = 520
    static let idealWidth: CGFloat = 720
    static let headerActionSpacing: CGFloat = 14
}

enum MacToolDocumentDiffMetrics {
    static let lineNumberWidth: CGFloat = 42
    static let markerWidth: CGFloat = 22
    static let rowMinimumHeight: CGFloat = 20
}

enum MacToolDocumentColumnPaint {
    enum Surface: Equatable, Sendable {
        case terminal
        case diff
        case code
        case markdown
        case file
        case media
        case status
        case empty
    }

    /// Diffs paint `DiffLine` rows with gutters. They are not unified-text dumps.
    static let paintsDiffAsPlaintextDump = false

    static func surface(for descriptor: ToolContentDescriptor?) -> Surface {
        guard let descriptor else { return .empty }
        switch descriptor {
        case .terminal: return .terminal
        case .diff: return .diff
        case .code: return .code
        case .markdown: return .markdown
        case .file: return .file
        case .media: return .media
        case .status: return .status
        }
    }

    static func fileUsesSyntaxHighlighter(_ file: ToolContentDescriptor.File) -> Bool {
        file.language != nil
    }

    static func fileUsesMarkupPreview(_ file: ToolContentDescriptor.File) -> Bool {
        MacMarkupPreviewKind.from(file: file) != nil
    }

    static func fileUsesPDFPreview(_ file: ToolContentDescriptor.File) -> Bool {
        if file.fileType == .pdf {
            return true
        }
        if let path = file.filePath, FileType.detect(from: path) == .pdf {
            return true
        }
        return false
    }

    static func highlightedCode(_ code: ToolContentDescriptor.Code) -> NSAttributedString {
        MacSyntaxHighlighter.attributedCode(
            code.text,
            language: code.language,
            includeLineNumbers: true
        )
    }
}

struct MacToolDocumentDiffRow: Equatable, Sendable {
    var kind: DiffLine.Kind
    var text: String
    var oldLineNumber: Int?
    var newLineNumber: Int?
}

enum MacToolDocumentDiffLayout {
    static func rows(from diff: ToolContentDescriptor.Diff) -> [MacToolDocumentDiffRow] {
        diff.lines.map { line in
            MacToolDocumentDiffRow(
                kind: line.kind,
                text: line.text,
                oldLineNumber: line.oldLineNumber,
                newLineNumber: line.newLineNumber
            )
        }
    }
}

struct MacToolDocumentColumnModel: Equatable {
    let toolRowID: String
    let tool: String
    let argsSummary: String
    let presentation: ToolContentPresentation

    var title: String {
        if let path = documentPath, !path.isEmpty {
            return MacPathPaint.inspectorLabel(path)
        }
        return MacToolTimelineChrome.displayTitle(tool: tool)
    }

    var documentPath: String? {
        switch presentation.content {
        case .diff(let diff):
            return diff.path
        case .code(let code):
            return code.filePath
        case .file(let file):
            return file.filePath
        case .media(let media):
            return media.filePath
        case .terminal, .markdown, .status, .none:
            return nil
        }
    }

    @MainActor
    static func make(
        toolRowID: String?,
        items: [ChatItem],
        toolOutputStore: ToolOutputStore,
        toolArgsStore: ToolArgsStore,
        toolDetailsStore: ToolDetailsStore
    ) -> MacToolDocumentColumnModel? {
        guard let toolRowID,
              let item = items.first(where: { $0.id == toolRowID }),
              case .toolCall(_, let tool, let argsSummary, let outputPreview, _, let isError, let isDone) = item
        else {
            return nil
        }
        let stored = toolOutputStore.fullOutput(for: toolRowID)
        let presentation = ToolContentDescriptorBuilder.build(
            tool: tool,
            argsSummary: argsSummary,
            outputPreview: outputPreview,
            isError: isError,
            isDone: isDone,
            context: ToolContentDescriptorBuilder.Context(
                args: toolArgsStore.args(for: toolRowID),
                details: toolDetailsStore.details(for: toolRowID),
                fullOutput: stored.isEmpty ? outputPreview : stored,
                isLoadingOutput: toolOutputStore.hasPreviewOnlyOutput(for: toolRowID)
            )
        )
        return MacToolDocumentColumnModel(
            toolRowID: toolRowID,
            tool: tool,
            argsSummary: argsSummary,
            presentation: presentation
        )
    }
}

struct MacToolDocumentColumn: View {
    private enum Document {
        case session(MacSessionTraceStore)
        case workspaceFile(
            plan: FileViewerPlan,
            descriptor: ToolContentDescriptor?,
            isLoading: Bool,
            error: String?,
            close: () -> Void
        )
    }

    private let document: Document
    private var sessionFocus: FocusState<KeybindingFocus?>.Binding?
    @Environment(\.theme) private var theme
    @State private var fontPreferenceRevision = 0

    init(store: MacSessionTraceStore, sessionFocus: FocusState<KeybindingFocus?>.Binding) {
        self.document = .session(store)
        self.sessionFocus = sessionFocus
    }

    init(
        plan: FileViewerPlan,
        descriptor: ToolContentDescriptor?,
        isLoading: Bool,
        error: String?,
        close: @escaping () -> Void
    ) {
        self.document = .workspaceFile(
            plan: plan,
            descriptor: descriptor,
            isLoading: isLoading,
            error: error,
            close: close
        )
        self.sessionFocus = nil
    }

    var body: some View {
        let _ = fontPreferenceRevision
        Group {
            if let sessionFocus, let store = sessionStore {
                columnStack
                    .focusable(true)
                    .focused(sessionFocus, equals: .viewer)
                    .focusEffectDisabled(true)
                    .onKeyPress { press in
                        handleViewerKeyPress(press)
                    }
                    .task(id: store.openToolDocumentID) {
                        guard let id = store.openToolDocumentID else { return }
                        await store.loadFullToolOutputIfNeeded(itemID: id)
                    }
            } else {
                columnStack
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: FontPreferenceStore.didChangeNotification
        )) { _ in
            fontPreferenceRevision &+= 1
        }
    }

    private var columnStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            documentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScrollSurface()
        .foregroundStyle(theme.text.primary)
        .accessibilityIdentifier("mac.documentColumn")
    }

    private var sessionStore: MacSessionTraceStore? {
        if case .session(let store) = document {
            return store
        }
        return nil
    }

    private var sessionModel: MacToolDocumentColumnModel? {
        guard let store = sessionStore else { return nil }
        return MacToolDocumentColumnModel.make(
            toolRowID: store.openToolDocumentID,
            items: store.items,
            toolOutputStore: store.toolOutputStore,
            toolArgsStore: store.toolArgsStore,
            toolDetailsStore: store.toolDetailsStore
        )
    }

    private var title: String {
        switch document {
        case .session:
            return sessionModel?.title ?? "Document"
        case .workspaceFile(let plan, _, _, _, _):
            return plan.fileName
        }
    }

    private var documentPath: String? {
        switch document {
        case .session:
            return sessionModel?.documentPath
        case .workspaceFile(let plan, _, _, _, _):
            return plan.path
        }
    }

    private var descriptor: ToolContentDescriptor? {
        switch document {
        case .session:
            return sessionModel?.presentation.content
        case .workspaceFile(_, let descriptor, _, _, _):
            return descriptor
        }
    }

    private var documentKindLabel: String {
        switch MacToolDocumentColumnPaint.surface(for: descriptor) {
        case .terminal: "Terminal"
        case .diff: "Diff"
        case .code: "Code"
        case .markdown: "Markdown"
        case .file: "Source"
        case .media: "Media"
        case .status: "Status"
        case .empty: "Document"
        }
    }

    private var documentKindSymbol: String {
        switch MacToolDocumentColumnPaint.surface(for: descriptor) {
        case .terminal: "terminal"
        case .diff: "plus.forwardslash.minus"
        case .code, .file: "chevron.left.forwardslash.chevron.right"
        case .markdown: "doc.richtext"
        case .media: "play.rectangle"
        case .status: "hourglass"
        case .empty: "doc.text"
        }
    }

    private var diffSummary: String? {
        guard case .diff(let diff) = descriptor else { return nil }
        let stats = DiffEngine.stats(diff.lines)
        return "+\(stats.added) −\(stats.removed)"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: documentKindSymbol)
                .foregroundStyle(theme.text.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(documentKindLabel)
                    if let diffSummary {
                        Text(diffSummary)
                            .foregroundStyle(theme.text.primary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(theme.text.secondary)
            }
            .help(documentPath ?? title)
            Spacer(minLength: 8)
            HStack(spacing: MacToolDocumentColumnMetrics.headerActionSpacing) {
                if let documentPath {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(documentPath, forType: .string)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.clipboard")
                            .labelStyle(.iconOnly)
                    }
                    .help("Copy file path")
                    .accessibilityIdentifier("mac.documentColumn.copyPath")
                }
                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                }
                .help("Enter system full screen for this window")
                .accessibilityIdentifier("mac.documentColumn.fullScreen")
                Button {
                    closeDocument()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .help("Close document")
                .accessibilityIdentifier("mac.documentColumn.close")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var documentBody: some View {
        switch document {
        case .session(let store):
            if let descriptor = sessionModel?.presentation.content {
                MacToolDocumentDescriptorView(
                    descriptor: descriptor,
                    itemID: sessionModel?.toolRowID,
                    workspaceID: store.selectedTarget?.workspaceId,
                    sessionID: store.selectedTarget?.sessionId,
                    worktreeId: store.session?.worktreeId,
                    routeScope: store.selectedTarget?.routeScope
                )
            } else if store.openToolDocumentID != nil {
                ContentUnavailableView(
                    "Loading document",
                    systemImage: "doc.text",
                    description: Text("The selected tool document will appear here.")
                )
            } else {
                EmptyView()
            }
        case .workspaceFile(let plan, let descriptor, let isLoading, let error, _):
            if let error {
                ContentUnavailableView(
                    "Could not load file",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let descriptor {
                MacToolDocumentDescriptorView(
                    descriptor: descriptor,
                    itemID: plan.id,
                    workspaceID: plan.workspaceID,
                    sessionID: nil,
                    worktreeId: plan.worktreeId,
                    routeScope: nil
                )
            } else if isLoading {
                ContentUnavailableView(
                    "Loading document",
                    systemImage: "doc.text",
                    description: Text("The selected workspace file will appear here.")
                )
            } else {
                EmptyView()
            }
        }
    }

    private func closeDocument() {
        switch document {
        case .session(let store):
            store.closeToolDocument()
        case .workspaceFile(_, _, _, _, let close):
            close()
        }
    }

    private func handleViewerKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard let sessionFocus, sessionFocus.wrappedValue == .viewer else { return .ignored }
        guard let store = sessionStore else { return .ignored }
        guard let chord = KeybindingEventMap.chord(
            characters: press.characters,
            isUpArrow: press.key == .upArrow,
            isDownArrow: press.key == .downArrow,
            isLeftArrow: press.key == .leftArrow,
            isRightArrow: press.key == .rightArrow,
            isReturn: press.key == .return,
            isEscape: press.key == .escape,
            isTab: press.key == .tab,
            command: press.modifiers.contains(.command),
            shift: press.modifiers.contains(.shift),
            option: press.modifiers.contains(.option),
            control: press.modifiers.contains(.control)
        ) else {
            return .ignored
        }
        let action = store.applyKeybinding(chord)
        return MacTimelineKeybinding.consumes(action) ? .handled : .ignored
    }
}

struct MacToolDocumentDescriptorView: View {
    let descriptor: ToolContentDescriptor
    var itemID: String? = nil
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var routeScope: SessionRouteScope? = nil

    var body: some View {
        switch descriptor {
        case .terminal(let terminal):
            MacToolDocumentTerminalView(terminal: terminal, itemID: itemID)
        case .diff(let diff):
            MacToolDocumentDiffView(diff: diff)
        case .code(let code):
            MacToolDocumentCodeView(code: code, itemID: itemID)
        case .markdown(let markdown):
            ScrollView {
                MacMarkdownDocumentView(
                    markdown: markdown.text,
                    itemID: itemID,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    worktreeId: worktreeId
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        case .file(let file):
            MacToolDocumentFileView(
                file: file,
                itemID: itemID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
        case .media(let media):
            MacToolDocumentMediaView(
                media: media,
                itemID: itemID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                routeScope: routeScope
            )
        case .status(let message):
            ContentUnavailableView(
                message,
                systemImage: "hourglass",
                description: Text("This tool has no document body yet.")
            )
        }
    }
}

private struct MacToolDocumentTerminalView: View {
    let terminal: ToolContentDescriptor.Terminal
    var itemID: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = terminal.command, !command.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("$")
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.accent.green)
                    Text(command)
                        .textSelection(.enabled)
                }
                .font(Font(FontPreferenceStore.macCodeFont()))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            MacReviewCommentTextView(
                text: terminal.output?.isEmpty == false ? terminal.output ?? "" : " ",
                source: MacReviewCommentSource(
                    kind: .terminalOutput,
                    label: terminal.command,
                    timelineItemId: itemID
                ),
                fillsColumn: true,
                accessibilityIdentifier: "mac.documentColumn.terminal"
            )
        }
        .accessibilityIdentifier("mac.documentColumn.terminal")
    }
}

private struct MacToolDocumentCodeView: View {
    let code: ToolContentDescriptor.Code
    var itemID: String? = nil
    @Environment(\.themeID) private var themeID

    var body: some View {
        let _ = themeID
        MacReviewCommentTextView(
            text: code.text,
            attributedText: MacSyntaxHighlighter.attributedCode(
                code.text,
                language: code.language,
                includeLineNumbers: false
            ),
            source: code.filePath == nil
                ? MacReviewCommentSource(
                    kind: .toolOutput,
                    timelineItemId: itemID,
                    startLine: code.startLine ?? 1
                )
                : MacReviewCommentSource.fileDocument(
                    path: code.filePath,
                    itemID: itemID,
                    startLine: code.startLine ?? 1
                ),
            fillsColumn: false,
            accessibilityIdentifier: "mac.documentColumn.code"
        )
        .accessibilityIdentifier("mac.documentColumn.code")
    }
}

private struct MacToolDocumentDiffView: View {
    let diff: ToolContentDescriptor.Diff
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(MacToolDocumentDiffLayout.rows(from: diff).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(gutter(row.oldLineNumber))
                                .frame(width: MacToolDocumentDiffMetrics.lineNumberWidth, alignment: .trailing)
                            Text(gutter(row.newLineNumber))
                                .frame(width: MacToolDocumentDiffMetrics.lineNumberWidth, alignment: .trailing)
                            Text(row.kind.prefix)
                                .foregroundStyle(color(for: row.kind))
                                .frame(width: MacToolDocumentDiffMetrics.markerWidth, alignment: .center)
                            Rectangle()
                                .fill(theme.text.tertiary.opacity(0.16))
                                .frame(width: 1)
                            Text(row.text.isEmpty ? " " : row.text)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.leading, 10)
                                .padding(.trailing, 12)
                        }
                        .font(Font(FontPreferenceStore.macCodeFont()))
                        .foregroundStyle(color(for: row.kind))
                        .frame(minHeight: MacToolDocumentDiffMetrics.rowMinimumHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: row.kind))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(changeBar(for: row.kind))
                                .frame(width: 3)
                        }
                        .textSelection(.enabled)
                    }
                }
                .frame(
                    minWidth: proxy.size.width,
                    minHeight: proxy.size.height,
                    alignment: .topLeading
                )
            }
        }
        .accessibilityIdentifier("mac.documentColumn.diff")
    }

    private func gutter(_ number: Int?) -> String {
        number.map(String.init) ?? ""
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme.diff.addedAccent
        case .removed: theme.diff.removedAccent
        case .context: theme.diff.contextFg
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme.diff.addedBg
        case .removed: theme.diff.removedBg
        case .context: Color.clear
        }
    }

    private func changeBar(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: theme.diff.addedAccent
        case .removed: theme.diff.removedAccent
        case .context: .clear
        }
    }
}

private struct MacToolDocumentFileView: View {
    let file: ToolContentDescriptor.File
    var itemID: String?
    var workspaceID: String?
    var sessionID: String?
    var worktreeId: String?

    var body: some View {
        if MacToolDocumentColumnPaint.fileUsesPDFPreview(file) {
            MacToolDocumentPDFView(
                file: file,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId
            )
        } else if let kind = MacMarkupPreviewKind.from(file: file) {
            MacMarkupSourcePreviewView(
                source: file.text,
                kind: kind,
                fillsColumn: true,
                filePath: file.filePath,
                itemID: itemID
            )
            .padding(12)
        } else if MacToolDocumentColumnPaint.fileUsesSyntaxHighlighter(file) {
            MacToolDocumentCodeView(
                code: ToolContentDescriptor.Code(
                    text: file.text,
                    language: file.language,
                    startLine: file.startLine,
                    filePath: file.filePath
                ),
                itemID: itemID
            )
        } else if file.fileType == .markdown {
            ScrollView {
                MacMarkdownDocumentView(
                    markdown: file.text,
                    itemID: itemID,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    worktreeId: worktreeId,
                    filePath: file.filePath
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        } else {
            MacToolDocumentCodeView(
                code: ToolContentDescriptor.Code(
                    text: file.text,
                    language: file.language,
                    startLine: file.startLine,
                    filePath: file.filePath
                ),
                itemID: itemID
            )
        }
    }
}
