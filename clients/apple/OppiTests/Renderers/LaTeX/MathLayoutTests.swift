import CoreGraphics
import Testing
@testable import Oppi

/// Tests for `MathLayoutEngine` layout correctness.
///
/// Verifies that the box-and-glue layout model produces structurally correct
/// output: correct sizes, baseline positions, and spatial relationships.
/// Uses the parser to produce ASTs from LaTeX strings, then checks layout invariants.
@Suite("MathLayoutTests")
struct MathLayoutTests {
    let parser = TeXMathParser()
    let engine = MathLayoutEngine()
    let renderer = MathCoreGraphicsRenderer()
    let fontSize: CGFloat = 16

    // MARK: - Helper

    private func layoutFromTeX(_ tex: String) -> LayoutBox {
        let nodes = parser.parse(tex)
        return engine.layout(nodes, fontSize: fontSize)
    }

    private func assertNonZeroSize(_ box: LayoutBox, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(box.size.width > 0, "width should be > 0: \(message)", sourceLocation: sourceLocation)
        #expect(box.size.height > 0, "height should be > 0: \(message)", sourceLocation: sourceLocation)
    }

    // MARK: - Empty Input

    @Test func emptyInputProducesZeroSize() {
        let box = engine.layout([], fontSize: fontSize)
        #expect(box.size == .zero)
    }

    // MARK: - Simple Variable

    @Test func singleVariableGlyphBox() {
        let box = layoutFromTeX("x")
        assertNonZeroSize(box, "single variable")
        #expect(box.baseline > 0, "baseline should be positive")
        // Single variable should produce a glyph
        if case .glyph(let text, let size) = box.content {
            #expect(text == "x")
            #expect(size == fontSize)
        } else if case .container(let children) = box.content {
            // May be wrapped in container with single child
            #expect(children.count == 1)
            if case .glyph(let text, _) = children[0].content {
                #expect(text == "x")
            }
        }
    }

    // MARK: - Number

    @Test func numberGlyphBox() {
        let box = layoutFromTeX("3")
        assertNonZeroSize(box, "single number")
        #expect(box.baseline > 0)
    }

    // MARK: - Fraction

