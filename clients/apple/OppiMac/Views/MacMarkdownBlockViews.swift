import AppKit
import SwiftUI

struct MacOpenFileViewerAction: Sendable {
    let handler: @MainActor @Sendable (FileViewerPlan) -> Void

    init(_ handler: @escaping @MainActor @Sendable (FileViewerPlan) -> Void = { _ in }) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction(_ plan: FileViewerPlan) {
        handler(plan)
    }
}

private struct MacOpenFileViewerKey: EnvironmentKey {
    static let defaultValue = MacOpenFileViewerAction()
}

extension EnvironmentValues {
    var macOpenFileViewer: MacOpenFileViewerAction {
        get { self[MacOpenFileViewerKey.self] }
        set { self[MacOpenFileViewerKey.self] = newValue }
    }
}

/// Wiki and Markdown file links open `FileViewerPlan`. Other URLs stay system.
enum MacWikiFileLinkRouting {
    enum Decision: Equatable, Sendable {
        case open(FileViewerPlan)
        case ignoreResourceReference
        case system
    }

    static func decision(for url: URL, worktreeId: String? = nil) -> Decision {
        if let plan = FileViewerPlan.opening(url: url, worktreeId: worktreeId) {
            return .open(plan)
        }
        if url.scheme?.lowercased() == ResourceReferenceURL.scheme {
            return .ignoreResourceReference
        }
        return .system
    }

    @MainActor
    static func openURLResult(
        for url: URL,
        openFileViewer: MacOpenFileViewerAction,
        worktreeId: String? = nil
    ) -> OpenURLAction.Result {
        switch decision(for: url, worktreeId: worktreeId) {
        case .open(let plan):
            openFileViewer(plan)
            return .handled
        case .ignoreResourceReference:
            return .handled
        case .system:
            return .systemAction
        }
    }
}

/// Timeline prose vs thinking vs document chrome. Thinking keeps Settings
/// (message scale + mono) but paints one step quieter than user/assistant.
enum MacMarkdownTypography: Equatable, Sendable {
    case document
    case message
    case thinking

    var usesScaledMessageFont: Bool {
        self != .document
    }

    var usesThinkingForeground: Bool {
        self == .thinking
    }

    func resolvedTextStyle(_ requested: NSFont.TextStyle) -> NSFont.TextStyle {
        switch self {
        case .thinking:
            return .callout
        case .document, .message:
            return requested
        }
    }
}

enum MacMarkdownBlockWidthPaint: Sendable {
    enum Role: Equatable, Sendable {
        case prose
        case graphical
    }

    static func role(for block: MarkdownBlock) -> Role {
        guard case .codeBlock(let language, let code) = block else { return .prose }
        switch MacMarkdownPaintDispatch.codeBlockKind(language: language, code: code) {
        case .mermaidDiagram, .latexFormula:
            return .graphical
        default:
            return .prose
        }
    }

    static func maximumWidth(
        for block: MarkdownBlock,
        proseMaximumWidth: CGFloat?
    ) -> CGFloat {
        switch role(for: block) {
        case .prose:
            return proseMaximumWidth ?? .infinity
        case .graphical:
            return .infinity
        }
    }
}

/// Paints OppiCore `MarkdownBlock` trees. Parse happens in `MacMarkdownPaintDispatch`.
/// Timeline rows pass `itemID` so `MacMarkdownStreamingParserStore` can reuse one
/// `CommonMarkStreamingParser` per `ChatItem` across appends.
struct MacMarkdownDocumentView: View {
    let markdown: String
    var itemID: String? = nil
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var sourceDirectory: String? = nil
    var filePath: String? = nil
    var typography: MacMarkdownTypography = .document
    var proseMaximumWidth: CGFloat? = nil

    var body: some View {
        MacMarkdownBlockList(
            blocks: parsedBlocks,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: worktreeId,
            sourceDirectory: resolvedSourceDirectory,
            filePath: filePath,
            typography: typography,
            proseMaximumWidth: proseMaximumWidth
        )
    }

