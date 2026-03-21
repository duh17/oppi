import SwiftUI

// MARK: - CodeFileView

/// Source code with line numbers and syntax highlighting.
///
/// Uses ``NativeCodeBodyView`` (UIKit `UITextView` + gutter) for all
/// presentation modes. Inline wraps with SwiftUI chrome (header,
/// truncation notice, code block border).
struct CodeFileView: View {
    let content: String
    let language: SyntaxLanguage
    let startLine: Int
    let presentation: FileContentPresentation
    let filePath: String?

    @Environment(\.selectedTextPiActionRouter) private var piRouter

    var body: some View {
        if presentation.usesInlineChrome {
            InlineFileContentChrome(
                label: language.displayName,
                content: content,
                fullScreenContent: .code(
                    content: content, language: language.displayName,
                    filePath: filePath, startLine: startLine
                ),
                maxDisplayLines: FileContentView.maxDisplayLines,
                presentation: presentation,
                showCopy: false,
                showBorder: false
            ) { displayContent, _ in
                NativeCodeBodyView(
                    content: displayContent,
                    language: language.displayName,
                    startLine: startLine,
                    maxHeight: presentation.viewportMaxHeight
                )
            }
        } else {
            NativeCodeBodyView(
                content: content,
                language: language.displayName,
                startLine: startLine,
                selectedTextSourceContext: piRouter != nil
                    ? fileContentSourceContext(filePath: filePath, language: language.displayName)
                    : nil
            )
        }
    }
}
