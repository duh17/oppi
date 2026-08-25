import Foundation
import Testing
import UIKit
@testable import Oppi

/// Regression: the Math and LaTeX section of the markdown-rendering stress
/// fixture must become formula segments, not paragraphs that still contain `$$`.
@Suite("Markdown stress-fixture display math")
struct MarkdownStressFixtureDisplayMathTests {
    private static let mathSection = #"""
    # Math and LaTeX

    Inline identities should sit in normal prose: $a^2 + b^2 = c^2$, $\sqrt{x^2 + y^2}$, $\frac{1}{n}\sum_{i=1}^{n} x_i$, and $\mathbf{v} \cdot \mathbf{w} = 0$.

    A display equation follows:

    $$
    \int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
    $$

    Another display tests matrices and alignment:

    $$
    \begin{aligned}
      A &= \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}, &
      \det(A) &= -2 \\
      B &= A^{-1}, &
      AB &= I
    \end{aligned}
    $$

    A probability example:

    $$
    P(A \mid B) = \frac{P(B \mid A)P(A)}{P(B)}
    $$

    A fenced LaTeX block:

    ```latex
    \boxed{e^{i\pi} + 1 = 0}

    \mathcal{L}(\theta) = -\sum_{i=1}^{n} y_i \log \hat{y}_i
    ```

    A long expression for wrapping:

    $$
    \operatorname*{arg\,min}_{\theta \in \mathbb{R}^{d}}\left[\frac{1}{n}\sum_{i=1}^{n}\left(f_{\theta}(x_i)-y_i\right)^2 + \lambda\lVert\theta\rVert_2^2\right]
    $$
    """#

    @Test func parsePromotesFixtureDisplaysToLatexCodeBlocks() {
        let blocks = parseCommonMark(Self.mathSection)
        let latexBlocks = blocks.compactMap { block -> String? in
            guard case .codeBlock(let language, let code) = block,
                  language == "latex" else {
                return nil
            }
            return code
        }
        let paragraphText = blocks.compactMap { block -> String? in
            guard case .paragraph(let inlines) = block else { return nil }
            return inlines.compactMap { inline -> String? in
                if case .text(let text) = inline { return text }
                return nil
            }.joined()
        }.joined(separator: "\n")

        #expect(latexBlocks.count >= 5)
        #expect(latexBlocks.contains { $0.contains(#"\int_{0}^{\infty}"#) })
        #expect(latexBlocks.contains { $0.contains(#"\begin{aligned}"#) && $0.contains(#"\begin{bmatrix}"#) })
        #expect(latexBlocks.contains { $0.contains(#"\mid"#) })
        #expect(latexBlocks.contains { $0.contains(#"\boxed"#) })
        #expect(latexBlocks.contains { $0.contains(#"\operatorname*"#) })
        #expect(!paragraphText.contains("$$"))
        #expect(!paragraphText.contains(#"\begin{aligned}"#))
        #expect(!paragraphText.contains(#"\operatorname*"#))
    }

    @Test func renderedSegmentsAreFormulasNotRawDollars() {
        let segments = FlatSegment.build(from: parseCommonMark(Self.mathSection), themeID: .dark)
        let formulas = segments.compactMap { segment -> String? in
            guard case .latexBlock(let source) = segment else { return nil }
            return source
        }
        let prose = segments.compactMap { segment -> String? in
            guard case .text(let attributed) = segment else { return nil }
            return String(attributed.characters)
        }.joined(separator: "\n")

        #expect(formulas.count >= 5)
        #expect(formulas.contains { $0.contains(#"\int_{0}^{\infty}"#) })
        #expect(formulas.contains { $0.contains(#"\begin{aligned}"#) })
        #expect(formulas.contains { $0.contains(#"P(A \mid B)"#) })
        #expect(formulas.contains { $0.contains(#"\boxed{e^{i\pi} + 1 = 0}"#) })
        #expect(formulas.contains { $0.contains(#"\operatorname*"#) })
        #expect(!prose.contains("$$"))
        #expect(!prose.contains(#"\begin{aligned}"#))
        #expect(!prose.contains(#"\mid"#))
        #expect(!prose.contains(#"\operatorname*"#))
        #expect(prose.contains("Inline identities"))
        #expect(prose.contains("A probability example"))
    }

    @MainActor
    @Test func fixtureDisplaysRasterizeAsFormulas() throws {
        let cases = [
            #"P(A \mid B) = \frac{P(B \mid A)P(A)}{P(B)}"#,
            #"\boxed{e^{i\pi} + 1 = 0}"#,
            #"\operatorname*{arg\,min}_{\theta \in \mathbb{R}^{d}} x"#,
        ]

        for source in cases {
            let validation = TeXMathParser().parseValidated(source)
            #expect(validation.isRenderable, "Not renderable: \(source) diagnostics=\(validation.diagnostics)")

            let view = NativeLatexBlockView()
            view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
            view.layoutIfNeeded()
            view.applyAsFormulaSync(code: source, palette: ThemeID.dark.palette)
            view.layoutIfNeeded()

            let imageView = try #require(timelineAllImageViews(in: view).first {
                timelineViewIsVisible($0) && $0.image != nil
            }, "Expected a rasterized formula for \(source)")
            let image = try #require(imageView.image)
            #expect(image.size.width > AppFont.messageBody.pointSize)
            #expect(image.size.height > AppFont.messageBody.pointSize * 0.5)
        }
    }
}