    /// iOS derives this from `sourceFilePath` via `deletingLastPathComponent`.
    /// Mac callers often pass `filePath` (document column) without `sourceDirectory`.
    private var resolvedSourceDirectory: String? {
        MacMarkdownPaintDispatch.resolvedSourceDirectory(
            sourceDirectory,
            filePath: filePath
        )
    }

    private var parsedBlocks: [MarkdownBlock] {
        if let itemID {
            return MacMarkdownStreamingParserStore.shared.parsedBlocks(
                itemID: itemID,
                markdown: markdown,
                workspaceID: workspaceID,
                sessionID: sessionID,
                sourceDirectory: resolvedSourceDirectory
            )
        }
        return MacMarkdownPaintDispatch.parsedBlocks(
            from: markdown,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: resolvedSourceDirectory
        )
    }
}

struct MacMarkdownBlockList: View {
    let blocks: [MarkdownBlock]
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var sourceDirectory: String? = nil
    var filePath: String? = nil
    var typography: MacMarkdownTypography = .document
    var proseMaximumWidth: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MacMarkdownBlockView(
                    block: block,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    worktreeId: worktreeId,
                    sourceDirectory: sourceDirectory,
                    filePath: filePath,
                    typography: typography,
                    proseMaximumWidth: proseMaximumWidth
                )
                .frame(
                    maxWidth: MacMarkdownBlockWidthPaint.maximumWidth(
                        for: block,
                        proseMaximumWidth: proseMaximumWidth
                    ),
                    alignment: .leading
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacMarkdownBlockView: View {
    let block: MarkdownBlock
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var sourceDirectory: String? = nil
    var filePath: String? = nil
    var typography: MacMarkdownTypography = .document
    var proseMaximumWidth: CGFloat? = nil
    @Environment(\.theme) private var theme

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let inlines):
            MacMarkdownInlineContent(
                inlines: inlines,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                sourceDirectory: sourceDirectory
            )
                .font(messageFont(
                    level == 1 ? .title3 : level == 2 ? .headline : .subheadline,
                    fallback: level == 1 ? .title3 : level == 2 ? .headline : .subheadline,
                    weight: .semibold
                ))
                .fontWeight(.semibold)
                .foregroundStyle(headingForeground)
        case .paragraph(let inlines):
            if let formula = MacMarkdownPaintDispatch.displayMathSource(from: inlines) {
                MacLatexFormulaView(code: formula)
            } else {
                MacMarkdownInlineContent(
                    inlines: inlines,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    worktreeId: worktreeId,
                    sourceDirectory: sourceDirectory
                )
                    .font(messageFont(.body, fallback: .body))
                    .foregroundStyle(proseForeground)
            }
        case .blockQuote(let children):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(theme.markdown.quoteBorder)
                    .frame(width: 3)
                MacMarkdownBlockList(
                    blocks: children,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    worktreeId: worktreeId,
                    sourceDirectory: sourceDirectory,
                    filePath: filePath,
                    typography: typography,
                    proseMaximumWidth: proseMaximumWidth
                )
                    .foregroundStyle(quoteForeground)
            }
        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•")
                            .font(messageFont(.body, fallback: .body))
                            .foregroundStyle(listForeground)
                        MacMarkdownBlockList(
                            blocks: item,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            worktreeId: worktreeId,
                            sourceDirectory: sourceDirectory,
                            filePath: filePath,
                            typography: typography,
                            proseMaximumWidth: proseMaximumWidth
                        )
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(start + offset).")
                            .font(messageFont(.body, fallback: .body))
                            .foregroundStyle(listForeground)
                        MacMarkdownBlockList(
                            blocks: item,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            worktreeId: worktreeId,
                            sourceDirectory: sourceDirectory,
                            filePath: filePath,
                            typography: typography,
                            proseMaximumWidth: proseMaximumWidth
                        )
                    }
                }
            }
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: item.checked ? "checkmark.square" : "square")
                            .foregroundStyle(theme.accent.green)
                        MacMarkdownBlockList(
                            blocks: item.content,
                            workspaceID: workspaceID,
                            sessionID: sessionID,
                            worktreeId: worktreeId,
                            sourceDirectory: sourceDirectory,
                            filePath: filePath,
                            typography: typography,
                            proseMaximumWidth: proseMaximumWidth
                        )
                    }
                }
            }
        case .thematicBreak:
            Divider()
                .overlay(theme.markdown.hr)
        case .table(let headers, let rows):
            MacMarkdownTableView(
                headers: headers,
                rows: rows,
                workspaceID: workspaceID,
                sessionID: sessionID,
                worktreeId: worktreeId,
                sourceDirectory: sourceDirectory,
                typography: typography
            )
        case .htmlBlock(let html):
            MacMarkupSourcePreviewView(
                source: html,
                kind: MacMarkupPreviewKind.from(htmlBlock: html),
                filePath: filePath
            )
        }
    }

    private func messageFont(
        _ textStyle: NSFont.TextStyle,
        fallback: Font,
        weight: NSFont.Weight = .regular
    ) -> Font {
        guard typography.usesScaledMessageFont else { return fallback }
        return Font(FontPreferenceStore.macMessageFont(
            forTextStyle: typography.resolvedTextStyle(textStyle),
            weight: weight
        ))
    }

    private var proseForeground: Color {
        typography.usesThinkingForeground ? theme.text.thinking : theme.text.primary
    }

    private var headingForeground: Color {
        typography.usesThinkingForeground ? theme.text.thinking : theme.markdown.heading
    }

    private var quoteForeground: Color {
        typography.usesThinkingForeground ? theme.text.thinking : theme.markdown.quote
    }

    private var listForeground: Color {
        typography.usesThinkingForeground ? theme.text.thinking : theme.markdown.listBullet
    }

    @ViewBuilder
    private func codeBlockView(language: String?, code: String) -> some View {
        switch MacMarkdownPaintDispatch.codeBlockKind(language: language, code: code) {
        case .mermaidDiagram(let diagram):
            MacMermaidDiagramView(code: diagram)
        case .latexFormula(let formula):
            MacLatexFormulaView(code: formula)
        case .codeListing(let listingLanguage, let listing):
            MacCodeOutputPreview(
                model: MacCodeOutputModel(language: listingLanguage, text: listing),
                source: MacReviewCommentSource.selectable(filePath: filePath)
            )
        default:
            MacCodeOutputPreview(
                model: MacCodeOutputModel(language: language, text: code),
                source: MacReviewCommentSource.selectable(filePath: filePath)
            )
        }
    }
}

