@MainActor
enum ToolTimelineRowExpandedModeRouter {
    static func route<Visibility>(
        expandedContent: ToolPresentationBuilder.ToolExpandedContent,
        renderBash: (_ command: String?, _ output: String?, _ unwrapped: Bool) -> Visibility,
        renderDiff: (_ lines: [DiffLine], _ path: String?) -> Visibility,
        renderCode: (_ text: String, _ language: SyntaxLanguage?, _ startLine: Int?) -> Visibility,
        renderMarkdown: (_ text: String) -> Visibility,
        renderTodo: (_ output: String) -> Visibility,
        renderPlot: (_ spec: PlotChartSpec, _ fallbackText: String?) -> Visibility,
        renderReadMedia: (_ output: String, _ filePath: String?, _ startLine: Int) -> Visibility,
        renderText: (_ text: String, _ language: SyntaxLanguage?) -> Visibility
    ) -> Visibility {
        switch expandedContent {
        case .bash(let command, let output, let unwrapped):
            return renderBash(command, output, unwrapped)

        case .diff(let lines, let path):
            return renderDiff(lines, path)

        case .code(let text, let language, let startLine, _):
            return renderCode(text, language, startLine)

        case .markdown(let text):
            return renderMarkdown(text)

        case .todoCard(let output):
            return renderTodo(output)

        case .plot(let spec, let fallbackText):
            return renderPlot(spec, fallbackText)

        case .readMedia(let output, let filePath, let startLine):
            return renderReadMedia(output, filePath, startLine)

        case .text(let text, let language):
            return renderText(text, language)
        }
    }
}
