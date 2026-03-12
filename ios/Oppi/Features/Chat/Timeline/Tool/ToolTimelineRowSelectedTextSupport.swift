import Foundation

/// Pure-function helpers for selected-text source context resolution and selection flag
/// computation. Extracted from ToolTimelineRowContentView to isolate logic that is testable
/// without constructing UITextViews.
enum ToolTimelineRowSelectedTextSupport {

    /// Identifies which text surface is requesting a source context.
    enum Surface {
        case command
        case output
        case expandedLabel
        case expandedMarkdown
    }

    /// Computed selection flags for all text surfaces in a tool row.
    struct SelectionFlags: Equatable {
        let commandSelectable: Bool
        let outputSelectable: Bool
        let expandedLabelSelectable: Bool
        let markdownSelectable: Bool
        /// When true, tap-copy gestures and pinch should be disabled.
        let disableGestureInterception: Bool

        static let none = SelectionFlags(
            commandSelectable: false,
            outputSelectable: false,
            expandedLabelSelectable: false,
            markdownSelectable: false,
            disableGestureInterception: false
        )
    }

    // MARK: - Source context resolution

    /// Resolve which `SelectedTextSourceContext` applies for a given surface.
    ///
    /// - Parameters:
    ///   - surface: Which text view is requesting context.
    ///   - expandedContent: The current expanded content (nil when collapsed).
    ///   - sessionId: The active session identifier.
    ///   - sourceLabel: Display label for the tool (typically the tool title).
    ///   - expandedLabelText: Current text content of the expanded label, used for
    ///     line-range computation in code views. Pass nil for non-label surfaces.
    static func sourceContext(
        surface: Surface,
        expandedContent: ToolPresentationBuilder.ToolExpandedContent?,
        sessionId: String,
        sourceLabel: String,
        expandedLabelText: String?
    ) -> SelectedTextSourceContext? {
        switch surface {
        case .command:
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolCommand,
                sourceLabel: sourceLabel
            )

        case .output:
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolOutput,
                sourceLabel: sourceLabel
            )

        case .expandedLabel:
            guard let expandedContent else { return nil }
            return expandedLabelSourceContext(
                expandedContent: expandedContent,
                sessionId: sessionId,
                sourceLabel: sourceLabel,
                expandedLabelText: expandedLabelText
            )

        case .expandedMarkdown:
            guard let expandedContent else { return nil }
            guard case .markdown = expandedContent else { return nil }
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolExpandedText,
                sourceLabel: sourceLabel
            )
        }
    }

    // MARK: - Selection flag computation

    /// Compute selection flags from the interaction spec, visibility state, and context availability.
    static func selectionFlags(
        spec: TimelineInteractionSpec,
        showCommand: Bool,
        showOutput: Bool,
        showExpanded: Bool,
        hasCommandContext: Bool,
        hasOutputContext: Bool,
        hasExpandedContext: Bool,
        hasMarkdownContext: Bool,
        isMarkdownLayout: Bool,
        isReadMediaLayout: Bool
    ) -> SelectionFlags {
        let commandSelectable = showCommand
            && spec.commandSelectionEnabled
            && hasCommandContext

        let outputSelectable = showOutput
            && spec.outputSelectionEnabled
            && hasOutputContext

        let expandedLabelSelectable = showExpanded
            && !isReadMediaLayout
            && spec.expandedLabelSelectionEnabled
            && hasExpandedContext

        let markdownSelectable = showExpanded
            && isMarkdownLayout
            && spec.markdownSelectionEnabled
            && hasMarkdownContext

        return SelectionFlags(
            commandSelectable: commandSelectable,
            outputSelectable: outputSelectable,
            expandedLabelSelectable: expandedLabelSelectable,
            markdownSelectable: markdownSelectable,
            disableGestureInterception: markdownSelectable || expandedLabelSelectable
        )
    }

    // MARK: - Private

    private static func expandedLabelSourceContext(
        expandedContent: ToolPresentationBuilder.ToolExpandedContent,
        sessionId: String,
        sourceLabel: String,
        expandedLabelText: String?
    ) -> SelectedTextSourceContext? {
        switch expandedContent {
        case .code(_, let language, let startLine, let filePath):
            let lineRange: ClosedRange<Int>?
            if let startLine {
                let text = expandedLabelText ?? ""
                let lineCount = max(1, text.components(separatedBy: "\n").count)
                lineRange = startLine...(startLine + lineCount - 1)
            } else {
                lineRange = nil
            }
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolExpandedText,
                sourceLabel: sourceLabel,
                filePath: filePath,
                lineRange: lineRange,
                languageHint: language?.displayName
            )

        case .diff(_, let path):
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolExpandedText,
                sourceLabel: sourceLabel,
                filePath: path
            )

        case .text(_, let language):
            return SelectedTextSourceContext(
                sessionId: sessionId,
                surface: .toolExpandedText,
                sourceLabel: sourceLabel,
                languageHint: language?.displayName
            )

        case .bash, .markdown, .plot, .readMedia, .status:
            return nil
        }
    }
}
