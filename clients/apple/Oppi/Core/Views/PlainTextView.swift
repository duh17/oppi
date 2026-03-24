import SwiftUI

// MARK: - PlainTextView

/// Monospaced text with line numbers (no syntax highlighting).
struct PlainTextView: View {
    let content: String
    let startLine: Int
    let presentation: FileContentPresentation
    let filePath: String?

    @Environment(\.selectedTextPiActionRouter) private var piRouter

    var body: some View {
        if presentation.usesInlineChrome {
            InlineFileContentChrome(
                label: "Text",
                content: content,
                fullScreenContent: .plainText(content: content, filePath: filePath),
                maxDisplayLines: FileContentView.maxDisplayLines,
                presentation: presentation
            ) { displayContent, _ in
                NativeCodeBodyView(
                    content: displayContent,
                    language: nil,
                    startLine: startLine,
                    maxHeight: presentation.viewportMaxHeight
                )
            }
        } else {
            NativeCodeBodyView(
                content: content,
                language: nil,
                startLine: startLine,
                selectedTextSourceContext: piRouter != nil
                    ? fileContentSourceContext(filePath: filePath, surface: .fullScreenSource)
                    : nil
            )
        }
    }
}
