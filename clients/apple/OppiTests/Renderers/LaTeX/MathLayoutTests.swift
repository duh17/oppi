import CoreGraphics
import Testing
@testable import Oppi

/// What a formula looks like once laid out and drawn: where glyphs, rules and
/// scripts land, which glyphs draw, and how much of the raster each part
/// covers. Geometry is read from the layout tree's absolute frames or from a
/// rendered bitmap, never from the tree's shape.
@Suite("MathLayoutTests")
struct MathLayoutTests {
    let parser = TeXMathParser()
    let renderer = MathCoreGraphicsRenderer()
    let fontSize: CGFloat = 40

    // MARK: - Helpers

    private func layout(_ tex: String, inline: Bool = false) -> MathRenderLayout {
        renderer.layout(
            parser.parse(tex),
            configuration: RenderConfiguration(
                fontSize: fontSize,
                maxWidth: 4_000,
                theme: .fallback,
                displayMode: inline ? .inline : .document
            )
        )
    }

    /// A drawn piece of the formula with its frame in root coordinates (y down).
    private struct Leaf {
        let text: String?
        let frame: CGRect
        let isRule: Bool
    }

    private func leaves(_ tex: String, inline: Bool = false) -> (leaves: [Leaf], root: LayoutBox) {
        let root = layout(tex, inline: inline).rootBox
        var result: [Leaf] = []
        func walk(_ box: LayoutBox, _ origin: CGPoint) {
            let frame = CGRect(origin: CGPoint(x: origin.x + box.origin.x, y: origin.y + box.origin.y), size: box.size)
            switch box.content {
            case .glyph(let text, _):
                result.append(Leaf(text: text, frame: frame, isRule: false))
            case .line:
                result.append(Leaf(text: nil, frame: frame, isRule: true))
            case .container(let children):
                for child in children { walk(child, frame.origin) }
            default:
                result.append(Leaf(text: nil, frame: frame, isRule: false))
            }
        }
        walk(root, .zero)
        return (result, root)
    }

    private func leaf(_ text: String, in leaves: [Leaf], sourceLocation: SourceLocation = #_sourceLocation) -> Leaf? {
        let found = leaves.first { $0.text == text }
        #expect(found != nil, "no glyph run \(text) in \(leaves.compactMap(\.text))", sourceLocation: sourceLocation)
        return found
    }

    /// Alpha of every pixel of the formula drawn with a margin around its box.
    private struct Raster {
        static let margin = 24
        let width: Int
        let height: Int
        let alpha: [UInt8]
        let boxSize: CGSize

        func painted(_ x: Int, _ y: Int) -> Bool { alpha[y * width + x] > 64 }

        /// Painted extent within `columns`, as (minY, maxY), or nil.
        func rows(inColumns columns: Range<Int>) -> (min: Int, max: Int)? {
            var low: Int?
            var high: Int?
            for y in 0 ..< height {
                for x in columns where x >= 0 && x < width && painted(x, y) {
                    low = low ?? y
                    high = y
                    break
                }
            }
            guard let low, let high else { return nil }
            return (low, high)
        }

        var inkColumns: (min: Int, max: Int)? {
            var low: Int?
            var high: Int?
            for x in 0 ..< width {
                for y in 0 ..< height where painted(x, y) {
                    low = low ?? x
                    high = x
                    break
                }
            }
            guard let low, let high else { return nil }
            return (low, high)
        }

        func columns(inRows rows: ClosedRange<Int>) -> (min: Int, max: Int)? {
            var low: Int?
            var high: Int?
            for x in 0 ..< width {
                for y in rows where painted(x, y) {
                    low = low ?? x
                    high = x
                    break
                }
            }
            guard let low, let high else { return nil }
            return (low, high)
        }
    }

