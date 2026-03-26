import CoreGraphics
import CoreText
import Foundation

// MARK: - Layout Box Model

/// A positioned box in the layout tree.
///
/// Each `MathNode` becomes one or more `LayoutBox` instances during layout.
/// Positions are relative to the parent container's origin (top-left).
struct LayoutBox: Equatable, Sendable {
    /// Top-left corner relative to parent.
    var origin: CGPoint
    /// Bounding size of this box.
    var size: CGSize
    /// Distance from top edge to the baseline (for vertical alignment).
    var baseline: CGFloat
    /// What this box contains.
    var content: LayoutContent
}

/// Content inside a layout box.
enum LayoutContent: Equatable, Sendable {
    /// A single glyph drawn at the given font size.
    case glyph(String, CGFloat)
    /// A line segment (from, to, thickness) for fraction bars, sqrt overlines.
    case line(CGPoint, CGPoint, CGFloat)
    /// A container holding child boxes positioned relative to this box's origin.
    case container([LayoutBox])
}

// MARK: - Layout Engine

/// Converts `[MathNode]` into a positioned `LayoutBox` tree.
///
/// Uses Core Text font metrics (`CTFont`) for accurate glyph sizing.
/// Layout follows TeX conventions: italic variables, upright numbers/operators,
/// shrunk sub/superscripts, centered fractions, etc.
///
/// Two-phase usage:
/// ```
/// let engine = MathLayoutEngine()
/// let box = engine.layout(nodes, fontSize: 16)
/// // box.size gives the bounding rect; pass to renderer for drawing
/// ```
struct MathLayoutEngine: Sendable {

    // MARK: - Constants

    /// Factor applied to font size for sub/superscripts and fraction children.
    private static let scriptSizeFactor: CGFloat = 0.7
    /// Minimum font size to prevent infinite shrinking in deep nesting.
    private static let minimumFontSize: CGFloat = 6.0
    /// Horizontal padding around relation operators (=, <, >, etc.).
    private static let relationSpacing: CGFloat = 0.25 // em
    /// Horizontal padding around binary operators (+, -, etc.).
    private static let binaryOpSpacing: CGFloat = 0.2 // em
    /// Padding above/below fraction bar.
    private static let fractionGap: CGFloat = 0.15 // em
    /// Fraction bar thickness as fraction of font size.
    private static let fractionBarThickness: CGFloat = 0.04
    /// Superscript raise as fraction of font size.
    private static let superscriptRaise: CGFloat = 0.4
    /// Subscript drop as fraction of font size.
    private static let subscriptDrop: CGFloat = 0.2
    /// Spacing between matrix columns in em.
    private static let matrixColumnSpacing: CGFloat = 1.0
    /// Spacing between matrix rows in em.
    private static let matrixRowSpacing: CGFloat = 0.5
    /// Radical symbol horizontal padding.
    private static let radicalPadding: CGFloat = 0.15 // em
    /// Overline thickness as fraction of font size.
    private static let overlineThickness: CGFloat = 0.04
    /// Gap between accent and base as fraction of font size.
    private static let accentGap: CGFloat = 0.1
    /// Big operator scale factor relative to base font size.
    private static let bigOperatorScale: CGFloat = 1.5
    /// Delimiter padding.
    private static let delimiterPadding: CGFloat = 0.1 // em

    // MARK: - Font Cache

    /// Per-layout font cache to avoid repeated CTFont creation.
    /// Not stored across layout calls — created fresh each time.
    private final class FontCache: @unchecked Sendable {
        private var italicFonts: [CGFloat: CTFont] = [:]
        private var romanFonts: [CGFloat: CTFont] = [:]

        func italic(size: CGFloat) -> CTFont {
            if let cached = italicFonts[size] { return cached }
            let font = MathLayoutEngine.createItalicFont(size: size)
            italicFonts[size] = font
            return font
        }

        func roman(size: CGFloat) -> CTFont {
            if let cached = romanFonts[size] { return cached }
            let font = MathLayoutEngine.createRomanFont(size: size)
            romanFonts[size] = font
            return font
        }
    }

    // MARK: - Public API

    /// Layout a list of math nodes at the given font size.
    ///
    /// Returns a single container `LayoutBox` wrapping all nodes laid out
    /// left to right. Returns a zero-size box for empty input.
    func layout(_ nodes: [MathNode], fontSize: CGFloat) -> LayoutBox {
        guard !nodes.isEmpty else {
            return LayoutBox(
                origin: .zero,
                size: .zero,
                baseline: 0,
                content: .container([])
            )
        }
        let cache = FontCache()
        let effectiveSize = max(fontSize, Self.minimumFontSize)
        let children = layoutSequence(nodes, fontSize: effectiveSize, cache: cache)
        return wrapInContainer(children)
    }

    // MARK: - Sequence Layout

