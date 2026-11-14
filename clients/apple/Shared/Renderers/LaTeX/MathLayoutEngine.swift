import CoreGraphics
import CoreText
import Foundation

// MARK: - Layout Box Model

/// A positioned box in the layout tree.
///
/// Each `MathNode` becomes one or more `LayoutBox` instances during layout.
/// Positions are relative to the parent container's origin (top-left, y down).
struct LayoutBox: Equatable, Sendable {
    /// Top-left corner relative to parent.
    var origin: CGPoint
    /// Advance width and height. Glyph boxes are as tall as their ink, as TeX
    /// measures characters, so spacing follows what is drawn.
    var size: CGSize
    /// Distance from top edge to the baseline (for vertical alignment).
    var baseline: CGFloat
    /// What this box contains.
    var content: LayoutContent
    /// Drawn extent relative to this box's origin. Ink can pass the box:
    /// italic overhangs, accents, a negative kern. `.null` when nothing draws.
    var ink: CGRect = .null
    /// Slant overhang of a box that ends in an italic glyph; a superscript
    /// moves right by it.
    var italicCorrection: CGFloat = 0
    /// \color for this box and what it holds, unless a child sets its own.
    /// A theme token, resolved when drawing, so layout stays theme-free.
    var color: MathColor?

    var ascent: CGFloat { baseline }
    var descent: CGFloat { size.height - baseline }
}

/// Content inside a layout box.
enum LayoutContent: Equatable, Sendable {
    /// A run of text in the math font at the given size, baseline at the
    /// box's baseline.
    case glyph(String, CGFloat)
    /// One glyph of the math font by id: size variants and assembly parts
    /// that have no character of their own.
    case glyphID(CGGlyph, CGFloat)
    /// A filled rule from one point to another (fraction bars, overbars).
    case line(CGPoint, CGPoint, CGFloat)
    /// A container holding child boxes positioned relative to this box's origin.
    case container([LayoutBox])
}

// MARK: - Layout Engine

/// Converts `[MathNode]` into a positioned `LayoutBox` tree.
///
/// Follows TeX's rules with the constants, size variants and assembly parts
/// of the math font's OpenType MATH table (`MathFont`): four styles (display,
/// text, script, scriptscript), inter-atom spacing by atom class, fractions
/// and big operators centred on the math axis, stretchy delimiters and
/// radicals, and accents placed on each glyph's attachment point. Letters map
/// to Unicode's mathematical alphanumerics, so italic, bold, blackboard,
/// script, fraktur, sans and monospace all come from the one font.
struct MathLayoutEngine: Sendable {
    /// Minimum font size to prevent infinite shrinking in deep nesting.
    private static let minimumFontSize: CGFloat = 6.0

    /// Layout a list of math nodes at the given font size. Display style
    /// stacks limits and sets fractions full size; text style is for math in
    /// a line of prose.
    ///
    /// The returned box covers every drawn pixel: its size and baseline grow
    /// to include ink that overhangs the advance boxes.
    func layout(_ nodes: [MathNode], fontSize: CGFloat, display: Bool = true) -> LayoutBox {
        guard !nodes.isEmpty else {
            return LayoutBox(origin: .zero, size: .zero, baseline: 0, content: .container([]))
        }
        let typesetter = Typesetter(font: .shared)
        let style = Style(
            level: display ? .display : .text,
            baseSize: max(fontSize, Self.minimumFontSize),
            scales: typesetter.font.constants
        )
        let box = typesetter.list(nodes, style)
        return Self.coveringInk(box, margin: max(fontSize, Self.minimumFontSize) * 0.04)
    }