    private func raster(_ tex: String, inline: Bool = false) throws -> Raster {
        let result = layout(tex, inline: inline)
        let size = renderer.boundingBox(result)
        let width = Int(ceil(size.width)) + 2 * Raster.margin
        let height = Int(ceil(size.height)) + 2 * Raster.margin
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draw as UIKit does: y down from the top-left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        renderer.draw(result, in: context, at: CGPoint(x: Raster.margin, y: Raster.margin))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let alpha = (0 ..< width * height).map { pixels[$0 * 4 + 3] }
        return Raster(width: width, height: height, alpha: alpha, boxSize: size)
    }

    // MARK: - Empty input

    @Test func emptyInputProducesZeroSize() {
        #expect(renderer.boundingBox(layout("")) == .zero)
    }

    // MARK: - Glyph choice

    /// Variables are italic and the font commands draw their own alphabets,
    /// not the plain letter (`\mathbb{R}` once drew an ordinary R).
    @Test(arguments: [
        ("x", "\u{1D465}"),
        (#"\mathbb{R}"#, "\u{211D}"),
        (#"\mathbb{C}"#, "\u{2102}"),
        (#"\mathbf{E}"#, "\u{1D404}"),
        (#"\mathcal{L}"#, "\u{2112}"),
        (#"\mathfrak{J}"#, "\u{1D50D}"),
        (#"\mathrm{d}"#, "d"),
        (#"\operatorname{sgn}"#, "sgn"),
    ])
    func lettersDrawInTheirMathAlphabet(tex: String, glyph: String) {
        let drawn = leaves(tex).leaves.compactMap(\.text).joined()
        #expect(drawn == glyph, "\(tex) drew \(drawn.unicodeScalars.map { String($0.value, radix: 16) })")
    }

    // MARK: - Fractions

    /// The bar sits on the math axis, a quarter em above the baseline, so a
    /// fraction centres on the minus sign and stands beside text, not below it.
    @Test func fractionBarSitsOnTheMathAxis() throws {
        let (parts, root) = leaves(#"a = \frac{1}{2}"#)
        let bar = try #require(parts.first(where: { $0.isRule }))
        let height = root.baseline - bar.frame.midY
        #expect(height > fontSize * 0.15 && height < fontSize * 0.35, "bar is \(height / fontSize) em above the baseline")
    }

    @Test func numeratorAboveBarAboveDenominator() throws {
        let parts = leaves(#"\frac{a}{b}"#).leaves
        let bar = try #require(parts.first(where: { $0.isRule }))
        let numerator = try #require(leaf("\u{1D44E}", in: parts))
        let denominator = try #require(leaf("\u{1D44F}", in: parts))
        #expect(numerator.frame.maxY < bar.frame.minY)
        #expect(denominator.frame.minY > bar.frame.maxY)
    }

    /// Display style keeps a fraction's parts full size; text style shrinks
    /// them, and `\displaystyle` switches an inline formula to display.
    @Test func displayStyleSwitchEnlargesAnInlineFraction() {
        let plain = layout(#"\frac{a}{b}"#, inline: true).rootBox.size.height
        let switched = layout(#"\displaystyle\frac{a}{b}"#, inline: true).rootBox.size.height
        let display = layout(#"\frac{a}{b}"#).rootBox.size.height
        #expect(switched > plain * 1.2)
        #expect(abs(switched - display) < 1)
    }

    @Test func binomialStacksWithoutABarInsideParentheses() throws {
        let parts = leaves(#"\binom{n}{k}"#).leaves
        #expect(!parts.contains(where: { $0.isRule }))
        let top = try #require(leaf("\u{1D45B}", in: parts))
        let bottom = try #require(leaf("\u{1D458}", in: parts))
        #expect(top.frame.maxY <= bottom.frame.minY)
        let picture = try raster(#"\binom{n}{k}"#)
        let stack = try #require(picture.rows(inColumns: 0 ..< picture.width))
        let left = try #require(picture.rows(inColumns: 0 ..< Raster.margin + Int(fontSize * 0.45)))
        #expect(Double(left.max - left.min) > Double(stack.max - stack.min) * 0.85, "the parenthesis covers the stack")
    }

    // MARK: - Scripts and limits

    /// In a line of prose, limits go beside the operator so the line keeps
    /// its height; display style stacks them.
    @Test func inlineLimitsGoBesideTheOperator() throws {
        let tex = #"\sum_{k=1}^{n} k"#
        let inline = leaves(tex, inline: true)
        let display = leaves(tex)
        #expect(inline.root.size.height < display.root.size.height * 0.8)
        let sum = try #require(leaf("\u{2211}", in: inline.leaves))
        let upper = try #require(leaf("\u{1D45B}", in: inline.leaves))
        #expect(upper.frame.minX >= sum.frame.maxX - 0.5)
    }

    /// Function names take scripts beside them, in display style too:
    /// `\cos^2` is a power, `\log_b` a base.
    @Test(arguments: [(#"\cos^2\theta"#, "cos", "2"), (#"\log_b x"#, "log", "\u{1D44F}")])
    func functionNamesTakeScriptsBeside(tex: String, name: String, script: String) throws {
        let parts = leaves(tex).leaves
        let operatorName = try #require(leaf(name, in: parts))
        let attached = try #require(leaf(script, in: parts))
        #expect(attached.frame.minX >= operatorName.frame.maxX - 0.5)
    }

    /// Exponents on function names line up: the dot of the i in `sin` does
    /// not lift its exponent above `cos`'s.
    @Test func functionNameExponentsShareAHeight() throws {
        let sine = try #require(leaf("2", in: leaves(#"\sin^2"#).leaves))
        let cosine = try #require(leaf("2", in: leaves(#"\cos^2"#).leaves))
        let sineRoot = leaves(#"\sin^2"#).root
        let cosineRoot = leaves(#"\cos^2"#).root
        let sineRise = sineRoot.baseline - sine.frame.maxY
        let cosineRise = cosineRoot.baseline - cosine.frame.maxY
        #expect(abs(sineRise - cosineRise) < 0.5, "sin² rises \(sineRise), cos² \(cosineRise)")
    }

    // MARK: - Spacing

    /// TeX spacing: a leading minus binds to its operand, a binary minus is
    /// spaced, and a comma has a thin space after it.
    @Test func spacingFollowsAtomClasses() throws {
        let unary = leaves("(-b)").leaves
        let unaryMinus = try #require(leaf("\u{2212}", in: unary))
        let operand = try #require(leaf("\u{1D44F}", in: unary))
        #expect(operand.frame.minX - unaryMinus.frame.maxX < fontSize * 0.05)

        let binary = leaves("a-b").leaves
        let left = try #require(leaf("\u{1D44E}", in: binary))
        let minus = try #require(leaf("\u{2212}", in: binary))
        #expect(minus.frame.minX - left.frame.maxX > fontSize * 0.15)

        let list = leaves("a,b").leaves
        let comma = try #require(leaf(",", in: list))
        let next = try #require(leaf("\u{1D44F}", in: list))
        #expect(next.frame.minX - comma.frame.maxX > fontSize * 0.12)
    }

    // MARK: - Delimiters and radicals

    /// Stretchy delimiters, radicals and the cases brace grow to cover what
    /// they enclose instead of staying one line tall.
    @Test(arguments: [
        #"\left(\frac{a}{b}\right)"#,
        #"\begin{pmatrix}1\\2\\3\end{pmatrix}"#,
        #"\begin{bmatrix}1\\2\\3\\4\end{bmatrix}"#,
        #"\begin{cases}1 & a\\2 & b\\3 & c\end{cases}"#,
    ])
    func leftEdgeCoversTheContent(tex: String) throws {
        let picture = try raster(tex)
        let all = try #require(picture.rows(inColumns: 0 ..< picture.width))
        let edge = try #require(picture.rows(inColumns: 0 ..< Raster.margin + Int(fontSize * 0.45)))
        let covered = Double(edge.max - edge.min) / Double(all.max - all.min)
        #expect(covered > 0.85, "\(tex): left edge spans \(covered) of the formula")
    }

    /// The radical sign reaches from below the radicand up to its bar.
    @Test func radicalSignCoversATallRadicand() throws {
        let tex = #"\sqrt{\frac{a}{\frac{b}{c}}}"#
        let bar = try #require(leaves(tex).leaves.filter { $0.isRule }.min { $0.frame.minY < $1.frame.minY })
        let picture = try raster(tex)
        let all = try #require(picture.rows(inColumns: 0 ..< picture.width))
        let sign = try #require(picture.rows(inColumns: 0 ..< Raster.margin + Int(bar.frame.minX)))
        let covered = Double(sign.max - sign.min) / Double(all.max - all.min)
        #expect(covered > 0.85, "the sign spans \(covered) of the formula")
    }

    @Test func sizedDelimitersGrowWithTheirCommand() throws {
        let plain = try #require(try raster("[x").rows(inColumns: 0 ..< Raster.margin + Int(fontSize * 0.3)))
        let big = try #require(try raster(#"\Big[x"#).rows(inColumns: 0 ..< Raster.margin + Int(fontSize * 0.3)))
        #expect(Double(big.max - big.min) > Double(plain.max - plain.min) * 1.4)
    }

    // MARK: - Accents and bars

    @Test func overlineSpansItsWholeBase() throws {
        let parts = leaves(#"\overline{x_2}"#).leaves
        let bar = try #require(parts.first(where: { $0.isRule }))
        let base = parts.filter { $0.text != nil }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        #expect(bar.frame.width >= base.width * 0.9)
        #expect(bar.frame.maxY <= base.minY)
    }

    /// The accent's ink centres over its base's ink (the hat on f once
    /// floated off to the left).
    @Test(arguments: [#"\hat{f}"#, #"\hat{x}"#, #"\vec{a}"#, #"\tilde{d}"#, #"\hat{H}"#])
    func accentCentresOverItsBase(tex: String) throws {
        let picture = try raster(tex)
        let rows = try #require(picture.rows(inColumns: 0 ..< picture.width))
        // The first blank row below the accent separates it from the base.
        var gap = rows.min
        while gap <= rows.max, picture.columns(inRows: gap ... gap) != nil { gap += 1 }
        try #require(gap < rows.max, "\(tex): accent and base touch")
        let accent = try #require(picture.columns(inRows: rows.min ... gap))
        // Compare with the base's top, where the accent attaches: an italic
        // letter's foot sits left of its head.
        var baseTop = gap
        while baseTop < rows.max, picture.columns(inRows: baseTop ... baseTop) == nil { baseTop += 1 }
        let base = try #require(picture.columns(inRows: baseTop ... baseTop + (rows.max - baseTop) / 3))
        let offset = abs(Double(accent.min + accent.max) / 2 - Double(base.min + base.max) / 2)
        #expect(offset < Double(fontSize) * 0.15, "\(tex): accent is \(offset) px off centre")
        // And it sits just above the base rather than floating over it.
        let lift = baseTop - gap
        #expect(Double(lift) < Double(fontSize) * 0.2, "\(tex): accent floats \(lift) px above its base")
    }

    // MARK: - Canvas

    /// Every drawn pixel is inside the formula's box, so a raster of that
    /// size never clips an italic overhang, an accent or an integral.
    @Test(arguments: ["f", #"\int_0^1 f\,dx"#, #"\hat{f}(\xi)"#, #"\left(\frac{1}{2}\right)^n"#, #"\sqrt[3]{x}"#])
    func drawingStaysInsideTheBox(tex: String) throws {
        let picture = try raster(tex)
        let columns = try #require(picture.inkColumns)
        let rows = try #require(picture.rows(inColumns: 0 ..< picture.width))
        let margin = Raster.margin
        #expect(columns.min >= margin - 1 && columns.max <= margin + Int(ceil(picture.boxSize.width)))
        #expect(rows.min >= margin - 1 && rows.max <= margin + Int(ceil(picture.boxSize.height)))
    }
}
