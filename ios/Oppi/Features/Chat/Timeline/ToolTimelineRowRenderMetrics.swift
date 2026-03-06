import UIKit

enum ToolTimelineRowRenderMetrics {
    private static func combineActiveTheme(into hasher: inout Hasher) {
        hasher.combine(ThemeRuntimeState.currentThemeID())
    }

    static func estimatedMonospaceLineWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 1 }

        let maxLineLength = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).reduce(0) { max($0, $1.count) }

        guard maxLineLength > 0 else { return 1 }

        let font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        return ceil(charWidth * CGFloat(maxLineLength)) + 12
    }

    static func displayCommandText(_ text: String) -> String {
        ToolRowTextRenderer.displayCommandText(text)
    }

    static func displayOutputText(_ text: String) -> String {
        ToolRowTextRenderer.displayOutputText(text)
    }

    static func commandSignature(displayCommand: String) -> Int {
        var hasher = Hasher()
        hasher.combine("command")
        combineActiveTheme(into: &hasher)
        hasher.combine(displayCommand)
        hasher.combine(displayCommand.utf8.count <= ToolRowTextRenderer.maxShellHighlightBytes)
        return hasher.finalize()
    }

    static func outputSignature(displayOutput: String, isError: Bool, unwrapped: Bool, isStreaming: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine("bash-output")
        combineActiveTheme(into: &hasher)
        hasher.combine(displayOutput)
        hasher.combine(isError)
        hasher.combine(unwrapped)
        hasher.combine(isStreaming)
        return hasher.finalize()
    }

    static func diffSignature(lines: [DiffLine], path: String?, isStreaming: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine("diff")
        combineActiveTheme(into: &hasher)
        hasher.combine(path ?? "")
        hasher.combine(isStreaming)
        hasher.combine(lines.count)
        for line in lines {
            switch line.kind {
            case .context:
                hasher.combine(0)
            case .added:
                hasher.combine(1)
            case .removed:
                hasher.combine(2)
            }
            hasher.combine(line.text)
        }
        return hasher.finalize()
    }

    static func codeSignature(
        displayText: String,
        language: SyntaxLanguage?,
        startLine: Int,
        isStreaming: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("code")
        combineActiveTheme(into: &hasher)
        hasher.combine(displayText)
        hasher.combine(language)
        hasher.combine(startLine)
        hasher.combine(isStreaming)
        return hasher.finalize()
    }

    static func markdownSignature(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine("markdown")
        combineActiveTheme(into: &hasher)
        hasher.combine(text)
        return hasher.finalize()
    }

    static func readMediaSignature(
        output: String,
        filePath: String?,
        startLine: Int,
        isError: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("read-media")
        combineActiveTheme(into: &hasher)
        hasher.combine(output)
        hasher.combine(filePath ?? "")
        hasher.combine(startLine)
        hasher.combine(isError)
        return hasher.finalize()
    }

    static func plotSignature(spec: PlotChartSpec, fallbackText: String?) -> Int {
        var hasher = Hasher()
        hasher.combine("plot")
        combineActiveTheme(into: &hasher)
        hasher.combine(spec)
        hasher.combine(fallbackText)
        return hasher.finalize()
    }

    static func textSignature(
        displayText: String,
        language: SyntaxLanguage?,
        isError: Bool,
        isStreaming: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("text")
        combineActiveTheme(into: &hasher)
        hasher.combine(displayText)
        hasher.combine(language)
        hasher.combine(isError)
        hasher.combine(isStreaming)
        return hasher.finalize()
    }
}