/// Mac paint for GFM `MarkdownBlock.table`. Parse stays in OppiCore.
private struct MacMarkdownTableView: View {
    let headers: [[MarkdownInline]]
    let rows: [[[MarkdownInline]]]
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var sourceDirectory: String? = nil
    var typography: MacMarkdownTypography = .document
    @Environment(\.theme) private var theme

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        let columns = max(columnCount, 1)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(padded(headers, to: columns).enumerated()), id: \.offset) { _, cell in
                    cellView(cell)
                        .fontWeight(.semibold)
                        .foregroundStyle(headingForeground)
                }
            }
            GridRow {
                Rectangle()
                    .fill(theme.markdown.hr)
                    .frame(height: 1)
                    .gridCellColumns(columns)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(padded(row, to: columns).enumerated()), id: \.offset) { _, cell in
                        cellView(cell)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.markdown.codeBlockBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown.table")
    }

    private func padded(_ cells: [[MarkdownInline]], to count: Int) -> [[MarkdownInline]] {
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: [.text("")], count: count - cells.count)
    }

    @ViewBuilder
    private func cellView(_ cell: [MarkdownInline]) -> some View {
        MacMarkdownInlineContent(
            inlines: cell,
            workspaceID: workspaceID,
            sessionID: sessionID,
            worktreeId: worktreeId,
            sourceDirectory: sourceDirectory
        )
        .font(typography.usesScaledMessageFont
            ? Font(FontPreferenceStore.macMessageFont(
                forTextStyle: typography.resolvedTextStyle(.body)
            ))
            : .body)
        .foregroundStyle(proseForeground)
    }

    private var proseForeground: Color {
        typography.usesThinkingForeground ? theme.text.thinking : theme.text.primary
    }

    private var headingForeground: Color {
        typography.usesThinkingForeground ? theme.text.thinking : theme.markdown.heading
    }
}