    /// Layout nodes left-to-right, returning positioned child boxes.
    private func layoutSequence(
        _ nodes: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> [LayoutBox] {
        var boxes: [LayoutBox] = []
        var cursor: CGFloat = 0

        for node in nodes {
            let box = layoutNode(node, fontSize: fontSize, cache: cache)
            var positioned = box
            positioned.origin.x = cursor
            boxes.append(positioned)
            cursor += box.size.width
        }

        return boxes
    }

    // MARK: - Node Dispatch

    /// Layout a single math node, returning a box at origin (0,0).
    private func layoutNode(
        _ node: MathNode,
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        switch node {
        case .variable(let name):
            return layoutGlyph(name, fontSize: fontSize, italic: true, cache: cache)

        case .number(let digits):
            return layoutGlyph(digits, fontSize: fontSize, italic: false, cache: cache)

        case .operator(let op):
            return layoutOperator(op, fontSize: fontSize, cache: cache)

        case .symbol(let sym):
            return layoutSymbol(sym, fontSize: fontSize, cache: cache)

        case .fraction(let num, let den):
            return layoutFraction(num, den, fontSize: fontSize, cache: cache)

        case .superscript(let base, let exp):
            return layoutSuperscript(base, exp, fontSize: fontSize, cache: cache)

        case .subscript(let base, let idx):
            return layoutSubscript(base, idx, fontSize: fontSize, cache: cache)

        case .subSuperscript(let base, let sub, let sup):
            return layoutSubSuperscript(base, sub, sup, fontSize: fontSize, cache: cache)

        case .sqrt(let index, let radicand):
            return layoutSqrt(index: index, radicand: radicand, fontSize: fontSize, cache: cache)

        case .leftRight(let left, let right, let body):
            return layoutLeftRight(left: left, right: right, body: body, fontSize: fontSize, cache: cache)

        case .matrix(let rows, let style):
            return layoutMatrix(rows: rows, style: style, fontSize: fontSize, cache: cache)

        case .bigOperator(let kind, let limits):
            return layoutBigOperator(kind, limits: limits, fontSize: fontSize, cache: cache)

        case .accent(let kind, let base):
            return layoutAccent(kind, base: base, fontSize: fontSize, cache: cache)

        case .group(let children):
            let childBoxes = layoutSequence(children, fontSize: fontSize, cache: cache)
            return wrapInContainer(childBoxes)

        case .text(let content):
            return layoutGlyph(content, fontSize: fontSize, italic: false, cache: cache)

        case .space(let sp):
            return layoutSpace(sp, fontSize: fontSize)

        case .font(_, let body):
            // Font style hint — layout body normally (visual distinction handled by renderer)
            let childBoxes = layoutSequence(body, fontSize: fontSize, cache: cache)
            return wrapInContainer(childBoxes)

        case .environment(_, let rows):
            // Layout as matrix-like grid
            return layoutMatrix(rows: rows, style: .plain, fontSize: fontSize, cache: cache)
        }
    }

    // MARK: - Glyph Layout

    private func layoutGlyph(
        _ text: String,
        fontSize: CGFloat,
        italic: Bool,
        cache: FontCache
    ) -> LayoutBox {
        let font = italic ? cache.italic(size: fontSize) : cache.roman(size: fontSize)
        let (width, ascent, descent) = measureText(text, font: font)
        let height = ascent + descent
        return LayoutBox(
            origin: .zero,
            size: CGSize(width: width, height: height),
            baseline: ascent,
            content: .glyph(text, fontSize)
        )
    }

    // MARK: - Operator Layout

    private func layoutOperator(
        _ op: MathOperator,
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let displayChar = Self.operatorDisplayString(op)
        let font = cache.roman(size: fontSize)
        let (glyphWidth, ascent, descent) = measureText(displayChar, font: font)
        let height = ascent + descent
        let em = fontSize

        let spacing: CGFloat
        if Self.isRelationOperator(op) {
            spacing = em * Self.relationSpacing
        } else if Self.isBinaryOperator(op) {
            spacing = em * Self.binaryOpSpacing
        } else {
            spacing = 0
        }

        let totalWidth = glyphWidth + spacing * 2

        // The glyph sits centered in the total width
        let glyphBox = LayoutBox(
            origin: CGPoint(x: spacing, y: 0),
            size: CGSize(width: glyphWidth, height: height),
            baseline: ascent,
            content: .glyph(displayChar, fontSize)
        )

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: totalWidth, height: height),
            baseline: ascent,
            content: .container([glyphBox])
        )
    }

    // MARK: - Symbol Layout

    private func layoutSymbol(
        _ sym: MathSymbol,
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let displayChar = Self.symbolDisplayString(sym)
        return layoutGlyph(displayChar, fontSize: fontSize, italic: true, cache: cache)
    }

    // MARK: - Fraction Layout

    private func layoutFraction(
        _ numerator: [MathNode],
        _ denominator: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let childSize = max(fontSize * Self.scriptSizeFactor, Self.minimumFontSize)
        let em = fontSize

        let numBoxes = layoutSequence(numerator, fontSize: childSize, cache: cache)
        let numContainer = wrapInContainer(numBoxes)

        let denBoxes = layoutSequence(denominator, fontSize: childSize, cache: cache)
        let denContainer = wrapInContainer(denBoxes)

        let barThickness = em * Self.fractionBarThickness
        let gap = em * Self.fractionGap

        let maxWidth = max(numContainer.size.width, denContainer.size.width)
        let padding: CGFloat = em * 0.1

        // Center numerator
        var num = numContainer
        num.origin = CGPoint(
            x: (maxWidth + padding * 2 - num.size.width) / 2,
            y: 0
        )

        // Bar position
        let barY = num.size.height + gap
        let barBox = LayoutBox(
            origin: CGPoint(x: padding, y: barY),
            size: CGSize(width: maxWidth, height: barThickness),
            baseline: barThickness / 2,
            content: .line(
                CGPoint(x: 0, y: barThickness / 2),
                CGPoint(x: maxWidth, y: barThickness / 2),
                barThickness
            )
        )

        // Center denominator
        var den = denContainer
        den.origin = CGPoint(
            x: (maxWidth + padding * 2 - den.size.width) / 2,
            y: barY + barThickness + gap
        )

        let totalHeight = den.origin.y + den.size.height
        let totalWidth = maxWidth + padding * 2

        // Baseline is at the fraction bar
        return LayoutBox(
            origin: .zero,
            size: CGSize(width: totalWidth, height: totalHeight),
            baseline: barY + barThickness / 2,
            content: .container([num, barBox, den])
        )
    }

    // MARK: - Superscript Layout

    private func layoutSuperscript(
        _ base: [MathNode],
        _ exponent: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let baseBoxes = layoutSequence(base, fontSize: fontSize, cache: cache)
        let baseContainer = wrapInContainer(baseBoxes)

        let scriptSize = max(fontSize * Self.scriptSizeFactor, Self.minimumFontSize)
        let supBoxes = layoutSequence(exponent, fontSize: scriptSize, cache: cache)
        let supContainer = wrapInContainer(supBoxes)

        let raise = fontSize * Self.superscriptRaise

        // Superscript is raised so its bottom aligns above the base midline
        let supY = max(baseContainer.baseline - raise - supContainer.size.height, 0)

        var basePlaced = baseContainer
        basePlaced.origin = CGPoint(x: 0, y: max(-supY, 0))

        var supPlaced = supContainer
        supPlaced.origin = CGPoint(x: baseContainer.size.width, y: supY)

        let totalHeight = max(
            basePlaced.origin.y + basePlaced.size.height,
            supPlaced.origin.y + supPlaced.size.height
        )
        let totalWidth = baseContainer.size.width + supContainer.size.width

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: totalWidth, height: totalHeight),
            baseline: basePlaced.origin.y + baseContainer.baseline,
            content: .container([basePlaced, supPlaced])
        )
    }

    // MARK: - Subscript Layout

    private func layoutSubscript(
        _ base: [MathNode],
        _ index: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let baseBoxes = layoutSequence(base, fontSize: fontSize, cache: cache)
        let baseContainer = wrapInContainer(baseBoxes)

        let scriptSize = max(fontSize * Self.scriptSizeFactor, Self.minimumFontSize)
        let subBoxes = layoutSequence(index, fontSize: scriptSize, cache: cache)
        let subContainer = wrapInContainer(subBoxes)

        let drop = fontSize * Self.subscriptDrop

        // Subscript drops below the base baseline
        let subY = baseContainer.baseline + drop

        var basePlaced = baseContainer
        basePlaced.origin = .zero

        var subPlaced = subContainer
        subPlaced.origin = CGPoint(x: baseContainer.size.width, y: subY)

        let totalHeight = max(
            basePlaced.size.height,
            subPlaced.origin.y + subPlaced.size.height
        )
        let totalWidth = baseContainer.size.width + subContainer.size.width

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: totalWidth, height: totalHeight),
            baseline: baseContainer.baseline,
            content: .container([basePlaced, subPlaced])
        )
    }

    // MARK: - Combined Sub + Superscript

    private func layoutSubSuperscript(
        _ base: [MathNode],
        _ sub: [MathNode],
        _ sup: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let baseBoxes = layoutSequence(base, fontSize: fontSize, cache: cache)
        let baseContainer = wrapInContainer(baseBoxes)

        let scriptSize = max(fontSize * Self.scriptSizeFactor, Self.minimumFontSize)
        let supBoxes = layoutSequence(sup, fontSize: scriptSize, cache: cache)
        let supContainer = wrapInContainer(supBoxes)
        let subBoxes = layoutSequence(sub, fontSize: scriptSize, cache: cache)
        let subContainer = wrapInContainer(subBoxes)

        let raise = fontSize * Self.superscriptRaise
        let drop = fontSize * Self.subscriptDrop

        let supY = max(baseContainer.baseline - raise - supContainer.size.height, 0)
        let subY = baseContainer.baseline + drop

        // Adjust base position if superscript extends above
        let baseOffsetY = max(-supY, 0)

        var basePlaced = baseContainer
        basePlaced.origin = CGPoint(x: 0, y: baseOffsetY)

        let scriptX = baseContainer.size.width

        var supPlaced = supContainer
        supPlaced.origin = CGPoint(x: scriptX, y: supY + baseOffsetY - baseOffsetY)
        // Recalculate: supY was computed relative to base top=0
        supPlaced.origin = CGPoint(x: scriptX, y: supY)

        var subPlaced = subContainer
        subPlaced.origin = CGPoint(x: scriptX, y: subY + baseOffsetY)

        let totalHeight = max(
            basePlaced.origin.y + basePlaced.size.height,
            max(supPlaced.origin.y + supPlaced.size.height,
                subPlaced.origin.y + subPlaced.size.height)
        )
        let scriptWidth = max(supContainer.size.width, subContainer.size.width)
        let totalWidth = baseContainer.size.width + scriptWidth

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: totalWidth, height: totalHeight),
            baseline: basePlaced.origin.y + baseContainer.baseline,
            content: .container([basePlaced, supPlaced, subPlaced])
        )
    }

    // MARK: - Square Root

    private func layoutSqrt(
        index: [MathNode]?,
        radicand: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let em = fontSize
        let radBoxes = layoutSequence(radicand, fontSize: fontSize, cache: cache)
        let radContainer = wrapInContainer(radBoxes)

        let radicalPad = em * Self.radicalPadding
        let overlineThick = em * Self.overlineThickness
        let overlineGap = em * 0.1

        // Radical symbol
        let radicalChar = "\u{221A}" // √
        let radicalFont = cache.roman(size: fontSize * 1.2)
        let (radicalWidth, radicalAsc, radicalDesc) = measureText(radicalChar, font: radicalFont)
        let radicalHeight = radicalAsc + radicalDesc
        _ = radicalHeight // Suppress unused warning; height is for reference

        // Scale radical to match radicand height
        let contentHeight = radContainer.size.height + overlineThick + overlineGap
        let radicalGlyphBox = LayoutBox(
            origin: CGPoint(x: 0, y: 0),
            size: CGSize(width: radicalWidth, height: contentHeight),
            baseline: radicalAsc,
            content: .glyph(radicalChar, fontSize * 1.2)
        )

        // Overline bar
        let overlineStartX = radicalWidth
        let overlineY = overlineThick / 2
        let overlineBox = LayoutBox(
            origin: CGPoint(x: overlineStartX, y: 0),
            size: CGSize(width: radContainer.size.width + radicalPad, height: overlineThick),
            baseline: overlineThick / 2,
            content: .line(
                CGPoint(x: 0, y: overlineY),
                CGPoint(x: radContainer.size.width + radicalPad, y: overlineY),
                overlineThick
            )
        )

        // Radicand content
        var radPlaced = radContainer
        radPlaced.origin = CGPoint(
            x: radicalWidth + radicalPad / 2,
            y: overlineThick + overlineGap
        )

        var children: [LayoutBox] = [radicalGlyphBox, overlineBox, radPlaced]

        // Optional index
        var indexWidth: CGFloat = 0
        if let indexNodes = index, !indexNodes.isEmpty {
            let indexSize = max(fontSize * Self.scriptSizeFactor * Self.scriptSizeFactor, Self.minimumFontSize)
            let indexBoxes = layoutSequence(indexNodes, fontSize: indexSize, cache: cache)
            let indexContainer = wrapInContainer(indexBoxes)

            var indexPlaced = indexContainer
            indexPlaced.origin = CGPoint(x: 0, y: 0)
            indexWidth = indexContainer.size.width

            // Shift everything right to make room for index
            for i in children.indices {
                children[i].origin.x += indexWidth
            }
            children.insert(indexPlaced, at: 0)
        }

        let totalWidth = indexWidth + radicalWidth + radContainer.size.width + radicalPad
        let totalHeight = contentHeight

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: totalWidth, height: totalHeight),
            baseline: radPlaced.origin.y + radContainer.baseline,
            content: .container(children)
        )
    }

    // MARK: - Left/Right Delimiters

    private func layoutLeftRight(
        left: Delimiter,
        right: Delimiter,
        body: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let bodyBoxes = layoutSequence(body, fontSize: fontSize, cache: cache)
        let bodyContainer = wrapInContainer(bodyBoxes)

        let em = fontSize
        let pad = em * Self.delimiterPadding
        var children: [LayoutBox] = []
        var cursor: CGFloat = 0

        // Left delimiter
        if left != .none {
            let leftStr = Self.delimiterDisplayString(left)
            let delBox = layoutGlyph(leftStr, fontSize: fontSize, italic: false, cache: cache)
            var placed = delBox
            placed.origin = CGPoint(x: cursor, y: 0)
            // Scale to body height
            placed.size.height = bodyContainer.size.height
            placed.baseline = bodyContainer.baseline
            children.append(placed)
            cursor += delBox.size.width + pad
        }

        // Body
        var bodyPlaced = bodyContainer
        bodyPlaced.origin = CGPoint(x: cursor, y: 0)
        children.append(bodyPlaced)
        cursor += bodyContainer.size.width

        // Right delimiter
        if right != .none {
            cursor += pad
            let rightStr = Self.delimiterDisplayString(right)
            let delBox = layoutGlyph(rightStr, fontSize: fontSize, italic: false, cache: cache)
            var placed = delBox
            placed.origin = CGPoint(x: cursor, y: 0)
            placed.size.height = bodyContainer.size.height
            placed.baseline = bodyContainer.baseline
            children.append(placed)
            cursor += delBox.size.width
        }

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: cursor, height: bodyContainer.size.height),
            baseline: bodyContainer.baseline,
            content: .container(children)
        )
    }

    // MARK: - Matrix Layout

    private func layoutMatrix(
        rows: [[[MathNode]]],
        style: MatrixStyle,
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        guard !rows.isEmpty else {
            return LayoutBox(origin: .zero, size: .zero, baseline: 0, content: .container([]))
        }

        let em = fontSize
        let colSpace = em * Self.matrixColumnSpacing
        let rowSpace = em * Self.matrixRowSpacing

        // Layout all cells
        let numCols = rows.map(\.count).max() ?? 0
        var cellBoxes: [[LayoutBox]] = []
        for row in rows {
            var rowBoxes: [LayoutBox] = []
            for cell in row {
                let cellChildren = layoutSequence(cell, fontSize: fontSize, cache: cache)
                rowBoxes.append(wrapInContainer(cellChildren))
            }
            // Pad with empty boxes if row has fewer columns
            while rowBoxes.count < numCols {
                rowBoxes.append(LayoutBox(origin: .zero, size: .zero, baseline: 0, content: .container([])))
            }
            cellBoxes.append(rowBoxes)
        }

        // Compute column widths and row heights
        var colWidths = [CGFloat](repeating: 0, count: numCols)
        var rowHeights = [CGFloat](repeating: 0, count: rows.count)
        var rowBaselines = [CGFloat](repeating: 0, count: rows.count)

        for (r, rowBoxArr) in cellBoxes.enumerated() {
            for (c, cell) in rowBoxArr.enumerated() {
                colWidths[c] = max(colWidths[c], cell.size.width)
                rowHeights[r] = max(rowHeights[r], cell.size.height)
                rowBaselines[r] = max(rowBaselines[r], cell.baseline)
            }
        }

        // Position cells
        var positioned: [LayoutBox] = []
        var y: CGFloat = 0
        for (r, rowBoxArr) in cellBoxes.enumerated() {
            var x: CGFloat = 0
            for (c, cell) in rowBoxArr.enumerated() {
                var placed = cell
                // Center horizontally in column
                placed.origin = CGPoint(
                    x: x + (colWidths[c] - cell.size.width) / 2,
                    y: y + (rowBaselines[r] - cell.baseline)
                )
                positioned.append(placed)
                x += colWidths[c]
                if c < numCols - 1 {
                    x += colSpace
                }
            }
            y += rowHeights[r]
            if r < rows.count - 1 {
                y += rowSpace
            }
        }

        let totalWidth = colWidths.reduce(0, +) + CGFloat(max(numCols - 1, 0)) * colSpace
        let totalHeight = y

        // Wrap with delimiter brackets based on matrix style
        let innerBox = LayoutBox(
            origin: .zero,
            size: CGSize(width: totalWidth, height: totalHeight),
            baseline: totalHeight / 2,
            content: .container(positioned)
        )

        let (leftDel, rightDel) = Self.matrixDelimiters(style)
        if leftDel != .none || rightDel != .none {
            return wrapWithDelimiters(
                innerBox,
                left: leftDel,
                right: rightDel,
                fontSize: fontSize,
                cache: cache
            )
        }

        return innerBox
    }

    /// Wrap a pre-laid-out box with delimiter glyphs.
    private func wrapWithDelimiters(
        _ innerBox: LayoutBox,
        left: Delimiter,
        right: Delimiter,
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let em = fontSize
        let pad = em * Self.delimiterPadding
        var children: [LayoutBox] = []
        var cursor: CGFloat = 0

        if left != .none {
            let leftStr = Self.delimiterDisplayString(left)
            let delBox = layoutGlyph(leftStr, fontSize: fontSize, italic: false, cache: cache)
            var placed = delBox
            placed.origin = CGPoint(x: cursor, y: 0)
            placed.size.height = innerBox.size.height
            placed.baseline = innerBox.baseline
            children.append(placed)
            cursor += delBox.size.width + pad
        }

        var bodyPlaced = innerBox
        bodyPlaced.origin = CGPoint(x: cursor, y: 0)
        children.append(bodyPlaced)
        cursor += innerBox.size.width

        if right != .none {
            cursor += pad
            let rightStr = Self.delimiterDisplayString(right)
            let delBox = layoutGlyph(rightStr, fontSize: fontSize, italic: false, cache: cache)
            var placed = delBox
            placed.origin = CGPoint(x: cursor, y: 0)
            placed.size.height = innerBox.size.height
            placed.baseline = innerBox.baseline
            children.append(placed)
            cursor += delBox.size.width
        }

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: cursor, height: innerBox.size.height),
            baseline: innerBox.baseline,
            content: .container(children)
        )
    }

    // MARK: - Big Operator Layout

    private func layoutBigOperator(
        _ kind: BigOpKind,
        limits: MathLimits?,
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let isTextOp = Self.isTextOperator(kind)
        let displayStr = Self.bigOperatorDisplayString(kind)

        let opFontSize: CGFloat
        let opItalic: Bool
        if isTextOp {
            opFontSize = fontSize
            opItalic = false
        } else {
            opFontSize = fontSize * Self.bigOperatorScale
            opItalic = false
        }

        let opBox = layoutGlyph(displayStr, fontSize: opFontSize, italic: opItalic, cache: cache)

        guard let limits, (limits.lower != nil || limits.upper != nil) else {
            return opBox
        }

        let limitSize = max(fontSize * Self.scriptSizeFactor, Self.minimumFontSize)
        var children: [LayoutBox] = []
        var totalHeight: CGFloat = 0
        let gap = fontSize * 0.1

        // Upper limit (above operator)
        var upperContainer: LayoutBox?
        if let upper = limits.upper, !upper.isEmpty {
            let upperBoxes = layoutSequence(upper, fontSize: limitSize, cache: cache)
            let container = wrapInContainer(upperBoxes)
            upperContainer = container
            totalHeight += container.size.height + gap
        }

        // Operator
        let opY = totalHeight
        totalHeight += opBox.size.height

        // Lower limit (below operator)
        var lowerContainer: LayoutBox?
        if let lower = limits.lower, !lower.isEmpty {
            totalHeight += gap
            let lowerBoxes = layoutSequence(lower, fontSize: limitSize, cache: cache)
            let container = wrapInContainer(lowerBoxes)
            lowerContainer = container
            totalHeight += container.size.height
        }

        // Center everything on the widest element
        let maxWidth = max(
            opBox.size.width,
            max(upperContainer?.size.width ?? 0, lowerContainer?.size.width ?? 0)
        )

        if let upper = upperContainer {
            var placed = upper
            placed.origin = CGPoint(x: (maxWidth - upper.size.width) / 2, y: 0)
            children.append(placed)
        }

        var opPlaced = opBox
        opPlaced.origin = CGPoint(x: (maxWidth - opBox.size.width) / 2, y: opY)
        children.append(opPlaced)

        if let lower = lowerContainer {
            var placed = lower
            placed.origin = CGPoint(
                x: (maxWidth - lower.size.width) / 2,
                y: opY + opBox.size.height + gap
            )
            children.append(placed)
        }

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: maxWidth, height: totalHeight),
            baseline: opY + opBox.baseline,
            content: .container(children)
        )
    }

    // MARK: - Accent Layout

    private func layoutAccent(
        _ kind: MathAccentKind,
        base: [MathNode],
        fontSize: CGFloat,
        cache: FontCache
    ) -> LayoutBox {
        let baseBoxes = layoutSequence(base, fontSize: fontSize, cache: cache)
        let baseContainer = wrapInContainer(baseBoxes)

        let accentChar = Self.accentDisplayString(kind)
        let accentSize = fontSize * 0.8
        let accentBox = layoutGlyph(accentChar, fontSize: accentSize, italic: false, cache: cache)

        let gap = fontSize * Self.accentGap
        let isUnder = (kind == .underline || kind == .underbrace)

        var children: [LayoutBox] = []
        let maxWidth = max(baseContainer.size.width, accentBox.size.width)

        if isUnder {
            var basePlaced = baseContainer
            basePlaced.origin = CGPoint(x: (maxWidth - baseContainer.size.width) / 2, y: 0)
            children.append(basePlaced)

            var accentPlaced = accentBox
            accentPlaced.origin = CGPoint(
                x: (maxWidth - accentBox.size.width) / 2,
                y: baseContainer.size.height + gap
            )
            children.append(accentPlaced)

            let totalHeight = baseContainer.size.height + gap + accentBox.size.height
            return LayoutBox(
                origin: .zero,
                size: CGSize(width: maxWidth, height: totalHeight),
                baseline: baseContainer.baseline,
                content: .container(children)
            )
        } else {
            // Accent above base
            var accentPlaced = accentBox
            accentPlaced.origin = CGPoint(
                x: (maxWidth - accentBox.size.width) / 2,
                y: 0
            )
            children.append(accentPlaced)

            var basePlaced = baseContainer
            basePlaced.origin = CGPoint(
                x: (maxWidth - baseContainer.size.width) / 2,
                y: accentBox.size.height + gap
            )
            children.append(basePlaced)

            let totalHeight = accentBox.size.height + gap + baseContainer.size.height
            return LayoutBox(
                origin: .zero,
                size: CGSize(width: maxWidth, height: totalHeight),
                baseline: accentBox.size.height + gap + baseContainer.baseline,
                content: .container(children)
            )
        }
    }

    // MARK: - Space Layout

    private func layoutSpace(_ space: MathSpace, fontSize: CGFloat) -> LayoutBox {
        let em = fontSize
        let width: CGFloat
        switch space {
        case .thinSpace: width = em * 3.0 / 18.0
        case .mediumSpace: width = em * 4.0 / 18.0
        case .thickSpace: width = em * 5.0 / 18.0
        case .quad: width = em
        case .qquad: width = em * 2
        case .negThin: width = em * -3.0 / 18.0
        case .backslashSpace: width = em * 4.0 / 18.0
        }
        return LayoutBox(
            origin: .zero,
            size: CGSize(width: max(width, 0), height: fontSize),
            baseline: fontSize * 0.7,
            content: .container([])
        )
    }

    // MARK: - Container Wrapping

    /// Wrap a list of positioned child boxes into a single container box.
    /// Computes bounding size and unifies baselines.
    /// If there's only one child, returns it directly to avoid unnecessary nesting.
    private func wrapInContainer(_ children: [LayoutBox]) -> LayoutBox {
        guard !children.isEmpty else {
            return LayoutBox(origin: .zero, size: .zero, baseline: 0, content: .container([]))
        }

        // Single child: return directly, no wrapper needed
        if children.count == 1 {
            var box = children[0]
            box.origin = .zero
            return box
        }

        // First pass: find the maximum baseline among children
        // so we can align them all on a common baseline.
        let maxBaseline = children.map(\.baseline).max() ?? 0

        // Second pass: shift children so baselines align, compute bounds
        var aligned: [LayoutBox] = []
        var maxWidth: CGFloat = 0
        var maxBottom: CGFloat = 0

        for child in children {
            var shifted = child
            let baselineShift = maxBaseline - child.baseline
            shifted.origin.y += baselineShift
            aligned.append(shifted)

            let right = shifted.origin.x + shifted.size.width
            let bottom = shifted.origin.y + shifted.size.height
            maxWidth = max(maxWidth, right)
            maxBottom = max(maxBottom, bottom)
        }

        return LayoutBox(
            origin: .zero,
            size: CGSize(width: maxWidth, height: maxBottom),
            baseline: maxBaseline,
            content: .container(aligned)
        )
    }

    // MARK: - Core Text Measurement

    private func measureText(_ text: String, font: CTFont) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        let attrString = NSAttributedString(
            string: text,
            attributes: [.font: font as Any]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)

        return (CGFloat(width), ascent, descent)
    }

    // MARK: - Font Creation

    private static func createItalicFont(size: CGFloat) -> CTFont {
        // Try to get italic variant via symbolic traits
        let baseFont = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, size, nil)
        if let italicFont = CTFontCreateCopyWithSymbolicTraits(
            baseFont, size, nil, .traitItalic, .traitItalic
        ) {
            return italicFont
        }
        // Fallback: use the italic PostScript name directly
        return CTFontCreateWithName("TimesNewRomanPS-ItalicMT" as CFString, size, nil)
    }

    private static func createRomanFont(size: CGFloat) -> CTFont {
        // Try Times New Roman, fall back to system serif
        let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, size, nil)
        return font
    }

    // MARK: - Display String Tables

    static func operatorDisplayString(_ op: MathOperator) -> String {
        switch op {
        case .plus: return "+"
        case .minus: return "\u{2212}" // minus sign
        case .times: return "\u{00D7}" // ×
        case .div: return "\u{00F7}"   // ÷
        case .cdot: return "\u{22C5}"  // ⋅
        case .pm: return "\u{00B1}"    // ±
        case .mp: return "\u{2213}"    // ∓
        case .star: return "*"
        case .equal: return "="
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .leq: return "\u{2264}"   // ≤
        case .geq: return "\u{2265}"   // ≥
        case .neq: return "\u{2260}"   // ≠
        case .approx: return "\u{2248}" // ≈
        case .equiv: return "\u{2261}" // ≡
        case .sim: return "\u{223C}"   // ∼
        case .in: return "\u{2208}"    // ∈
        case .subset: return "\u{2282}" // ⊂
        case .supset: return "\u{2283}" // ⊃
        case .subseteq: return "\u{2286}" // ⊆
        case .supseteq: return "\u{2287}" // ⊇
        case .cup: return "\u{222A}"   // ∪
        case .cap: return "\u{2229}"   // ∩
        case .to: return "\u{2192}"    // →
        case .rightarrow: return "\u{2192}"
        case .leftarrow: return "\u{2190}" // ←
        case .mapsto: return "\u{21A6}" // ↦
        case .colon: return ":"
        case .comma: return ","
        case .semicolon: return ";"
        case .bang: return "!"
        }
    }

    static func isRelationOperator(_ op: MathOperator) -> Bool {
        switch op {
        case .equal, .lessThan, .greaterThan, .leq, .geq, .neq,
             .approx, .equiv, .sim, .in, .subset, .supset,
             .subseteq, .supseteq, .to, .rightarrow, .leftarrow, .mapsto:
            return true
        default:
            return false
        }
    }

    static func isBinaryOperator(_ op: MathOperator) -> Bool {
        switch op {
        case .plus, .minus, .times, .div, .cdot, .pm, .mp, .star, .cup, .cap:
            return true
        default:
            return false
        }
    }

    static func symbolDisplayString(_ sym: MathSymbol) -> String {
        switch sym {
        case .alpha: return "\u{03B1}"
        case .beta: return "\u{03B2}"
        case .gamma: return "\u{03B3}"
        case .delta: return "\u{03B4}"
        case .epsilon: return "\u{03B5}"
        case .varepsilon: return "\u{03B5}"
        case .zeta: return "\u{03B6}"
        case .eta: return "\u{03B7}"
        case .theta: return "\u{03B8}"
        case .vartheta: return "\u{03D1}"
        case .iota: return "\u{03B9}"
        case .kappa: return "\u{03BA}"
        case .lambda: return "\u{03BB}"
        case .mu: return "\u{03BC}"
        case .nu: return "\u{03BD}"
        case .xi: return "\u{03BE}"
        case .pi: return "\u{03C0}"
        case .rho: return "\u{03C1}"
        case .varrho: return "\u{03F1}"
        case .sigma: return "\u{03C3}"
        case .varsigma: return "\u{03C2}"
        case .tau: return "\u{03C4}"
        case .upsilon: return "\u{03C5}"
        case .phi: return "\u{03C6}"
        case .varphi: return "\u{03D5}"
        case .chi: return "\u{03C7}"
        case .psi: return "\u{03C8}"
        case .omega: return "\u{03C9}"
        case .capitalGamma: return "\u{0393}"
        case .capitalDelta: return "\u{0394}"
        case .capitalTheta: return "\u{0398}"
        case .capitalLambda: return "\u{039B}"
        case .capitalXi: return "\u{039E}"
        case .capitalPi: return "\u{03A0}"
        case .capitalSigma: return "\u{03A3}"
        case .capitalUpsilon: return "\u{03A5}"
        case .capitalPhi: return "\u{03A6}"
        case .capitalPsi: return "\u{03A8}"
        case .capitalOmega: return "\u{03A9}"
        case .infty: return "\u{221E}"
        case .partial: return "\u{2202}"
        case .nabla: return "\u{2207}"
        case .forall: return "\u{2200}"
        case .exists: return "\u{2203}"
        case .neg: return "\u{00AC}"
        case .ell: return "\u{2113}"
        case .hbar: return "\u{210F}"
        case .emptyset: return "\u{2205}"
        case .cdots: return "\u{22EF}"
        case .ldots: return "\u{2026}"
        case .vdots: return "\u{22EE}"
        case .ddots: return "\u{22F1}"
        case .prime: return "\u{2032}"
        }
    }

    static func bigOperatorDisplayString(_ kind: BigOpKind) -> String {
        switch kind {
        case .sum: return "\u{2211}"    // ∑
        case .prod: return "\u{220F}"   // ∏
        case .coprod: return "\u{2210}" // ∐
        case .int: return "\u{222B}"    // ∫
        case .iint: return "\u{222C}"   // ∬
        case .iiint: return "\u{222D}"  // ∭
        case .oint: return "\u{222E}"   // ∮
        case .bigcup: return "\u{22C3}" // ⋃
        case .bigcap: return "\u{22C2}" // ⋂
        case .bigoplus: return "\u{2A01}" // ⨁
        case .bigotimes: return "\u{2A02}" // ⨂
        case .lim: return "lim"
        case .sup: return "sup"
        case .inf: return "inf"
        case .min: return "min"
        case .max: return "max"
        case .det: return "det"
        case .log: return "log"
        case .ln: return "ln"
        case .sin: return "sin"
        case .cos: return "cos"
        case .tan: return "tan"
        case .exp: return "exp"
        }
    }

    static func isTextOperator(_ kind: BigOpKind) -> Bool {
        switch kind {
        case .lim, .sup, .inf, .min, .max, .det, .log, .ln,
             .sin, .cos, .tan, .exp:
            return true
        default:
            return false
        }
    }

    static func accentDisplayString(_ kind: MathAccentKind) -> String {
        switch kind {
        case .hat: return "\u{0302}"      // combining circumflex
        case .bar: return "\u{0304}"      // combining macron
        case .vec: return "\u{20D7}"      // combining right arrow above
        case .dot: return "\u{0307}"      // combining dot above
        case .ddot: return "\u{0308}"     // combining diaeresis
        case .tilde: return "\u{0303}"    // combining tilde
        case .overline: return "\u{203E}" // overline
        case .underline: return "_"
        case .widehat: return "\u{0302}"
        case .widetilde: return "\u{0303}"
        case .overbrace: return "\u{23DE}" // top curly bracket
        case .underbrace: return "\u{23DF}" // bottom curly bracket
        }
    }

    static func delimiterDisplayString(_ del: Delimiter) -> String {
        switch del {
        case .paren: return "("
        case .closeParen: return ")"
        case .bracket: return "["
        case .closeBracket: return "]"
        case .brace: return "{"
        case .closeBrace: return "}"
        case .pipe: return "|"
        case .doublePipe: return "\u{2016}" // ‖
        case .angle: return "\u{27E8}"      // ⟨
        case .closeAngle: return "\u{27E9}" // ⟩
        case .none: return ""
        }
    }

    static func matrixDelimiters(_ style: MatrixStyle) -> (Delimiter, Delimiter) {
        switch style {
        case .plain, .small: return (.none, .none)
        case .parenthesized: return (.paren, .closeParen)
        case .bracketed: return (.bracket, .closeBracket)
        case .braced: return (.brace, .closeBrace)
        case .pipe: return (.pipe, .pipe)
        case .doublePipe: return (.doublePipe, .doublePipe)
        }
    }
}
