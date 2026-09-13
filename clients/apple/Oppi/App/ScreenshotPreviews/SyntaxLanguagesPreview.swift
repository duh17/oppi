#if DEBUG
import Foundation
import SwiftUI
import UIKit

// MARK: - Tree-sitter vs line-scanner paint preview

/// Same samples through production tree-sitter tokens or the leftover line scanner.
/// DEBUG-only; paints synchronously so ui-validate captures colors.
struct SyntaxLanguagesPreview: View {
    enum Page {
        case webAndDynamic
        case systemsAndMarkup
    }

    enum Engine {
        case treeSitter
        case scanner

        var title: String {
            switch self {
            case .treeSitter: return "Tree-sitter"
            case .scanner: return "Line scanner"
            }
        }
    }

    struct Sample: Identifiable {
        let id: String
        let language: SyntaxLanguage
        let code: String
    }

    private let page: Page
    private let engine: Engine
    private let themeID: ThemeID

    init(page: Page, engine: Engine) {
        self.page = page
        self.engine = engine
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(engine.title) — \(page.headline)")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text(engine == .treeSitter
                     ? "Query tokens. Continuation lines should keep string/comment color."
                     : "Old line scanner. Continuation lines usually lose string/comment color.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                ForEach(page.samples) { sample in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(sample.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.themeComment)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.themeBgHighlight)
                        SyntaxPreviewCodeView(
                            text: Self.highlighted(
                                sample.code,
                                language: sample.language,
                                themeID: themeID,
                                engine: engine
                            )
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                    .background(Color.themeBgDark)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(themeID.palette.mdCodeBlockBorder.opacity(0.5), lineWidth: 1)
                    }
                }
            }
            .padding(16)
            .accessibilityIdentifier("syntax.languages.preview.content")
        }
        .background(Color.themeBg.ignoresSafeArea())
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    private static func highlighted(
        _ code: String,
        language: SyntaxLanguage,
        themeID: ThemeID,
        engine: Engine
    ) -> NSAttributedString {
        let ranges: [SyntaxTokenRange]
        switch engine {
        case .treeSitter:
            ranges = TreeSitterHighlighter.resolvedTokenRanges(code, language: language)
        case .scanner:
            ranges = SyntaxTokenScanner.scanTokenRanges(code, language: language)
        }

        let font = AppFont.monoMedium
        let result = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: UIColor(themeID.palette.syntaxVariable),
            ]
        )
        let nsLength = result.length
        for token in ranges {
            guard token.kind != .variable,
                  let color = SyntaxHighlighter.color(for: token.kind, themeID: themeID) else {
                continue
            }
            let range = NSRange(location: token.location, length: token.length)
            guard range.location >= 0, NSMaxRange(range) <= nsLength else { continue }
            result.addAttribute(.foregroundColor, value: color, range: range)
        }
        return result
    }
}


private struct SyntaxPreviewCodeView: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = text
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let fallbackWidth = uiView.window?.windowScene?.screen.bounds.width ?? uiView.bounds.width
        let width = proposal.width ?? fallbackWidth
        guard width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        )
        return CGSize(width: width, height: max(1, fitting.height))
    }
}


extension SyntaxLanguagesPreview.Page {
    var headline: String {
        switch self {
        case .webAndDynamic: return "JS/TS/Python/Go/Rust"
        case .systemsAndMarkup: return "C/C++/HTML/CSS/Ruby/Java"
        }
    }

    fileprivate var samples: [SyntaxLanguagesPreview.Sample] {
        switch self {
        case .webAndDynamic:
            return [
                .init(id: "javascript", language: .javascript, code: """
                    const name = `hello
                    world`
                    foo()
                    """),
                .init(id: "jsx", language: .jsx, code: "const el = <div className=\"x\" />"),
                .init(id: "typescript", language: .typescript, code: """
                    const n: number = 1
                    function foo(): void {}
                    """),
                .init(id: "tsx", language: .tsx, code: "const el = <div className=\"x\" />"),
                .init(id: "python", language: .python, code: """
                    s = \"\"\"hello
                    world\"\"\"
                    print(s)
                    """),
                .init(id: "go", language: .go, code: """
                    func Hello() {
                        s := `hello
                    world`
                    }
                    """),
                .init(id: "rust", language: .rust, code: """
                    fn hello() {
                        let s = \"hello
                    world\";
                    }
                    """),
            ]
        case .systemsAndMarkup:
            return [
                .init(id: "c", language: .c, code: """
                    /* keep
                    color */
                    int main(void) { return 0; }
                    """),
                .init(id: "cpp", language: .cpp, code: """
                    const char* s = R\"(hello
                    rawline)\";
                    """),
                .init(id: "html", language: .html, code: """
                    <!-- keep
                    color -->
                    <div class=\"x\"></div>
                    """),
                .init(id: "css", language: .css, code: """
                    /* keep
                    color */
                    .foo { content: \"x\"; }
                    """),
                .init(id: "ruby", language: .ruby, code: """
                    s = \"hello
                    world\"
                    def foo
                    end
                    """),
                .init(id: "java", language: .java, code: """
                    /* keep
                    color */
                    class Foo { void bar() {} }
                    """),
                .init(id: "swift", language: .swift, code: """
                    let s = \"\"\"
                    still scanner
                    \"\"\"
                    print(s)
                    """),
            ]
        }
    }
}
#endif