struct MacMarkdownInlineContent: View {
    let inlines: [MarkdownInline]
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var worktreeId: String? = nil
    var sourceDirectory: String? = nil

    var body: some View {
        let runs = MacMarkdownPaintDispatch.inlineRuns(
            from: inlines,
            workspaceID: workspaceID,
            sessionID: sessionID
        )
        if runs.count == 1, case .text(let textInlines) = runs[0] {
            MacMarkdownInlineText(inlines: textInlines, worktreeId: worktreeId)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    switch run {
                    case .text(let textInlines):
                        MacMarkdownInlineText(inlines: textInlines, worktreeId: worktreeId)
                    case .image(let alt, let source, let imageWorkspaceID, let imageSessionID):
                        if MacMarkdownPaintDispatch.isSVGImageSource(source) {
                            MacMarkdownSVGView(
                                alt: alt,
                                source: source,
                                workspaceID: imageWorkspaceID,
                                sessionID: imageSessionID,
                                worktreeId: worktreeId,
                                sourceDirectory: sourceDirectory
                            )
                        } else {
                            MacMarkdownImageView(
                                alt: alt,
                                source: source,
                                workspaceID: imageWorkspaceID,
                                sessionID: imageSessionID,
                                worktreeId: worktreeId,
                                sourceDirectory: sourceDirectory
                            )
                        }
                    case .video(let embed):
                        MacMarkdownVideoView(embed: embed, worktreeId: worktreeId)
                    case .audio(let embed):
                        Text(embed.displayLabel)
                            .foregroundStyle(.secondary)
                    case .latexFormula(let code):
                        MacLatexFormulaView(code: code, isInline: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MacMarkdownInlineText: View {
    let inlines: [MarkdownInline]
    var worktreeId: String? = nil
    @Environment(\.theme) private var theme
    @Environment(\.macOpenFileViewer) private var openFileViewer

    var body: some View {
        Text(attributed(from: inlines))
            .environment(\.openURL, OpenURLAction { url in
                MacWikiFileLinkRouting.openURLResult(
                    for: url,
                    openFileViewer: openFileViewer,
                    worktreeId: worktreeId
                )
            })
    }

    private func attributed(from inlines: [MarkdownInline]) -> AttributedString {
        inlines.reduce(into: AttributedString()) { result, inline in
            result.append(attributed(from: inline))
        }
    }

    private func attributed(from inline: MarkdownInline) -> AttributedString {
        switch inline {
        case .text(let text):
            return AttributedString(text)
        case .emphasis(let children):
            var result = attributed(from: children)
            result.inlinePresentationIntent = .emphasized
            return result
        case .strong(let children):
            var result = attributed(from: children)
            result.inlinePresentationIntent = .stronglyEmphasized
            return result
        case .code(let code):
            var result = AttributedString(code)
            result.font = Font(FontPreferenceStore.macCodeFont())
            result.foregroundColor = theme.markdown.code
            return result
        case .link(let children, let destination):
            var result = attributed(from: children)
            if let destination, let url = URL(string: destination) {
                result.link = url
            }
            result.foregroundColor = theme.markdown.link
            result.underlineStyle = .single
            return result
        case .image(let alt, _):
            return AttributedString(alt)
        case .videoEmbed(let embed):
            var result = AttributedString(embed.displayLabel)
            result.foregroundColor = theme.markdown.link
            return result
        case .audioEmbed(let embed):
            var result = AttributedString(embed.displayLabel)
            result.foregroundColor = theme.markdown.link
            return result
        case .softBreak:
            return AttributedString(" ")
        case .hardBreak:
            return AttributedString("\n")
        case .html(let html):
            var result = AttributedString(html)
            result.foregroundColor = theme.markdown.code
            return result
        case .strikethrough(let children):
            var result = attributed(from: children)
            result.strikethroughStyle = .single
            return result
        }
    }
}