    /// Grows the root so its rect holds all ink plus an anti-aliasing margin.
    private static func coveringInk(_ box: LayoutBox, margin: CGFloat) -> LayoutBox {
        var bounds = CGRect(origin: .zero, size: box.size)
        if !box.ink.isNull { bounds = bounds.union(box.ink.insetBy(dx: -margin, dy: -margin)) }
        var child = box
        child.origin = CGPoint(x: -bounds.minX, y: -bounds.minY)
        let size = CGSize(width: ceil(bounds.width * 2) / 2, height: ceil(bounds.height * 2) / 2)
        return LayoutBox(
            origin: .zero,
            size: size,
            baseline: child.origin.y + box.baseline,
            content: .container([child]),
            ink: box.ink.offsetBy(dx: child.origin.x, dy: child.origin.y)
        )
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
        case .star: return "\u{2217}"  // ∗
        case .equal: return "="
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .leq: return "\u{2264}"   // ≤
        case .geq: return "\u{2265}"   // ≥
        case .neq: return "\u{2260}"   // ≠
        case .approx: return "\u{2248}" // ≈
        case .equiv: return "\u{2261}" // ≡
        case .sim: return "\u{223C}"   // ∼
        case .propto: return "\u{221D}" // ∝
        case .mid: return "\u{2223}"   // ∣
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
        case .iff: return "\u{27FA}" // ⟺
        case .doubleRightarrow: return "\u{21D2}" // ⇒
        case .doubleLeftarrow: return "\u{21D0}" // ⇐
        case .doubleLeftrightarrow: return "\u{21D4}" // ⇔
        case .leftrightarrow: return "\u{2194}" // ↔
        case .notin: return "\u{2209}" // ∉
        case .perp: return "\u{22A5}" // ⊥
        case .ll: return "\u{226A}" // ≪
        case .gg: return "\u{226B}" // ≫
        case .longrightarrow: return "\u{27F6}" // ⟶
        case .longleftarrow: return "\u{27F5}" // ⟵
        case .longleftrightarrow: return "\u{27F7}" // ⟷
        case .doubleLongRightarrow: return "\u{27F9}" // ⟹
        case .doubleLongLeftarrow: return "\u{27F8}" // ⟸
        case .doubleLongLeftrightarrow: return "\u{27FA}" // ⟺
        case .longmapsto: return "\u{27FC}" // ⟼
        case .setminus: return "\u{2216}" // ∖
        case .circ: return "\u{2218}" // ∘
        case .oplus: return "\u{2295}" // ⊕
        case .otimes: return "\u{2297}" // ⊗
        case .wedge: return "\u{2227}" // ∧
        case .vee: return "\u{2228}" // ∨
        case .colon: return ":"
        case .comma: return ","
        case .semicolon: return ";"
        case .bang: return "!"
        }
    }

    static func isRelationOperator(_ op: MathOperator) -> Bool {
        switch op {
        case .equal, .lessThan, .greaterThan, .leq, .geq, .neq,
             .approx, .equiv, .sim, .propto, .mid, .in, .subset, .supset,
             .subseteq, .supseteq, .to, .rightarrow, .leftarrow, .mapsto,
             .iff, .doubleRightarrow, .doubleLeftarrow, .doubleLeftrightarrow,
             .leftrightarrow, .colon, .notin, .perp, .ll, .gg, .longrightarrow,
             .longleftarrow, .longleftrightarrow, .doubleLongRightarrow,
             .doubleLongLeftarrow, .doubleLongLeftrightarrow, .longmapsto:
            return true
        default:
            return false
        }
    }

    static func isBinaryOperator(_ op: MathOperator) -> Bool {
        switch op {
        case .plus, .minus, .times, .div, .cdot, .pm, .mp, .star, .cup, .cap,
             .setminus, .circ, .oplus, .otimes, .wedge, .vee:
            return true
        default:
            return false
        }
    }

    /// TeX's glyph for each symbol command. `\phi` and `\epsilon` are the
    /// straight forms; `\varphi` and `\varepsilon` the curly ones.
    static func symbolDisplayString(_ sym: MathSymbol) -> String {
        switch sym {
        case .alpha: return "\u{03B1}"
        case .beta: return "\u{03B2}"
        case .gamma: return "\u{03B3}"
        case .delta: return "\u{03B4}"
        case .epsilon: return "\u{03F5}"
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
        case .phi: return "\u{03D5}"
        case .varphi: return "\u{03C6}"
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
        case .top: return "\u{22A4}"
        case .aleph: return "\u{2135}"
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
        case .xrightarrow: return "\u{2192}" // →, stretched to its label
        case .xleftarrow: return "\u{2190}" // ←
        }
    }

    /// Operator names set as upright words rather than symbols.
    static func isTextOperator(_ kind: BigOpKind) -> Bool {
        switch kind {
        case .lim, .sup, .inf, .min, .max, .det, .log, .ln,
             .sin, .cos, .tan, .exp:
            return true
        default:
            return false
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
        case .floor: return "\u{230A}" // ⌊
        case .closeFloor: return "\u{230B}" // ⌋
        case .ceil: return "\u{2308}" // ⌈
        case .closeCeil: return "\u{2309}" // ⌉
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

// MARK: - Style

/// TeX's math style: the level sets the size and whether limits stack and
/// fractions stay full size; cramped styles raise superscripts less.
private struct Style {
    enum Level: Int { case display, text, script, scriptScript }

    var level: Level
    var baseSize: CGFloat
    var fontStyle: MathFontStyle?
    var color: MathColor?
    var cramped = false
    let scriptScale: CGFloat
    let scriptScriptScale: CGFloat

    init(level: Level, baseSize: CGFloat, scales: MathFont.Constants) {
        self.level = level
        self.baseSize = baseSize
        scriptScale = scales.scriptScale
        scriptScriptScale = scales.scriptScriptScale
    }

    var isDisplay: Bool { level == .display }
    var isScript: Bool { level.rawValue >= Level.script.rawValue }

    /// Smallest size, in points, a script or a script's script sets in: TeX's
    /// 50% scriptscript size reads as specks beside phone body text. A
    /// formula set smaller than this keeps its scripts at its own size.
    static let minimumScriptSize: CGFloat = 11

    var size: CGFloat {
        let scale: CGFloat = switch level {
        case .display, .text: 1
        case .script: scriptScale
        case .scriptScript: scriptScriptScale
        }
        return max(baseSize * scale, min(Self.minimumScriptSize, baseSize), 6)
    }

    func with(_ level: Level, cramped: Bool? = nil) -> Self {
        var style = self
        style.level = level
        if let cramped { style.cramped = cramped }
        return style
    }

    func restyled(_ kind: MathStyleKind) -> Self {
        switch kind {
        case .display: with(.display)
        case .text: with(.text)
        case .script: with(.script)
        case .scriptScript: with(.scriptScript)
        }
    }

    /// Superscripts and limits.
    var superscript: Self { with(level.rawValue <= Level.text.rawValue ? .script : .scriptScript) }
    /// Subscripts are cramped.
    var `subscript`: Self { with(superscript.level, cramped: true) }
    var numerator: Self {
        switch level {
        case .display: with(.text)
        case .text: with(.script)
        case .script, .scriptScript: with(.scriptScript)
        }
    }
    var denominator: Self { with(numerator.level, cramped: true) }
    var crampedStyle: Self { with(level, cramped: true) }
}

// MARK: - Atom classes

/// TeX's atom classes, which decide the space between neighbours.
private enum AtomClass: Int {
    case ord, op, bin, rel, open, close, punct, inner

    /// Space between a left and a right atom in mu (1/18 em): 1 thin,
    /// 2 medium, 3 thick. Negative entries apply only outside script styles.
    /// TeXbook, chapter 18.
    private static let table: [[Int]] = [
        //  ord op bin rel open close punct inner
        [0, 1, -2, -3, 0, 0, 0, -1], // ord
        [1, 1, 0, -3, 0, 0, 0, -1], // op
        [-2, -2, 0, 0, -2, 0, 0, -2], // bin
        [-3, -3, 0, 0, -3, 0, 0, -3], // rel
        [0, 0, 0, 0, 0, 0, 0, 0], // open
        [0, 1, -2, -3, 0, 0, 0, -1], // close
        [-1, -1, 0, -1, -1, -1, -1, -1], // punct
        [-1, 1, -2, -3, -1, 0, -1, -1], // inner
    ]

    /// The space in mu: thin 3, medium 4, thick 5.
    func space(before right: Self, inScript: Bool) -> CGFloat {
        let entry = Self.table[rawValue][right.rawValue]
        if entry < 0, inScript { return 0 }
        return CGFloat([0, 3, 4, 5][abs(entry)])
    }
}

// MARK: - Typesetter

private struct Typesetter {
    let font: MathFont
    var c: MathFont.Constants { font.constants }

    // MARK: Lists

    /// One item of a flattened list: a node and the style it sets in.
    private struct Item {
        let node: MathNode
        let style: Style
    }

    private func flatten(_ nodes: [MathNode], _ style: Style, into items: inout [Item]) {
        for node in nodes {
            switch node {
            case .style(let kind, let body):
                flatten(body, style.restyled(kind), into: &items)
            case .color(let color, let body):
                // Colour does not group: its atoms space with their neighbours.
                var colored = style
                colored.color = color
                flatten(body, colored, into: &items)
            default:
                items.append(Item(node: node, style: style))
            }
        }
    }

    /// Lays a list out left to right with TeX's spacing between atoms.
    /// `leadingOrd` spaces the first atom as if an empty group came before it,
    /// as amsmath does for the right side of an alignment (`&=`).
    func list(_ nodes: [MathNode], _ style: Style, leadingOrd: Bool = false) -> LayoutBox {
        var items: [Item] = []
        flatten(nodes, style, into: &items)
        // A \tag goes after everything else in its formula.
        let tags = items.filter { if case .tag = $0.node { true } else { false } }
        if !tags.isEmpty {
            items.removeAll { if case .tag = $0.node { true } else { false } }
        }

        // Atom classes, with TeX's rule that a binary operator with nothing
        // to bind on its left (or right) is an ordinary atom: −b, (−x).
        var classes: [AtomClass?] = items.map { atomClass($0.node) }
        var previous: Int?
        var previousClass: AtomClass? = leadingOrd ? .ord : nil
        for index in classes.indices {
            guard let current = classes[index] else { continue }
            if current == .bin {
                switch previousClass {
                case nil, .bin?, .op?, .rel?, .open?, .punct?:
                    classes[index] = .ord
                default:
                    break
                }
            }
            if let prior = previous, classes[prior] == .bin,
               [.rel, .close, .punct].contains(classes[index]) {
                classes[prior] = .ord
            }
            previous = index
            previousClass = classes[index]
        }
        if let last = previous, classes[last] == .bin {
            classes[last] = .ord
        }

        var children: [LayoutBox] = []
        var cursor: CGFloat = 0
        var leftClass: AtomClass? = leadingOrd ? .ord : nil
        var lastItalicCorrection: CGFloat = 0
        for (index, item) in items.enumerated() {
            if case .space(let space) = item.node {
                cursor += spaceWidth(space, item.style)
                continue
            }
            guard let atom = classes[index] else { continue }
            if let leftClass {
                cursor += leftClass.space(before: atom, inScript: item.style.isScript) * item.style.size / 18
            }
            var box = node(item.node, item.style)
            if box.color == nil { box.color = item.style.color }
            box.origin.x = cursor
            cursor += box.size.width
            lastItalicCorrection = box.italicCorrection
            children.append(box)
            leftClass = atom
        }
        for item in tags {
            cursor += Self.tagGap * item.style.size
            var box = node(item.node, item.style)
            if box.color == nil { box.color = item.style.color }
            box.origin.x = cursor
            cursor += box.size.width
            lastItalicCorrection = 0
            children.append(box)
        }
        var result = hbox(children, width: cursor)
        result.italicCorrection = lastItalicCorrection
        return result
    }

    /// Room before a \tag, in em.
    private static let tagGap: CGFloat = 2

    /// A tag's label: upright, in parentheses unless starred.
    private func tagLabel(_ body: [MathNode], parenthesized: Bool) -> [MathNode] {
        [.font(.roman, body: parenthesized ? [.variable("(")] + body + [.variable(")")] : body)]
    }

    private func atomClass(_ node: MathNode) -> AtomClass? {
        switch node {
        case .space, .style, .color, .tag:
            return nil
        case .number, .text, .font, .accent, .sqrt, .group, .substack, .phantom:
            return .ord
        case .operatorName:
            return .op
        case .stack(let base, _, _, let isRelation):
            if isRelation { return .rel }
            return base.count == 1 ? atomClass(base[0]) ?? .ord : .ord
        case .symbol(let symbol):
            return symbol == .cdots || symbol == .ldots ? .inner : .ord
        case .variable(let name):
            if ["(", "[", "{", "\u{27E8}", "\u{230A}", "\u{2308}"].contains(name) { return .open }
            if [")", "]", "}", "\u{27E9}", "\u{230B}", "\u{2309}"].contains(name) { return .close }
            return .ord
        case .operator(let op):
            if MathLayoutEngine.isRelationOperator(op) { return .rel }
            if MathLayoutEngine.isBinaryOperator(op) { return .bin }
            switch op {
            case .comma, .semicolon: return .punct
            case .bang: return .close
            default: return .ord
            }
        case .fraction, .binomial, .leftRight:
            return .inner
        case .matrix(_, let style):
            return style == .plain || style == .small ? .ord : .inner
        case .environment(let name, _):
            return name == "cases" ? .inner : .ord
        case .bigOperator(let kind, _):
            return kind == .xrightarrow || kind == .xleftarrow ? .rel : .op
        case .superscript(let base, _), .subscript(let base, _), .subSuperscript(let base, _, _):
            return base.count == 1 ? atomClass(base[0]) : .ord
        case .sizedDelimiter(let delimiter, _):
            switch delimiter {
            case .paren, .bracket, .brace, .angle, .floor, .ceil: return .open
            case .closeParen, .closeBracket, .closeBrace, .closeAngle, .closeFloor, .closeCeil: return .close
            default: return .ord
            }
        }
    }

    private func spaceWidth(_ space: MathSpace, _ style: Style) -> CGFloat {
        let mu = style.size / 18
        return switch space {
        case .thinSpace: 3 * mu
        case .mediumSpace: 4 * mu
        case .thickSpace: 5 * mu
        case .quad: 18 * mu
        case .qquad: 36 * mu
        case .negThin: -3 * mu
        case .backslashSpace: 0.25 * style.size
        }
    }

    // MARK: Nodes

    private func node(_ node: MathNode, _ style: Style) -> LayoutBox {
        switch node {
        case .variable(let name):
            return text(MathAlphabet.map(name, style: style.fontStyle, defaultItalic: true), style)
        case .number(let digits):
            return text(MathAlphabet.map(digits, style: style.fontStyle, defaultItalic: false), style)
        case .operator(let op):
            return text(MathLayoutEngine.operatorDisplayString(op), style)
        case .symbol(let symbol):
            return text(
                MathAlphabet.map(MathLayoutEngine.symbolDisplayString(symbol), style: style.fontStyle, defaultItalic: true),
                style
            )
        case .text(let content):
            return text(content, style)
        case .fraction(let numerator, let denominator):
            return fraction(numerator, denominator, style, hasRule: true)
        case .binomial(let top, let bottom):
            let stack = fraction(top, bottom, style, hasRule: false)
            return delimited(stack, left: .paren, right: .closeParen, style, shortfall: false)
        case .superscript(let base, let exponent):
            return scripts(base: list(base, style), baseIsCharacter: isCharacter(base), sup: exponent, sub: nil, style)
        case .subscript(let base, let index):
            return scripts(base: list(base, style), baseIsCharacter: isCharacter(base), sup: nil, sub: index, style)
        case .subSuperscript(let base, let sub, let sup):
            return scripts(base: list(base, style), baseIsCharacter: isCharacter(base), sup: sup, sub: sub, style)
        case .sqrt(let index, let radicand):
            return radical(index: index, radicand: radicand, style)
        case .leftRight(let left, let right, let body):
            return delimited(list(body, style), left: left, right: right, style)
        case .matrix(let rows, let matrixStyle):
            let cellStyle = matrixStyle == .small ? style.with(.script) : style.with(style.isScript ? style.level : .text)
            let grid = grid(rows, cellStyle, alignment: .centered, columnGap: 1, rowGap: 0)
            let (left, right) = MathLayoutEngine.matrixDelimiters(matrixStyle)
            guard left != .none || right != .none else { return grid }
            return delimited(grid, left: left, right: right, style, padding: 0.1)
        case .environment(let name, let rows):
            switch name {
            case "cases":
                let cellStyle = style.with(style.isScript ? style.level : .text)
                let grid = grid(rows, cellStyle, alignment: .left, columnGap: 1, rowGap: 0.2)
                return delimited(grid, left: .brace, right: .none, style, padding: 0.1)
            case "aligned":
                return grid(rows, style.with(.display), alignment: .alternatingRightLeft, columnGap: 1, rowGap: 0.3)
            default:
                return grid(rows, style.with(.display), alignment: .centered, columnGap: 1, rowGap: 0.3)
            }
        case .bigOperator(let kind, let limits):
            return bigOperator(kind, limits: limits, style)
        case .accent(let kind, let base):
            return accent(kind, base: base, style)
        case .group(let children):
            return list(children, style)
        case .font(let fontStyle, let body):
            var styled = style
            styled.fontStyle = fontStyle
            return list(body, styled)
        case .style(let kind, let body):
            return list(body, style.restyled(kind))
        case .color(let color, let body):
            var colored = style
            colored.color = color
            return list(body, colored)
        case .stack(let base, let over, let under, _):
            return limitStack(list(base, style), upper: over, lower: under, style)
        case .operatorName(let name, let limits, let starred):
            var roman = style
            roman.fontStyle = .roman
            var op = list(name, roman)
            op.italicCorrection = 0
            guard let limits, limits.lower != nil || limits.upper != nil else { return op }
            let stacks = switch limits.placement {
            case .stacked: true
            case .beside: false
            case .automatic: starred && style.isDisplay
            }
            if stacks { return limitStack(op, upper: limits.upper, lower: limits.lower, style) }
            return scripts(base: op, baseIsCharacter: true, sup: limits.upper, sub: limits.lower, style)
        case .substack(let rows):
            return grid(rows.map { [$0] }, style, alignment: .centered, columnGap: 0, rowGap: 0.1, strut: false)
        case .tag(let body, let parenthesized):
            return list(tagLabel(body, parenthesized: parenthesized), style)
        case .phantom(let kind, let body):
            let content = list(body, style)
            return LayoutBox(
                origin: .zero,
                size: CGSize(
                    width: kind == .vertical ? 0 : content.size.width,
                    height: kind == .horizontal ? 0 : content.size.height
                ),
                baseline: kind == .horizontal ? 0 : content.baseline,
                content: .container([])
            )
        case .sizedDelimiter(let delimiter, let size):
            let heights: [CGFloat] = [1.2, 1.8, 2.4, 3.0]
            let height = heights[min(max(size, 1), 4) - 1] * style.size
            return delimiterBox(delimiter, covering: height, style)
        case .space:
            return emptyBox(width: 0)
        }
    }

    /// A single letter, digit or symbol takes TeX's character script rules.
    private func isCharacter(_ base: [MathNode]) -> Bool {
        guard base.count == 1 else { return false }
        switch base[0] {
        case .variable(let name), .number(let name): return name.count == 1
        case .symbol: return true
        default: return false
        }
    }

    // MARK: Glyphs

    private func text(_ string: String, _ style: Style) -> LayoutBox {
        let size = style.size
        let ctFont = font.font(size: size)
        let metrics = GlyphMetrics.measure(string, font: ctFont)
        var italicCorrection = max(0, metrics.ink.maxX - metrics.width)
        if string.count == 1, let first = string.first, let glyph = font.glyph(for: first),
           let correction = font.italicCorrection(glyph) {
            italicCorrection = correction * size
        }
        return glyphBox(content: .glyph(string, size), width: metrics.width, ink: metrics.ink, italicCorrection: italicCorrection)
    }

    private func glyph(_ glyph: CGGlyph, size: CGFloat) -> LayoutBox {
        let ctFont = font.font(size: size)
        var id = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &id, &advance, 1)
        let ink = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &id, nil, 1)
        let correction = font.italicCorrection(glyph).map { $0 * size } ?? 0
        return glyphBox(content: .glyphID(glyph, size), width: advance.width, ink: ink, italicCorrection: correction)
    }

    /// A box as tall as its ink. `ink` is in CoreText's y-up glyph space.
    private func glyphBox(content: LayoutContent, width: CGFloat, ink: CGRect, italicCorrection: CGFloat) -> LayoutBox {
        let hasInk = !ink.isNull && !ink.isEmpty
        let ascent = hasInk ? max(ink.maxY, 0) : 0
        let descent = hasInk ? max(-ink.minY, 0) : 0
        return LayoutBox(
            origin: .zero,
            size: CGSize(width: width, height: ascent + descent),
            baseline: ascent,
            content: content,
            ink: hasInk ? CGRect(x: ink.minX, y: ascent - ink.maxY, width: ink.width, height: ink.height) : .null,
            italicCorrection: italicCorrection
        )
    }

    private func emptyBox(width: CGFloat) -> LayoutBox {
        LayoutBox(origin: .zero, size: CGSize(width: width, height: 0), baseline: 0, content: .container([]))
    }

    // MARK: Boxes

    /// A child to place with its baseline `shift` above the parent's baseline.
    private struct Placed {
        var box: LayoutBox
        var x: CGFloat
        var shift: CGFloat
    }

    /// Stacks placed children on a common baseline. Width defaults to the
    /// right edge of the widest child.
    private func vbox(_ placed: [Placed], width: CGFloat? = nil) -> LayoutBox {
        guard !placed.isEmpty else { return emptyBox(width: width ?? 0) }
        let ascent = max(0, placed.map { $0.box.ascent + $0.shift }.max() ?? 0)
        let descent = max(0, placed.map { $0.box.descent - $0.shift }.max() ?? 0)
        var children: [LayoutBox] = []
        var ink = CGRect.null
        var right: CGFloat = 0
        for item in placed {
            var child = item.box
            child.origin = CGPoint(x: item.x, y: ascent - item.shift - item.box.ascent)
            if !child.ink.isNull { ink = ink.union(child.ink.offsetBy(dx: child.origin.x, dy: child.origin.y)) }
            right = max(right, item.x + item.box.size.width)
            children.append(child)
        }
        return LayoutBox(
            origin: .zero,
            size: CGSize(width: width ?? right, height: ascent + descent),
            baseline: ascent,
            content: .container(children),
            ink: ink
        )
    }

    /// Children already positioned along x, aligned on their baselines.
    private func hbox(_ children: [LayoutBox], width: CGFloat) -> LayoutBox {
        vbox(children.map { Placed(box: $0, x: $0.origin.x, shift: 0) }, width: width)
    }

    /// A filled rule of `thickness` whose top edge is `top` above the baseline.
    private func rule(width: CGFloat, thickness: CGFloat) -> LayoutBox {
        LayoutBox(
            origin: .zero,
            size: CGSize(width: width, height: thickness),
            baseline: thickness,
            content: .line(CGPoint(x: 0, y: thickness / 2), CGPoint(x: width, y: thickness / 2), thickness),
            ink: CGRect(x: 0, y: 0, width: width, height: thickness)
        )
    }

    /// Centres a box on the math axis.
    private func centeredOnAxis(_ box: LayoutBox, _ style: Style) -> Placed {
        let axis = c.axisHeight * style.size
        return Placed(box: box, x: 0, shift: axis - (box.ascent - box.descent) / 2)
    }

    // MARK: Fractions

    private func fraction(_ numerator: [MathNode], _ denominator: [MathNode], _ style: Style, hasRule: Bool) -> LayoutBox {
        let size = style.size
        let num = list(numerator, style.numerator)
        let den = list(denominator, style.denominator)
        let axis = c.axisHeight * size
        let display = style.isDisplay

        var numShift: CGFloat
        var denShift: CGFloat
        let thickness = hasRule ? c.fractionRuleThickness * size : 0
        if hasRule {
            // Text style uses TeX's shifts (num2, denom2): STIX's own text
            // shifts equal its display ones and set an inline a/b 1.5 em tall,
            // pushing prose lines apart. The gap minimums below still hold.
            numShift = (display ? c.fractionNumeratorDisplayStyleShiftUp : 0.394) * size
            denShift = (display ? c.fractionDenominatorDisplayStyleShiftDown : 0.345) * size
            let numGap = (display ? c.fractionNumDisplayStyleGapMin : c.fractionNumeratorGapMin) * size
            let denGap = (display ? c.fractionDenomDisplayStyleGapMin : c.fractionDenominatorGapMin) * size
            numShift += max(0, numGap - ((numShift - num.descent) - (axis + thickness / 2)))
            denShift += max(0, denGap - ((axis - thickness / 2) - (den.ascent - denShift)))
        } else {
            numShift = (display ? c.stackTopDisplayStyleShiftUp : c.stackTopShiftUp) * size
            denShift = (display ? c.stackBottomDisplayStyleShiftDown : c.stackBottomShiftDown) * size
            let gapMin = (display ? c.stackDisplayStyleGapMin : c.stackGapMin) * size
            let gap = (numShift - num.descent) - (den.ascent - denShift)
            if gap < gapMin {
                numShift += (gapMin - gap) / 2
                denShift += (gapMin - gap) / 2
            }
        }

        // TeX's null delimiter space on each side keeps a bar off its neighbours.
        let padding = 0.12 * size
        let content = max(num.size.width, den.size.width)
        let width = content + 2 * padding
        var placed = [
            Placed(box: num, x: (width - num.size.width) / 2, shift: numShift),
            Placed(box: den, x: (width - den.size.width) / 2, shift: -denShift),
        ]
        if hasRule {
            let bar = rule(width: content, thickness: thickness)
            placed.append(Placed(box: bar, x: padding, shift: axis - thickness / 2))
        }
        return vbox(placed, width: width)
    }

    // MARK: Scripts

    private func scripts(base: LayoutBox, baseIsCharacter: Bool, sup: [MathNode]?, sub: [MathNode]?, _ style: Style) -> LayoutBox {
        let size = style.size
        let supBox = sup.map { list($0, style.superscript) }
        let subBox = sub.map { list($0, style.subscript) }
        let scriptSize = style.superscript.size

        var supShift: CGFloat = 0
        var subShift: CGFloat = 0
        if let supBox {
            supShift = (style.cramped ? c.superscriptShiftUpCramped : c.superscriptShiftUp) * size
            if !baseIsCharacter {
                supShift = max(supShift, base.ascent - c.superscriptBaselineDropMax * scriptSize)
            }
            supShift = max(supShift, supBox.descent + c.superscriptBottomMin * size)
        }
        if let subBox {
            subShift = c.subscriptShiftDown * size
            if !baseIsCharacter {
                subShift = max(subShift, base.descent + c.subscriptBaselineDropMin * scriptSize)
            }
            subShift = max(subShift, subBox.ascent - c.subscriptTopMax * size)
        }
        if let supBox, let subBox {
            let gap = (supShift - supBox.descent) - (subBox.ascent - subShift)
            let gapMin = c.subSuperscriptGapMin * size
            if gap < gapMin {
                subShift += gapMin - gap
                let lift = c.superscriptBottomMaxWithSubscript * size - (supShift - supBox.descent)
                if lift > 0 {
                    supShift += lift
                    subShift -= lift
                }
            }
        }

        var placed = [Placed(box: base, x: 0, shift: 0)]
        var right = base.size.width
        if let supBox {
            let x = base.size.width + base.italicCorrection
            placed.append(Placed(box: supBox, x: x, shift: supShift))
            right = max(right, x + supBox.size.width)
        }
        if let subBox {
            placed.append(Placed(box: subBox, x: base.size.width, shift: -subShift))
            right = max(right, base.size.width + subBox.size.width)
        }
        return vbox(placed, width: right + c.spaceAfterScript * size)
    }

    // MARK: Radicals

    private func radical(index: [MathNode]?, radicand: [MathNode], _ style: Style) -> LayoutBox {
        let size = style.size
        let body = list(radicand, style.crampedStyle)
        let thickness = c.radicalRuleThickness * size
        var gap = (style.isDisplay ? c.radicalDisplayStyleVerticalGap : c.radicalVerticalGap) * size
        let needed = body.ascent + body.descent + gap + thickness

        let sign = verticalStretch("\u{221A}", height: needed, size: size)
        let signHeight = sign.size.height
        if signHeight > needed { gap += (signHeight - needed) / 2 }
        // The sign's top is the overbar's top.
        let top = body.ascent + gap + thickness
        let signShift = top - sign.ascent

        var placed: [Placed] = []
        var x: CGFloat = 0
        if let index, !index.isEmpty {
            let degree = list(index, style.with(.scriptScript))
            let kernBefore = c.radicalKernBeforeDegree * size
            let kernAfter = c.radicalKernAfterDegree * size
            let raise = c.radicalDegreeBottomRaise * signHeight
            placed.append(Placed(box: degree, x: kernBefore, shift: (top - signHeight) + raise + degree.descent))
            x = max(0, kernBefore + degree.size.width + kernAfter)
        }
        placed.append(Placed(box: sign, x: x, shift: signShift))
        x += sign.size.width
        let bar = rule(width: body.size.width, thickness: thickness)
        placed.append(Placed(box: bar, x: x, shift: top - thickness))
        placed.append(Placed(box: body, x: x, shift: 0))
        // Room above the bar so a radical does not touch what is above it.
        placed.append(Placed(box: emptyBox(width: 0), x: 0, shift: top + c.radicalExtraAscender * size))
        return vbox(placed, width: x + body.size.width)
    }

    // MARK: Delimiters

    /// A body between two delimiters tall enough to cover it, centred on the
    /// axis. TeX lets `\left`/`\right` fall short: 90.1% of the body, or
    /// within 0.5 em of it. A binomial's parentheses cover it fully.
    /// `padding` (em) separates a matrix from its delimiters.
    private func delimited(
        _ body: LayoutBox,
        left: Delimiter,
        right: Delimiter,
        _ style: Style,
        shortfall: Bool = true,
        padding: CGFloat = 0
    ) -> LayoutBox {
        let size = style.size
        let axis = c.axisHeight * size
        let half = max(body.ascent - axis, body.descent + axis)
        let target = shortfall ? max(2 * half * 0.901, 2 * half - 0.5 * size) : 2 * half
        let leftBox = delimiterBox(left, covering: target, style)
        let rightBox = delimiterBox(right, covering: target, style)
        let pad = padding * size
        let bodyX = leftBox.size.width + (left == .none ? 0 : pad)
        let rightX = bodyX + body.size.width + (right == .none ? 0 : pad)
        return vbox([
            Placed(box: leftBox, x: 0, shift: 0),
            Placed(box: body, x: bodyX, shift: 0),
            Placed(box: rightBox, x: rightX, shift: 0),
        ], width: rightX + rightBox.size.width)
    }

    /// One delimiter at least `height` tall, centred on the axis.
    private func delimiterBox(_ delimiter: Delimiter, covering height: CGFloat, _ style: Style) -> LayoutBox {
        let size = style.size
        guard delimiter != .none else { return emptyBox(width: 0.12 * size) }
        let glyph = verticalStretch(MathLayoutEngine.delimiterDisplayString(delimiter), height: height, size: size)
        return vbox([centeredOnAxis(glyph, style)])
    }

    /// The character's own glyph if it is tall enough, else the smallest
    /// size variant that is, else an assembly built to `height`.
    private func verticalStretch(_ character: String, height: CGFloat, size: CGFloat) -> LayoutBox {
        guard let first = character.first, let base = font.glyph(for: first) else {
            return text(character, Style(level: .text, baseSize: size, scales: c))
        }
        let natural = glyph(base, size: size)
        guard natural.size.height < height, let construction = font.verticalConstruction(base) else {
            return natural
        }
        var largest = natural
        for variant in construction.variants {
            let box = glyph(variant, size: size)
            if box.size.height >= height { return box }
            largest = box
        }
        guard !construction.assembly.isEmpty else { return largest }
        return assemble(construction.assembly, length: height, size: size, vertical: true)
    }

    private func horizontalStretch(_ character: String, width: CGFloat, size: CGFloat) -> LayoutBox {
        guard let first = character.first, let base = font.glyph(for: first) else {
            return text(character, Style(level: .text, baseSize: size, scales: c))
        }
        let natural = glyph(base, size: size)
        guard natural.size.width < width, let construction = font.horizontalConstruction(base) else {
            return natural
        }
        var largest = natural
        for variant in construction.variants {
            let box = glyph(variant, size: size)
            if box.size.width >= width { return box }
            largest = box
        }
        guard !construction.assembly.isEmpty else { return largest }
        return assemble(construction.assembly, length: width, size: size, vertical: false)
    }

    /// Builds a glyph assembly `length` long (OpenType MATH): repeat the
    /// extenders until the parts can reach it, then share the overlap evenly
    /// between joints within what each connector allows.
    private func assemble(_ parts: [MathFont.AssemblyPart], length: CGFloat, size: CGFloat, vertical: Bool) -> LayoutBox {
        let scale = size / font.unitsPerEm
        let minOverlap = font.minConnectorOverlap * scale
        let hasExtender = parts.contains(where: \.isExtender)
        var sequence: [MathFont.AssemblyPart] = []
        for repeats in 1 ... 64 {
            sequence = parts.flatMap { part in
                part.isExtender ? Array(repeating: part, count: repeats) : [part]
            }
            let total = sequence.reduce(0) { $0 + $1.fullAdvance * scale }
            let reach = total - CGFloat(max(sequence.count - 1, 0)) * minOverlap
            if reach >= length || !hasExtender { break }
        }

        let total = sequence.reduce(0) { $0 + $1.fullAdvance * scale }
        let joints = max(sequence.count - 1, 1)
        let wanted = (total - length) / CGFloat(joints)
        var offsets: [CGFloat] = []
        var cursor: CGFloat = 0
        for (index, part) in sequence.enumerated() {
            offsets.append(cursor)
            guard index + 1 < sequence.count else { break }
            let next = sequence[index + 1]
            let allowed = min(part.endConnector, next.startConnector) * scale
            let overlap = min(max(wanted, minOverlap), max(allowed, minOverlap))
            cursor += part.fullAdvance * scale - overlap
        }
        let extent = (offsets.last ?? 0) + (sequence.last?.fullAdvance ?? 0) * scale

        var placed: [Placed] = []
        for (part, offset) in zip(sequence, offsets) {
            let piece = glyph(part.glyph, size: size)
            if vertical {
                // Parts run bottom to top; each sits on its own ink bottom.
                placed.append(Placed(box: piece, x: 0, shift: offset + piece.descent))
            } else {
                placed.append(Placed(box: piece, x: offset, shift: 0))
            }
        }
        // A vertical assembly sits on the baseline; callers centre it.
        return vbox(placed, width: vertical ? nil : extent)
    }

    // MARK: Big operators

    private func bigOperator(_ kind: BigOpKind, limits: MathLimits?, _ style: Style) -> LayoutBox {
        let size = style.size
        if kind == .xrightarrow || kind == .xleftarrow {
            return extensibleArrow(kind, limits: limits, style)
        }

        let isIntegral = [.int, .iint, .iiint, .oint].contains(kind)
        let stacksLimits: Bool = switch (limits?.placement ?? .automatic, kind) {
        case (.stacked, _): true
        case (.beside, _): false
        case (.automatic, .int), (.automatic, .iint), (.automatic, .iiint), (.automatic, .oint),
             (.automatic, .log), (.automatic, .ln), (.automatic, .sin), (.automatic, .cos),
             (.automatic, .tan), (.automatic, .exp): false
        case (.automatic, _): style.isDisplay
        }

        var op: LayoutBox
        if MathLayoutEngine.isTextOperator(kind) {
            op = text(MathLayoutEngine.bigOperatorDisplayString(kind), style)
            op.italicCorrection = 0
        } else {
            let symbol = MathLayoutEngine.bigOperatorDisplayString(kind)
            var glyphBox = text(symbol, style)
            if style.isDisplay, let first = symbol.first, let base = font.glyph(for: first),
               let construction = font.verticalConstruction(base) {
                // The first display size at least DisplayOperatorMinHeight tall,
                // else the largest there is.
                let minimum = c.displayOperatorMinHeight * size
                for variant in construction.variants.dropFirst() {
                    glyphBox = glyph(variant, size: size)
                    if glyphBox.size.height >= minimum { break }
                }
            }
            op = vbox([centeredOnAxis(glyphBox, style)])
            op.italicCorrection = glyphBox.italicCorrection
        }

        guard limits?.lower?.isEmpty == false || limits?.upper?.isEmpty == false else { return op }
        guard stacksLimits else {
            var sideBase = op
            if !isIntegral { sideBase.italicCorrection = 0 }
            // A function name takes scripts like a letter, so the exponent of
            // \sin sits where the exponent of \cos does despite the i's dot.
            return scripts(
                base: sideBase,
                baseIsCharacter: MathLayoutEngine.isTextOperator(kind),
                sup: limits?.upper,
                sub: limits?.lower,
                style
            )
        }

        return limitStack(op, upper: limits?.upper, lower: limits?.lower, style)
    }

    /// Limits centred over and under a base, at TeX's limit gaps: big
    /// operators in display style, \overset and kin, and labelled braces.
    /// An italic base's limits shift by half its slant, each its own way.
    private func limitStack(_ op: LayoutBox, upper upperNodes: [MathNode]?, lower lowerNodes: [MathNode]?, _ style: Style) -> LayoutBox {
        let size = style.size
        let lower = lowerNodes.flatMap { $0.isEmpty ? nil : list($0, style.subscript) }
        let upper = upperNodes.flatMap { $0.isEmpty ? nil : list($0, style.superscript) }
        let width = max(op.size.width, upper?.size.width ?? 0, lower?.size.width ?? 0)
        let correction = op.italicCorrection
        var placed = [Placed(box: op, x: (width - op.size.width) / 2, shift: 0)]
        if let upper {
            let gap = max(c.upperLimitGapMin * size, c.upperLimitBaselineRiseMin * size - upper.descent)
            placed.append(Placed(
                box: upper,
                x: (width - upper.size.width) / 2 + correction / 2,
                shift: op.ascent + gap + upper.descent
            ))
        }
        if let lower {
            let gap = max(c.lowerLimitGapMin * size, c.lowerLimitBaselineDropMin * size - lower.ascent)
            placed.append(Placed(
                box: lower,
                x: (width - lower.size.width) / 2 - correction / 2,
                shift: -(op.descent + gap + lower.ascent)
            ))
        }
        return vbox(placed, width: width)
    }

    /// `\xrightarrow[under]{over}`: an arrow stretched past its labels.
    private func extensibleArrow(_ kind: BigOpKind, limits: MathLimits?, _ style: Style) -> LayoutBox {
        let size = style.size
        let over = limits?.upper.flatMap { $0.isEmpty ? nil : list($0, style.superscript) }
        let under = limits?.lower.flatMap { $0.isEmpty ? nil : list($0, style.subscript) }
        let labelWidth = max(over?.size.width ?? 0, under?.size.width ?? 0)
        let arrow = horizontalStretch(
            MathLayoutEngine.bigOperatorDisplayString(kind),
            width: labelWidth + 0.6 * size,
            size: size
        )
        let width = max(arrow.size.width, labelWidth)
        var placed = [Placed(box: arrow, x: (width - arrow.size.width) / 2, shift: 0)]
        if let over {
            let gap = max(c.stretchStackGapAboveMin * size, c.stretchStackTopShiftUp * size - arrow.ascent - over.descent)
            placed.append(Placed(box: over, x: (width - over.size.width) / 2, shift: arrow.ascent + gap + over.descent))
        }
        if let under {
            let gap = max(c.stretchStackGapBelowMin * size, c.stretchStackBottomShiftDown * size - arrow.descent - under.ascent)
            placed.append(Placed(box: under, x: (width - under.size.width) / 2, shift: -(arrow.descent + gap + under.ascent)))
        }
        return vbox(placed, width: width)
    }

    // MARK: Accents

    private func accent(_ kind: MathAccentKind, base nodes: [MathNode], _ style: Style) -> LayoutBox {
        let size = style.size
        let base = list(nodes, style.crampedStyle)

        switch kind {
        case .overline:
            let thickness = c.overbarRuleThickness * size
            let bar = rule(width: base.size.width, thickness: thickness)
            let shift = base.ascent + c.overbarVerticalGap * size
            var result = vbox([
                Placed(box: base, x: 0, shift: 0),
                Placed(box: bar, x: 0, shift: shift),
                Placed(box: emptyBox(width: 0), x: 0, shift: shift + thickness + c.overbarExtraAscender * size),
            ], width: base.size.width)
            result.italicCorrection = base.italicCorrection
            return result
        case .underline:
            let thickness = c.underbarRuleThickness * size
            let bar = rule(width: base.size.width, thickness: thickness)
            let drop = base.descent + c.underbarVerticalGap * size + thickness
            return vbox([
                Placed(box: base, x: 0, shift: 0),
                Placed(box: bar, x: 0, shift: -drop),
            ], width: base.size.width)
        case .overbrace, .underbrace:
            let brace = horizontalStretch(kind == .overbrace ? "\u{23DE}" : "\u{23DF}", width: base.size.width, size: size)
            let x = (base.size.width - brace.size.width) / 2
            let gap = c.stretchStackGapAboveMin * size
            let shift = kind == .overbrace
                ? base.ascent + gap + brace.descent
                : -(base.descent + gap + brace.ascent)
            return vbox([
                Placed(box: base, x: max(0, -x), shift: 0),
                Placed(box: brace, x: max(0, x), shift: shift),
            ])
        default:
            break
        }

        let mark: String = switch kind {
        case .hat, .widehat: "\u{0302}"
        case .tilde, .widetilde: "\u{0303}"
        case .bar: "\u{0304}"
        case .vec: "\u{20D7}"
        case .dot: "\u{0307}"
        case .ddot: "\u{0308}"
        case .check: "\u{030C}"
        case .breve: "\u{0306}"
        default: "\u{0302}"
        }
        let accentBox: LayoutBox
        let accentGlyph = mark.first.flatMap { font.glyph(for: $0) }
        if kind == .widehat || kind == .widetilde {
            accentBox = horizontalStretch(mark, width: base.size.width, size: size)
        } else if let accentGlyph {
            accentBox = glyph(accentGlyph, size: size)
        } else {
            accentBox = text(mark, style)
        }

        // Centre the mark's attachment point over the base's.
        var baseAnchor = base.size.width / 2
        if nodes.count == 1, case .glyph(let string, _) = singleGlyphContent(base),
           let first = string.first, string.count == 1, let baseGlyph = font.glyph(for: first),
           let attachment = font.topAccentAttachment(baseGlyph) {
            baseAnchor = attachment * size
        }
        var accentAnchor = accentBox.ink.isNull ? accentBox.size.width / 2 : accentBox.ink.midX
        if case .glyphID(let id, _) = accentBox.content, let attachment = font.topAccentAttachment(id) {
            accentAnchor = attachment * size
        }
        // Marks are drawn to sit over an x-height base; raise them over taller
        // ones. The outline stroke grows the base up and the mark down by half
        // its width each, so the mark also rises by one stroke to keep the
        // font's gap.
        let raise = max(0, base.ascent - c.accentBaseHeight * size) + font.strokeWidth * size
        var result = vbox([
            Placed(box: base, x: 0, shift: 0),
            Placed(box: accentBox, x: baseAnchor - accentAnchor, shift: raise),
        ], width: base.size.width)
        result.italicCorrection = base.italicCorrection
        return result
    }

    /// The glyph content of a box that is one glyph, possibly wrapped.
    private func singleGlyphContent(_ box: LayoutBox) -> LayoutContent? {
        switch box.content {
        case .glyph: return box.content
        case .container(let children) where children.count == 1: return singleGlyphContent(children[0])
        default: return nil
        }
    }

    // MARK: Grids

    private enum ColumnAlignment {
        case centered
        case left
        case alternatingRightLeft
    }

    /// Matrix-like rows. Each row is at least a strut tall (TeX arrays use
    /// 1.2 em rows) unless `strut` is off (\substack), plus `rowGap` em; the
    /// grid centres on the axis. A row's \tag moves out of its cells to a
    /// column of its own after the grid.
    private func grid(
        _ taggedRows: [[[MathNode]]],
        _ style: Style,
        alignment: ColumnAlignment,
        columnGap: CGFloat,
        rowGap: CGFloat,
        strut: Bool = true
    ) -> LayoutBox {
        guard !taggedRows.isEmpty else { return emptyBox(width: 0) }
        let size = style.size
        func isTag(_ node: MathNode) -> Bool { if case .tag = node { true } else { false } }
        let rows = taggedRows.map { row in row.map { $0.filter { !isTag($0) } } }
        let tags: [LayoutBox?] = taggedRows.map { row in
            let labels = row.flatMap { cell in
                cell.flatMap { node -> [MathNode] in
                    guard case .tag(let body, let parenthesized) = node else { return [] }
                    return tagLabel(body, parenthesized: parenthesized)
                }
            }
            return labels.isEmpty ? nil : list(labels, style)
        }
        let columns = rows.map(\.count).max() ?? 0
        let cells: [[LayoutBox]] = rows.map { row in
            (0 ..< columns).map { column in
                guard column < row.count else { return emptyBox(width: 0) }
                let rightSide = alignment == .alternatingRightLeft && !column.isMultiple(of: 2)
                return list(row[column], style, leadingOrd: rightSide)
            }
        }

        var widths = [CGFloat](repeating: 0, count: columns)
        for row in cells {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.size.width) }
        }
        let strutAscent = strut ? 0.85 * size : 0
        let strutDescent = strut ? 0.35 * size : 0
        let gaps: [CGFloat] = (0 ..< columns).map { column in
            guard column + 1 < columns else { return 0 }
            if alignment == .alternatingRightLeft { return column.isMultiple(of: 2) ? 0 : columnGap * size }
            return columnGap * size
        }

        var placed: [Placed] = []
        var y: CGFloat = 0
        var rowBaselines: [CGFloat] = []
        let cellsWidth = widths.reduce(0, +) + gaps.reduce(0, +)
        let tagWidth = tags.compactMap { $0?.size.width }.max()
        let tagX = cellsWidth + Self.tagGap * size
        for (row, tag) in zip(cells, tags) {
            let ascent = max(strutAscent, row.map(\.ascent).max() ?? 0, tag?.ascent ?? 0)
            let descent = max(strutDescent, row.map(\.descent).max() ?? 0, tag?.descent ?? 0)
            if !rowBaselines.isEmpty { y += rowGap * size }
            y += ascent
            rowBaselines.append(y)
            var x: CGFloat = 0
            for (column, cell) in row.enumerated() {
                let offset: CGFloat = switch alignment {
                case .centered: (widths[column] - cell.size.width) / 2
                case .left: 0
                case .alternatingRightLeft: column.isMultiple(of: 2) ? widths[column] - cell.size.width : 0
                }
                placed.append(Placed(box: cell, x: x + offset, shift: -y))
                x += widths[column] + gaps[column]
            }
            if let tag, let tagWidth {
                placed.append(Placed(box: tag, x: tagX + tagWidth - tag.size.width, shift: -y))
            }
            y += descent
        }
        let width = tagWidth.map { tagX + $0 } ?? cellsWidth
        // Rows hang below a baseline at the top; centre the whole on the axis.
        let axis = c.axisHeight * size
        let shiftToAxis = y / 2 + axis
        let lifted = placed.map { Placed(box: $0.box, x: $0.x, shift: $0.shift + shiftToAxis) }
        return vbox(lifted, width: width)
    }
}