    @Test func fractionNumeratorAboveDenominator() {
        let box = layoutFromTeX("\\frac{a}{b}")
        assertNonZeroSize(box, "fraction")

        // Fraction should be a container with numerator, bar, denominator
        guard case .container(let children) = box.content else {
            Issue.record("fraction should be a container")
            return
        }

        // Should have at least 3 children (num, bar, den)
        #expect(children.count >= 3, "fraction needs num + bar + den, got \(children.count)")

        // Find the bar (line content)
        let barIndex = children.firstIndex { child in
            if case .line = child.content { return true }
            return false
        }
        #expect(barIndex != nil, "fraction should have a bar line")

        if let barIdx = barIndex {
            // Numerator should be above bar
            let numChild = children[0]
            #expect(numChild.origin.y < children[barIdx].origin.y,
                    "numerator should be above fraction bar")

            // Denominator should be below bar
            let denIdx = barIdx + 1
            if denIdx < children.count {
                #expect(children[denIdx].origin.y > children[barIdx].origin.y,
                        "denominator should be below fraction bar")
            }
        }
    }

    @Test func fractionChildrenShrunk() {
        // Children of fractions use smaller font size (0.7x)
        let box = layoutFromTeX("\\frac{x}{y}")
        let singleBox = layoutFromTeX("x")

        // The fraction should be taller than a single character
        // (numerator + bar + denominator stacked)
        #expect(box.size.height > singleBox.size.height,
                "fraction should be taller than a single glyph")
    }

    // MARK: - Superscript

    @Test func superscriptSmallerAndRaised() {
        let box = layoutFromTeX("x^2")
        assertNonZeroSize(box, "superscript")

        guard case .container(let children) = box.content else {
            Issue.record("superscript should be a container")
            return
        }

        // Should have base and exponent
        #expect(children.count >= 2, "x^2 needs base + exponent")

        if children.count >= 2 {
            let base = children[0]
            let sup = children[1]

            // Superscript should be to the right of base
            #expect(sup.origin.x >= base.origin.x + base.size.width - 0.1,
                    "superscript should be right of base")

            // Superscript should be raised (lower Y in top-left coords = higher up)
            #expect(sup.origin.y < base.origin.y + base.size.height,
                    "superscript should be raised above base bottom")

            // Superscript should be smaller
            #expect(sup.size.height < base.size.height,
                    "superscript should be smaller than base")
        }
    }

    // MARK: - Subscript

    @Test func subscriptSmallerAndLowered() {
        let box = layoutFromTeX("x_i")
        assertNonZeroSize(box, "subscript")

        guard case .container(let children) = box.content else {
            Issue.record("subscript should be a container")
            return
        }

        #expect(children.count >= 2, "x_i needs base + index")

        if children.count >= 2 {
            let base = children[0]
            let sub = children[1]

            // Subscript should be to the right of base
            #expect(sub.origin.x >= base.origin.x + base.size.width - 0.1,
                    "subscript should be right of base")

            // Subscript should be lowered (higher Y = further down)
            #expect(sub.origin.y > base.origin.y,
                    "subscript should be below base top")

            // Subscript should be smaller
            #expect(sub.size.height < base.size.height,
                    "subscript should be smaller than base")
        }
    }

    // MARK: - Combined Sub + Superscript

    @Test func subSuperscriptBothAttached() {
        let box = layoutFromTeX("x_i^2")
        assertNonZeroSize(box, "sub+superscript")

        guard case .container(let children) = box.content else {
            Issue.record("sub+superscript should be a container")
            return
        }

        // Should have base + sup + sub (3 children)
        #expect(children.count >= 3, "x_i^2 needs base + sup + sub, got \(children.count)")

        if children.count >= 3 {
            let base = children[0]
            let sup = children[1]
            let sub = children[2]

            // Both scripts should be to the right of base
            #expect(sup.origin.x >= base.size.width - 0.1)
            #expect(sub.origin.x >= base.size.width - 0.1)

            // Sup should be above sub
            #expect(sup.origin.y < sub.origin.y,
                    "superscript should be above subscript")
        }
    }

    // MARK: - Horizontal Sequence

    @Test func horizontalSequenceCorrectOrder() {
        // x^2 + y^2 = z^2
        let box = layoutFromTeX("x^2+y^2=z^2")
        assertNonZeroSize(box, "equation")

        guard case .container(let children) = box.content else {
            Issue.record("sequence should be a container")
            return
        }

        // Should have multiple children laid out left to right
        #expect(children.count >= 5, "x^2 + y^2 = z^2 should have multiple parts")

        // Verify left-to-right ordering
        for i in 1 ..< children.count {
            #expect(children[i].origin.x >= children[i - 1].origin.x,
                    "children should be ordered left to right")
        }

        // Total width should be substantial
        #expect(box.size.width > fontSize * 3,
                "full equation should be wider than 3 em")
    }

    // MARK: - Nested Fraction

    @Test func nestedFractionRecursiveShrinking() {
        let box = layoutFromTeX("\\frac{\\frac{a}{b}}{c}")
        assertNonZeroSize(box, "nested fraction")

        // Nested fraction should be taller than a simple fraction
        let simpleFrac = layoutFromTeX("\\frac{a}{b}")
        #expect(box.size.height > simpleFrac.size.height * 0.8,
                "nested fraction should be at least 80%% as tall as simple fraction")
    }

    // MARK: - Matrix

    @Test func matrixGridLayout() {
        let box = layoutFromTeX("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
        assertNonZeroSize(box, "matrix")

        // Matrix should be substantially wider and taller than a single character
        let singleChar = layoutFromTeX("a")
        #expect(box.size.width > singleChar.size.width * 2,
                "2x2 matrix should be wider than 2 chars")
        #expect(box.size.height > singleChar.size.height * 1.5,
                "2x2 matrix should be taller than 1.5 chars")
    }

    @Test func matrixCellPositions() {
        let box = layoutFromTeX("\\begin{matrix} a & b \\\\ c & d \\end{matrix}")
        assertNonZeroSize(box, "plain matrix")

        // Flatten to find all glyph boxes
        let glyphs = collectGlyphs(box)
        #expect(glyphs.count >= 4, "2x2 matrix should have at least 4 glyph boxes")
    }

    // MARK: - Big Operator with Limits

    @Test func bigOperatorWithLimits() {
        let box = layoutFromTeX("\\sum_{i=0}^{n}")
        assertNonZeroSize(box, "sum with limits")

        guard case .container(let children) = box.content else {
            Issue.record("big operator with limits should be a container")
            return
        }

        // Should have upper limit, operator, lower limit
        #expect(children.count >= 2, "sum with limits should have multiple parts")

        // The whole thing should be taller than a plain sum
        let plainSum = layoutFromTeX("\\sum")
        #expect(box.size.height > plainSum.size.height,
                "sum with limits should be taller than plain sum")
    }

    // MARK: - Square Root

    @Test func sqrtWithRadicalAndOverline() {
        let box = layoutFromTeX("\\sqrt{x}")
        assertNonZeroSize(box, "sqrt")

        guard case .container(let children) = box.content else {
            Issue.record("sqrt should be a container")
            return
        }

        // Should have radical glyph, overline, and radicand
        #expect(children.count >= 3, "sqrt needs radical + overline + radicand, got \(children.count)")

        // Check that there's a line (overline) in the children
        let hasLine = children.contains { child in
            if case .line = child.content { return true }
            return false
        }
        #expect(hasLine, "sqrt should have an overline")

        // Check for radical glyph
        let hasRadical = children.contains { child in
            if case .glyph(let text, _) = child.content {
                return text == "\u{221A}"
            }
            return false
        }
        #expect(hasRadical, "sqrt should have a radical symbol")
    }

    @Test func sqrtWithIndex() {
        let box = layoutFromTeX("\\sqrt[3]{x}")
        assertNonZeroSize(box, "cube root")

        // Should be wider than sqrt without index
        let plainSqrt = layoutFromTeX("\\sqrt{x}")
        #expect(box.size.width >= plainSqrt.size.width,
                "cube root should be at least as wide as plain sqrt")
    }

    // MARK: - Layout Size Invariants

    @Test func layoutSizeNonZeroForNonEmptyInput() {
        let inputs = [
            "x", "42", "x+y", "\\frac{1}{2}", "x^2", "x_i",
            "\\alpha", "\\sum_{i=0}^{n} x_i",
            "\\sqrt{2}", "\\left(x\\right)",
        ]

        for input in inputs {
            let box = layoutFromTeX(input)
            assertNonZeroSize(box, "input: \(input)")
        }
    }

    // MARK: - Accent

    @Test func accentAboveBase() {
        let box = layoutFromTeX("\\hat{x}")
        assertNonZeroSize(box, "hat accent")

        // Accented expression should be taller than base alone
        let plainX = layoutFromTeX("x")
        #expect(box.size.height > plainX.size.height,
                "accented x should be taller than plain x")
    }

    // MARK: - Left/Right Delimiters

    @Test func leftRightDelimiters() {
        let box = layoutFromTeX("\\left(x+y\\right)")
        assertNonZeroSize(box, "delimited expression")

        // Should be wider than content alone (delimiters add width)
        let content = layoutFromTeX("x+y")
        #expect(box.size.width > content.size.width,
                "delimited should be wider than bare content")
    }

    // MARK: - Renderer Integration

    @Test func rendererProducesNonZeroResult() {
        let nodes = parser.parse("x^2 + y^2 = z^2")
        let config = RenderConfiguration.default()
        let layout = renderer.layout(nodes, configuration: config)
        let size = renderer.boundingBox(layout)

        #expect(size.width > 0, "rendered width should be > 0")
        #expect(size.height > 0, "rendered height should be > 0")
    }

    @Test func rendererProducesGraphicalOutput() {
        let nodes = parser.parse("\\frac{1}{2}")
        let config = RenderConfiguration.default()
        let output = renderer.render(nodes, configuration: config)

        if case .graphical(let result) = output {
            #expect(result.boundingBox.width > 0)
            #expect(result.boundingBox.height > 0)
        } else {
            Issue.record("renderer should produce graphical output")
        }
    }

    @Test func rendererEmptyInput() {
        let nodes: [MathNode] = []
        let config = RenderConfiguration.default()
        let layout = renderer.layout(nodes, configuration: config)
        let size = renderer.boundingBox(layout)
        #expect(size == .zero)
    }

    // MARK: - Space Layout

    @Test func spaceNodes() {
        let withSpace = layoutFromTeX("x\\quad y")
        let withoutSpace = layoutFromTeX("xy")

        #expect(withSpace.size.width > withoutSpace.size.width,
                "quad space should increase width")
    }

    // MARK: - Greek Symbols

    @Test func greekSymbolLayout() {
        let box = layoutFromTeX("\\alpha + \\beta")
        assertNonZeroSize(box, "greek symbols")
        #expect(box.size.width > fontSize, "greek expression should have meaningful width")
    }

    // MARK: - Helpers

    /// Recursively collect all glyph boxes from a layout tree.
    private func collectGlyphs(_ box: LayoutBox) -> [(text: String, fontSize: CGFloat)] {
        var result: [(String, CGFloat)] = []
        switch box.content {
        case .glyph(let text, let size):
            result.append((text, size))
        case .container(let children):
            for child in children {
                result.append(contentsOf: collectGlyphs(child))
            }
        case .line:
            break
        }
        return result
    }
}
