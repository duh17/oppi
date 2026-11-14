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

        /// RGBA bytes, premultiplied, row by row.
        let rgba: [UInt8]

        func painted(_ x: Int, _ y: Int) -> Bool { alpha[y * width + x] > 64 }

        /// Mean colour (0...1) of the fully covered pixels in `columns`, or nil.
        func color(inColumns columns: Range<Int>) -> (red: Double, green: Double, blue: Double)? {
            var sum = (0.0, 0.0, 0.0)
            var count = 0.0
            for y in 0 ..< height {
                for x in columns where x >= 0 && x < width && alpha[y * width + x] == 255 {
                    let index = (y * width + x) * 4
                    sum.0 += Double(rgba[index]) / 255
                    sum.1 += Double(rgba[index + 1]) / 255
                    sum.2 += Double(rgba[index + 2]) / 255
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            return (sum.0 / count, sum.1 / count, sum.2 / count)
        }

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
        let rgba = Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
        return Raster(width: width, height: height, alpha: alpha, boxSize: size, rgba: rgba)
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
        (#"\boldsymbol{x}"#, "\u{1D499}"),
        (#"\boldsymbol{\alpha}"#, "\u{1D736}"),
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
        #"\left\lfloor\frac{a}{b}\right\rfloor"#,
        #"\left\lceil\frac{a}{b}\right\rceil"#,
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
    @Test(arguments: [#"\hat{f}"#, #"\hat{x}"#, #"\vec{a}"#, #"\tilde{d}"#, #"\hat{H}"#, #"\check{x}"#, #"\breve{a}"#])
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

    // MARK: - Readability floors

    /// Every glyph size in a layout at `size` points.
    private func glyphSizes(_ tex: String, size: CGFloat) -> [CGFloat] {
        let root = renderer.layout(
            parser.parse(tex),
            configuration: RenderConfiguration(fontSize: size, maxWidth: 4_000, theme: .fallback, displayMode: .inline)
        ).rootBox
        var sizes: [CGFloat] = []
        func walk(_ box: LayoutBox) {
            switch box.content {
            case .glyph(_, let size), .glyphID(_, let size): sizes.append(size)
            case .container(let children): children.forEach(walk)
            case .line: break
            }
        }
        walk(root)
        return sizes
    }

    /// Scripts of scripts at phone text size stay readable (11 pt), while a
    /// large formula keeps TeX's proportions and a tiny one never grows its
    /// scripts past its own size.
    @Test func scriptsNeverDrawBelowTheMinimumSize() throws {
        let phone = glyphSizes(#"x^{y^{z}}"#, size: 16)
        #expect(phone.min() == 11, "sizes \(phone)")
        let large = glyphSizes(#"x^{y^{z}}"#, size: 40)
        let smallest = try #require(large.min())
        #expect(smallest < 40 * 0.6 && smallest > 11, "sizes \(large)")
        let tiny = glyphSizes(#"x^{y^{z}}"#, size: 9)
        #expect(tiny.max() == 9 && tiny.min() == 9, "sizes \(tiny)")
    }

    /// A fraction bar in small math covers at least one whole device pixel
    /// of ink, instead of a faint fraction of one.
    @Test func rulesDrawAtLeastOneDevicePixel() throws {
        let result = renderer.layout(
            parser.parse(#"\frac{\phantom{xxxx}}{\phantom{xxxx}}"#),
            configuration: RenderConfiguration(fontSize: 6, maxWidth: 400, theme: .fallback, displayMode: .inline)
        )
        let size = renderer.boundingBox(result)
        let width = Int(ceil(size.width)) + 8
        let height = Int(ceil(size.height)) + 8
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        renderer.draw(result, in: context, at: CGPoint(x: 4, y: 4))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let column = width / 2
        let ink = (0 ..< height).reduce(0) { $0 + Int(pixels[($1 * width + column) * 4 + 3]) }
        #expect(ink >= 240, "the bar's column holds \(ink) / 255 of a pixel's ink")
    }

    // MARK: - Alignment environments

    /// align, align* and split line their `&` columns up as aligned does;
    /// \tag and \nonumber in a row leave the columns where they were.
    @Test(arguments: [
        #"\begin{align} a &= b \\ ccc &= d \end{align}"#,
        #"\begin{align*} a &= b \\ ccc &= d \end{align*}"#,
        #"\begin{equation}\begin{split} a &= b \\ ccc &= d \end{split}\end{equation}"#,
        #"\begin{align} a &= b \tag{1} \\ ccc &= d \nonumber \end{align}"#,
    ])
    func alignmentEnvironmentsLineUpTheirRelations(tex: String) {
        let parts = leaves(tex).leaves
        let equals = parts.filter { $0.text == "=" }
        #expect(equals.count == 2, "\(tex) drew \(parts.compactMap(\.text))")
        // \nonumber and \end leave nothing behind.
        #expect(!parts.contains { $0.text?.contains("\\") == true }, "\(tex) drew \(parts.compactMap(\.text))")
        #expect(parts.compactMap(\.text).count <= 11, "\(tex) drew \(parts.compactMap(\.text))")
        guard equals.count == 2 else { return }
        #expect(abs(equals[0].frame.minX - equals[1].frame.minX) < 0.5)
        #expect(equals[1].frame.minY > equals[0].frame.maxY)
    }

    @Test func gatherCentresEachRow() throws {
        let parts = leaves(#"\begin{gather} a \\ b + c \end{gather}"#).leaves
        let a = try #require(leaf("\u{1D44E}", in: parts))
        let b = try #require(leaf("\u{1D44F}", in: parts))
        let c = try #require(leaf("\u{1D450}", in: parts))
        #expect(abs(a.frame.midX - (b.frame.minX + c.frame.maxX) / 2) < fontSize * 0.1)
        #expect(b.frame.minY > a.frame.maxY)
    }

    /// A tag sits in parentheses after the formula with room before it;
    /// \tag* drops the parentheses.
    @Test func tagSetsItsLabelAfterTheFormula() throws {
        let parts = leaves(#"x = 1 \tag{2}"#).leaves
        #expect(parts.compactMap(\.text).suffix(3) == ["(", "2", ")"], "drew \(parts.compactMap(\.text))")
        let one = try #require(leaf("1", in: parts))
        let open = try #require(leaf("(", in: parts))
        #expect(open.frame.minX - one.frame.maxX >= fontSize * 0.9)

        let starred = leaves(#"x \tag*{A}"#).leaves.compactMap(\.text)
        #expect(starred == ["\u{1D465}", "A"], "drew \(starred)")
    }

    // MARK: - Symbols

    @Test(arguments: [
        (#"\notin"#, "\u{2209}"), (#"\setminus"#, "\u{2216}"), (#"\circ"#, "\u{2218}"),
        (#"\oplus"#, "\u{2295}"), (#"\otimes"#, "\u{2297}"), (#"\wedge"#, "\u{2227}"),
        (#"\vee"#, "\u{2228}"), (#"\perp"#, "\u{22A5}"), (#"\ll"#, "\u{226A}"), (#"\gg"#, "\u{226B}"),
        (#"\aleph"#, "\u{2135}"), (#"\longrightarrow"#, "\u{27F6}"), (#"\longleftarrow"#, "\u{27F5}"),
        (#"\longleftrightarrow"#, "\u{27F7}"), (#"\Longrightarrow"#, "\u{27F9}"),
        (#"\Longleftarrow"#, "\u{27F8}"), (#"\Longleftrightarrow"#, "\u{27FA}"), (#"\longmapsto"#, "\u{27FC}"),
        (#"\lfloor x \rfloor"#, "\u{230A}\u{1D465}\u{230B}"), (#"\lceil x \rceil"#, "\u{2308}\u{1D465}\u{2309}"),
    ])
    func symbolCommandsDrawTheirGlyph(tex: String, glyph: String) {
        let drawn = leaves(tex).leaves.compactMap(\.text).joined()
        #expect(drawn == glyph, "\(tex) drew \(drawn.unicodeScalars.map { String($0.value, radix: 16) })")
    }

    /// Relations take a thick space (5 mu) each side, binary operators a
    /// medium one (4 mu).
    @Test(arguments: [
        (#"a \notin b"#, "\u{2209}", 5.0), (#"a \perp b"#, "\u{22A5}", 5.0), (#"a \ll b"#, "\u{226A}", 5.0),
        (#"a \longrightarrow b"#, "\u{27F6}", 5.0), (#"a \oplus b"#, "\u{2295}", 4.0),
        (#"a \setminus b"#, "\u{2216}", 4.0), (#"a \wedge b"#, "\u{2227}", 4.0), (#"a \circ b"#, "\u{2218}", 4.0),
    ])
    func operatorsTakeTheirClassSpacing(tex: String, glyph: String, mu: Double) throws {
        let parts = leaves(tex).leaves
        let a = try #require(leaf("\u{1D44E}", in: parts))
        let op = try #require(leaf(glyph, in: parts))
        let gap = op.frame.minX - a.frame.maxX
        #expect(abs(gap - CGFloat(mu) * fontSize / 18) < 0.5, "\(tex): gap is \(gap * 18 / fontSize) mu")
    }

    /// `\dots` is low between commas and centred between operators, as
    /// amsmath picks from what follows it.
    @Test(arguments: [
        (#"a_1, \dots, a_n"#, "\u{2026}"),
        (#"a_1 + \dots + a_n"#, "\u{22EF}"),
        (#"x_1 = \dots = x_n"#, "\u{22EF}"),
        (#"1, 2, \ldots, n"#, "\u{2026}"),
        (#"\dotsb"#, "\u{22EF}"),
    ])
    func dotsPickTheirHeightFromWhatFollows(tex: String, glyph: String) {
        let drawn = leaves(tex).leaves.compactMap(\.text)
        #expect(drawn.contains(glyph), "\(tex) drew \(drawn)")
    }

    // MARK: - Over, under and limits

    /// \overset and \stackrel put a small label centred over a relation that
    /// keeps its spacing; \underset hangs it below.
    @Test(arguments: [#"a \overset{!}{=} b"#, #"a \stackrel{!}{=} b"#])
    func oversetStacksItsLabelOverTheBase(tex: String) throws {
        let parts = leaves(tex).leaves
        let mark = try #require(leaf("!", in: parts))
        let equals = try #require(leaf("=", in: parts))
        let a = try #require(leaf("\u{1D44E}", in: parts))
        #expect(mark.frame.maxY < equals.frame.minY)
        #expect(abs(mark.frame.midX - equals.frame.midX) < fontSize * 0.1)
        #expect(equals.frame.minX - a.frame.maxX > fontSize * 0.2, "the stack is still a relation")
    }

    @Test func undersetHangsItsLabelUnderTheBase() throws {
        let parts = leaves(#"a \underset{n}{=} b"#).leaves
        let label = try #require(leaf("\u{1D45B}", in: parts))
        let equals = try #require(leaf("=", in: parts))
        #expect(label.frame.minY > equals.frame.maxY)
        #expect(abs(label.frame.midX - equals.frame.midX) < fontSize * 0.1)
    }

    @Test func substackStacksLimitRowsUnderTheOperator() throws {
        let parts = leaves(#"\sum_{\substack{i < n \\ j < m}} a"#).leaves
        let body = try #require(leaf("\u{1D44E}", in: parts))
        let first = try #require(leaf("\u{1D456}", in: parts))
        let second = try #require(leaf("\u{1D457}", in: parts))
        #expect(first.frame.minY > body.frame.maxY)
        #expect(second.frame.minY > first.frame.maxY)
        #expect(first.frame.maxX < body.frame.minX, "the rows sit under the sum, before its body")
    }

    /// \limits stacks an integral's limits; \nolimits puts a display sum's
    /// beside it.
    @Test func limitsAndNolimitsOverrideWhereLimitsGo() throws {
        let stacked = leaves(#"\int\limits_0^1 f"#).leaves
        let f = try #require(leaf("\u{1D453}", in: stacked))
        let lower = try #require(leaf("0", in: stacked))
        let upper = try #require(leaf("1", in: stacked))
        #expect(lower.frame.minY > f.frame.maxY)
        #expect(upper.frame.maxY < f.frame.minY)

        let normal = try #require(leaf("\u{1D458}", in: leaves(#"\sum_{k} a"#).leaves))
        let beside = leaves(#"\sum\nolimits_{k} a"#)
        let moved = try #require(leaf("\u{1D458}", in: beside.leaves))
        #expect(moved.frame.minX > normal.frame.minX + fontSize * 0.3)
        #expect(beside.root.size.height < leaves(#"\sum_{k} a"#).root.size.height)
    }

    /// \operatorname* takes limits under the name in display and beside it
    /// in a line of text, as \max does.
    @Test func starredOperatorNameStacksLimitsInDisplay() throws {
        let tex = #"\operatorname*{arg\,min}_{\theta} f"#
        let display = leaves(tex).leaves
        let theta = try #require(leaf("\u{1D703}", in: display))
        let a = try #require(leaf("a", in: display))
        let n = try #require(leaf("n", in: display))
        #expect(theta.frame.minY > a.frame.maxY)
        #expect(theta.frame.maxX < n.frame.maxX)

        let inline = leaves(tex, inline: true).leaves
        let inlineTheta = try #require(leaf("\u{1D703}", in: inline))
        let inlineN = try #require(leaf("n", in: inline))
        #expect(inlineTheta.frame.minX >= inlineN.frame.maxX - 0.5)
    }

    /// A brace's script labels the brace: centred over (or under) it, not
    /// beside it as an exponent.
    @Test(arguments: [(#"\overbrace{a+b}^{n}"#, true), (#"\underbrace{a+b}_{n}"#, false)])
    func braceScriptsLabelTheBrace(tex: String, over: Bool) throws {
        let parts = leaves(tex).leaves
        let a = try #require(leaf("\u{1D44E}", in: parts))
        let b = try #require(leaf("\u{1D44F}", in: parts))
        let label = try #require(leaf("\u{1D45B}", in: parts))
        #expect(abs(label.frame.midX - (a.frame.minX + b.frame.maxX) / 2) < fontSize * 0.1)
        if over {
            #expect(label.frame.maxY < a.frame.minY)
        } else {
            #expect(label.frame.minY > a.frame.maxY)
        }
    }

    // MARK: - Phantom and colour

    @Test func phantomTakesItsContentsRoomButDrawsNothing() throws {
        let parts = leaves(#"a\phantom{bb}c"#).leaves
        #expect(!parts.contains { $0.text == "\u{1D44F}" })
        let a = try #require(leaf("\u{1D44E}", in: parts))
        let c = try #require(leaf("\u{1D450}", in: parts))
        let bees = leaves("bb").leaves.filter { $0.text != nil }
        let width = (bees.last?.frame.maxX ?? 0) - (bees.first?.frame.minX ?? 0)
        #expect(abs((c.frame.minX - a.frame.maxX) - width) < 0.5)
    }

    /// Named and hex colours draw in the theme's matching accent, so they keep
    /// the palette's contrast; the colour ends with its group.
    @Test(arguments: [
        (#"\textcolor{blue}{x}\quad y"#, RenderTheme.fallback.accentBlue),
        (#"{\color{red} x}\quad y"#, RenderTheme.fallback.accentRed),
        (#"\textcolor{#1a8f2e}{x}\quad y"#, RenderTheme.fallback.accentGreen),
        (#"\color[HTML]{FF8800} x\quad\color{black} y"#, RenderTheme.fallback.accentOrange),
    ])
    func colorDrawsInThePaletteAccent(tex: String, expected: CGColor) throws {
        let parts = leaves(tex).leaves
        let x = try #require(leaf("\u{1D465}", in: parts))
        let y = try #require(leaf("\u{1D466}", in: parts))
        let picture = try raster(tex)
        let columns = { (frame: CGRect) in Raster.margin + Int(frame.minX) ..< Raster.margin + Int(ceil(frame.maxX)) }
        let colored = try #require(picture.color(inColumns: columns(x.frame)))
        let plain = try #require(picture.color(inColumns: columns(y.frame)))
        let want = try #require(expected.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components)
        let foreground = try #require(
            RenderTheme.fallback.foreground.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components
        )
        func near(_ color: (red: Double, green: Double, blue: Double), _ target: [CGFloat]) -> Bool {
            abs(color.red - target[0]) < 0.06 && abs(color.green - target[1]) < 0.06 && abs(color.blue - target[2]) < 0.06
        }
        #expect(near(colored, want), "\(tex): x drew \(colored), want \(want)")
        #expect(near(plain, foreground), "\(tex): y drew \(plain), want the foreground")
    }
}