// MARK: - Glyph metrics

/// Advance and ink of a text run, cached across layouts.
private enum GlyphMetrics {
    struct Measured {
        let width: CGFloat
        let ink: CGRect
    }

    private final class Entry: @unchecked Sendable {
        let value: Measured
        init(_ value: Measured) { self.value = value }
    }

    private final class Store: @unchecked Sendable {
        let cache: NSCache<NSString, Entry> = {
            let cache = NSCache<NSString, Entry>()
            cache.countLimit = 4_096
            cache.name = "org.oppi.MathLayoutEngine.glyphMetrics"
            return cache
        }()
    }

    private static let store = Store()

    static func measure(_ text: String, font: CTFont) -> Measured {
        let key = "\(CTFontGetSize(font))|\(text)" as NSString
        if let hit = store.cache.object(forKey: key) { return hit.value }
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let value = Measured(width: width, ink: ink)
        store.cache.setObject(Entry(value), forKey: key, cost: max(1, text.utf8.count))
        return value
    }
}

// MARK: - Math alphabets

/// Maps letters and digits to Unicode's mathematical alphanumerics, which the
/// math font draws: italic for variables, and the \mathbb … \mathtt faces.
enum MathAlphabet {
    static func map(_ string: String, style: MathFontStyle?, defaultItalic: Bool) -> String {
        var result = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            result.append(map(scalar, style: style, defaultItalic: defaultItalic))
        }
        return String(result)
    }

    private static func map(_ scalar: Unicode.Scalar, style: MathFontStyle?, defaultItalic: Bool) -> Unicode.Scalar {
        if scalar == "'" { return "\u{2032}" }
        let value = scalar.value
        let upper = (0x41 ... 0x5A).contains(value) ? value - 0x41 : nil
        let lower = (0x61 ... 0x7A).contains(value) ? value - 0x61 : nil
        let digit = (0x30 ... 0x39).contains(value) ? value - 0x30 : nil
        let greekLower = (0x3B1 ... 0x3C9).contains(value) ? value - 0x3B1 : nil
        let greekUpper = (0x391 ... 0x3A9).contains(value) ? value - 0x391 : nil

        func code(_ point: UInt32) -> Unicode.Scalar { Unicode.Scalar(point) ?? scalar }

        switch style {
        case nil, .italic?:
            guard defaultItalic || style == .italic else { return scalar }
            if let upper { return code(0x1D434 + upper) }
            if let lower { return lower == 7 ? "\u{210E}" : code(0x1D44E + lower) }
            if let greekLower { return code(0x1D6FC + greekLower) }
            switch value {
            case 0x3F5: return "\u{1D716}" // ϵ
            case 0x3D1: return "\u{1D717}" // ϑ
            case 0x3D5: return "\u{1D719}" // ϕ
            case 0x3F1: return "\u{1D71A}" // ϱ
            case 0x3D6: return "\u{1D71B}" // ϖ
            default: return scalar
            }
        case .roman?:
            return scalar
        case .boldItalic?:
            if let upper { return code(0x1D468 + upper) }
            if let lower { return code(0x1D482 + lower) }
            if let digit { return code(0x1D7CE + digit) }
            if let greekUpper { return code(0x1D71C + greekUpper) }
            if let greekLower { return code(0x1D736 + greekLower) }
            return scalar
        case .bold?:
            if let upper { return code(0x1D400 + upper) }
            if let lower { return code(0x1D41A + lower) }
            if let digit { return code(0x1D7CE + digit) }
            if let greekUpper { return code(0x1D6A8 + greekUpper) }
            if let greekLower { return code(0x1D6C2 + greekLower) }
            return scalar
        case .blackboard?:
            let exceptions: [UInt32: Unicode.Scalar] = [
                2: "\u{2102}", 7: "\u{210D}", 13: "\u{2115}", 15: "\u{2119}",
                16: "\u{211A}", 17: "\u{211D}", 25: "\u{2124}",
            ]
            if let upper { return exceptions[upper] ?? code(0x1D538 + upper) }
            if let lower { return code(0x1D552 + lower) }
            if let digit { return code(0x1D7D8 + digit) }
            return scalar
        case .calligraphic?:
            let exceptions: [UInt32: Unicode.Scalar] = [
                1: "\u{212C}", 4: "\u{2130}", 5: "\u{2131}", 7: "\u{210B}",
                8: "\u{2110}", 11: "\u{2112}", 12: "\u{2133}", 17: "\u{211B}",
            ]
            let lowerExceptions: [UInt32: Unicode.Scalar] = [4: "\u{212F}", 6: "\u{210A}", 14: "\u{2134}"]
            if let upper { return exceptions[upper] ?? code(0x1D49C + upper) }
            if let lower { return lowerExceptions[lower] ?? code(0x1D4B6 + lower) }
            return scalar
        case .fraktur?:
            let exceptions: [UInt32: Unicode.Scalar] = [
                2: "\u{212D}", 7: "\u{210C}", 8: "\u{2111}", 17: "\u{211C}", 25: "\u{2128}",
            ]
            if let upper { return exceptions[upper] ?? code(0x1D504 + upper) }
            if let lower { return code(0x1D51E + lower) }
            return scalar
        case .sansSerif?:
            if let upper { return code(0x1D5A0 + upper) }
            if let lower { return code(0x1D5BA + lower) }
            if let digit { return code(0x1D7E2 + digit) }
            return scalar
        case .typewriter?:
            if let upper { return code(0x1D670 + upper) }
            if let lower { return code(0x1D68A + lower) }
            if let digit { return code(0x1D7F6 + digit) }
            return scalar
        }
    }
}
