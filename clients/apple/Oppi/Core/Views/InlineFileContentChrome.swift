import SwiftUI

/// Shared chrome wrapper for inline file content views.
///
/// Provides header (with line count, copy, expand), truncation notice,
/// full-screen sheet, and code block styling. Callers supply just the
/// inner content view via a `@ViewBuilder` closure.
struct InlineFileContentChrome<Content: View>: View {
    let label: String
    let content: String
    let fullScreenContent: FullScreenCodeContent
    let maxDisplayLines: Int
    let presentation: FileContentPresentation
    let showCopy: Bool
    let showBorder: Bool
    let copyContent: String?
    @ViewBuilder let innerContent: (_ displayContent: String, _ isTruncated: Bool) -> Content

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.reviewCommentSelectionRouter) private var reviewCommentSelectionRouter
    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @State private var showFullScreen = false

    init(
        label: String,
        content: String,
        fullScreenContent: FullScreenCodeContent,
        maxDisplayLines: Int,
        presentation: FileContentPresentation,
        showCopy: Bool = true,
        showBorder: Bool = true,
        copyContent: String? = nil,
        @ViewBuilder innerContent: @escaping (_ displayContent: String, _ isTruncated: Bool) -> Content
    ) {
        self.label = label
        self.content = content
        self.fullScreenContent = fullScreenContent
        self.maxDisplayLines = maxDisplayLines
        self.presentation = presentation
        self.showCopy = showCopy
        self.showBorder = showBorder
        self.copyContent = copyContent
        self.innerContent = innerContent
    }

    private var inlineReviewCommentSourceContext: ReviewCommentSourceContext? {
        guard let source = fullScreenContent.inlineReviewCommentSource else { return nil }
        let selectionContext = reviewCommentSelectionScope?.makeContext(
            sourceLabel: label,
            filePath: source.filePath,
            languageHint: source.languageHint
        ) ?? ReviewCommentSelectionContext(
            router: reviewCommentSelectionRouter,
            sourceLabel: label,
            filePath: source.filePath,
            languageHint: source.languageHint
        )

        return selectionContext?.sourceContext(
            surface: source.surface,
            sourceLabel: label,
            filePath: source.filePath,
            languageHint: source.languageHint
        )
    }

    var body: some View {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = min(lines.count, maxDisplayLines)
        let isTruncated = lines.count > maxDisplayLines
        let displayContent = isTruncated
            ? lines.prefix(lineCount).joined(separator: "\n")
            : content
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion

        VStack(alignment: .leading, spacing: 0) {
            FileHeader(
                label: label,
                lineCount: lines.count,
                copyContent: copyContent ?? content,
                showCopy: showCopy,
                onExpand: hasFullScreenAffordance ? { showFullScreen = true } : nil
            )

            innerContent(displayContent, isTruncated)
                .environment(\.reviewCommentSourceContext, inlineReviewCommentSourceContext)

            if isTruncated {
                TruncationNotice(showing: lineCount, total: lines.count)
            }
        }
        .codeBlockChrome(showBorder: showBorder)
        .fullScreenViewer(
            isPresented: $showFullScreen,
            content: fullScreenContent,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter
        )
    }
}

private struct InlineReviewCommentSourceInfo {
    let surface: ReviewCommentSurfaceKind
    let filePath: String?
    let languageHint: String?
}

private extension FullScreenCodeContent {
    var inlineReviewCommentSource: InlineReviewCommentSourceInfo? {
        switch self {
        case .code(_, let language, let filePath, _):
            return InlineReviewCommentSourceInfo(surface: .fullScreenCode, filePath: filePath, languageHint: language)
        case .plainText(_, let filePath):
            return InlineReviewCommentSourceInfo(surface: .fullScreenSource, filePath: filePath, languageHint: nil)
        case .graphviz(_, let filePath):
            return InlineReviewCommentSourceInfo(surface: .fullScreenCode, filePath: filePath, languageHint: "dot")
        case .latex(_, let filePath):
            return InlineReviewCommentSourceInfo(surface: .fullScreenCode, filePath: filePath, languageHint: "latex")
        case .orgMode(_, let filePath):
            return InlineReviewCommentSourceInfo(surface: .fullScreenCode, filePath: filePath, languageHint: "org")
        case .mermaid(_, let filePath):
            return InlineReviewCommentSourceInfo(surface: .fullScreenCode, filePath: filePath, languageHint: "mermaid")
        case .markdown, .html, .diff, .thinking, .terminal, .liveSource:
            return nil
        }
    }
}
