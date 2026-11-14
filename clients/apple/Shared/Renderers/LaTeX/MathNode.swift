// MARK: - Core AST

/// A node in the math expression tree.
///
/// Designed for a two-phase pipeline: parse → layout → draw.
/// The parser produces `[MathNode]`; `MathLayoutEngine` converts them to
/// positioned boxes. All types are value types, `Equatable` and `Sendable`.
enum MathNode: Equatable, Sendable {
    /// Numeric literal: "3", "42", "3.14"
    case number(String)

    /// Single-letter variable: "x", "y"
    case variable(String)

    /// Binary or unary operator: +, -, \times, etc.
    case `operator`(MathOperator)

    /// Named symbol: \alpha, \infty, etc.
    case symbol(MathSymbol)

    /// \frac{numerator}{denominator}
    case fraction(numerator: [Self], denominator: [Self])

    /// \binom{top}{bottom}: a stack without a bar, in parentheses.
    case binomial(top: [Self], bottom: [Self])

    /// base^{exponent}
    case superscript(base: [Self], exponent: [Self])

    /// base_{index}
    case `subscript`(base: [Self], index: [Self])

    /// base_{sub}^{sup} — combined sub and superscript
    case subSuperscript(base: [Self], sub: [Self], sup: [Self])

    /// \sqrt[index]{radicand}
    case sqrt(index: [Self]?, radicand: [Self])

    /// Brace group {a + b}
    case group([Self])

    /// \left( ... \right)
    case leftRight(left: Delimiter, right: Delimiter, body: [Self])

    /// \begin{pmatrix} a & b \\ c & d \end{pmatrix}
    case matrix(rows: [[[Self]]], style: MatrixStyle)

    /// \text{...}
    case text(String)

    /// Whitespace commands: \, \; \: \quad \qquad \! \<space>
    case space(MathSpace)

    /// \hat{x}, \vec{v}, \overline{AB}
    case accent(MathAccentKind, base: [Self])

    /// \mathbb{R}, \mathcal{L}, etc.
    case font(MathFontStyle, body: [Self])

    /// \sum, \prod, \int, \lim — with optional limits
    case bigOperator(BigOpKind, limits: MathLimits?)

    /// \begin{cases} ... \end{cases} and other named environments
    case environment(String, rows: [[[Self]]])

    /// \displaystyle and its kin: the rest of the enclosing list in that style.
    /// \dfrac and \tfrac wrap one fraction in this.
    case style(MathStyleKind, body: [Self])

    /// \bigl( … \Biggr): a delimiter at a fixed size, 1 (\big) to 4 (\Bigg).
    case sizedDelimiter(Delimiter, size: Int)

    /// \color{name} (the rest of its list) and \textcolor{name}{body}.
    case color(MathColor, body: [Self])

    /// \overset, \underset, \stackrel, and a brace with its label: a base
    /// with script-size material centred over and under it. `isRelation`
    /// spaces it as a relation (\stackrel); otherwise it takes its base's class.
    case stack(base: [Self], over: [Self]?, under: [Self]?, isRelation: Bool)

    /// \operatorname{…} and \operatorname*{…}: an upright name spaced as an
    /// operator. The starred form stacks its limits in display style.
    case operatorName([Self], limits: MathLimits?, starred: Bool)

    /// \substack{a \\ b}: centred rows for a limit.
    case substack(rows: [[Self]])

    /// \tag{…} (parenthesised) and \tag*{…}: a label set after its row.
    case tag([Self], parenthesized: Bool)

    /// \phantom and kin: the room their body takes, drawn empty.
    case phantom(MathPhantomKind, body: [Self])
}

/// Which of a phantom's dimensions are kept.
enum MathPhantomKind: String, Equatable, Sendable {
    case both = "phantom"
    case horizontal = "hphantom"
    case vertical = "vphantom"
}

/// The colours \color and \textcolor can name, as the theme's tokens.
///
/// Math draws on the reader's and chat's own backgrounds in light and dark
/// themes, so a literal colour (TeX's `blue` on a dark page, `yellow` on a
/// light one) could vanish. Each named or hex colour maps to the nearest of
/// the theme's accents instead, which every theme tunes for contrast; black,
/// white and colours with no clear hue draw as ordinary text.
enum MathColor: Equatable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple
    /// Gray: the theme's dimmed text colour.
    case dim
    /// Ordinary text colour (black, white, unknown names).
    case foreground

    /// xcolor's and KaTeX's common names. Unknown names draw as text.
    init(name: String) {
        switch name.lowercased() {
        case "red", "darkred", "crimson", "maroon", "brickred", "rubinered", "bittersweet", "salmon":
            self = .red
        case "orange", "darkorange", "brown", "burntorange", "redorange", "peach", "tan", "sepia":
            self = .orange
        case "yellow", "olive", "gold", "goldenrod", "dandelion", "apricot":
            self = .yellow
        case "green", "darkgreen", "lime", "forestgreen", "limegreen", "seagreen", "junglegreen", "emerald", "pinegreen", "olivegreen", "yellowgreen":
            self = .green
        case "cyan", "teal", "aqua", "turquoise", "tealblue", "skyblue", "processblue":
            self = .cyan
        case "blue", "darkblue", "navy", "navyblue", "royalblue", "midnightblue", "cornflowerblue", "cerulean", "bluegreen":
            self = .blue
        case "purple", "magenta", "violet", "pink", "fuchsia", "orchid", "plum", "mulberry", "lavender", "rhodamine", "redviolet", "blueviolet", "royalpurple", "darkorchid", "thistle":
            self = .purple
        case "gray", "grey", "darkgray", "darkgrey", "lightgray", "lightgrey", "silver":
            self = .dim
        default:
            self = .foreground
        }
    }

    /// The accent nearest a literal colour by hue. Colours without a clear
    /// hue are text, or dimmed text when mid-gray.
    init(red: Double, green: Double, blue: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let chroma = high - low
        guard chroma >= 0.15 else {
            self = high > 0.2 && high < 0.8 ? .dim : .foreground
            return
        }
        var hue: Double
        if high == red {
            hue = (green - blue) / chroma
        } else if high == green {
            hue = (blue - red) / chroma + 2
        } else {
            hue = (red - green) / chroma + 4
        }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<15, 335...: self = .red
        case ..<45: self = .orange
        case ..<70: self = .yellow
        case ..<160: self = .green
        case ..<195: self = .cyan
        case ..<255: self = .blue
        default: self = .purple
        }
    }

    /// `#RRGGBB`, `RRGGBB` or `#RGB`; nil when not hex.
    init?(hex: String) {
        var digits = Substring(hex)
        if digits.first == "#" { digits = digits.dropFirst() }
        if digits.count == 3 { digits = Substring(digits.flatMap { [$0, $0] }) }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// TeX's four math styles, as \displaystyle … \scriptscriptstyle name them.
enum MathStyleKind: String, Equatable, Sendable {
    case display = "displaystyle"
    case text = "textstyle"
    case script = "scriptstyle"
    case scriptScript = "scriptscriptstyle"
}

// MARK: - Supporting Enums

/// Binary and prefix operators.
enum MathOperator: String, Equatable, Sendable {
    // Arithmetic
    case plus = "+"
    case minus = "-"
    case times = "\\times"
    case div = "\\div"
    case cdot = "\\cdot"
    case pm = "\\pm"
    case mp = "\\mp"
    case star = "*"

    // Relations
    case equal = "="
    case lessThan = "<"
    case greaterThan = ">"
    case leq = "\\leq"
    case geq = "\\geq"
    case neq = "\\neq"
    case approx = "\\approx"
    case equiv = "\\equiv"
    case sim = "\\sim"
    case propto = "\\propto"
    case mid = "\\mid"
    case `in` = "\\in"
    case subset = "\\subset"
    case supset = "\\supset"
    case subseteq = "\\subseteq"
    case supseteq = "\\supseteq"
    case cup = "\\cup"
    case cap = "\\cap"
    case to = "\\to"
    case rightarrow = "\\rightarrow"
    case leftarrow = "\\leftarrow"
    case mapsto = "\\mapsto"
    case iff = "\\iff"
    case doubleRightarrow = "\\Rightarrow"
    case doubleLeftarrow = "\\Leftarrow"
    case doubleLeftrightarrow = "\\Leftrightarrow"
    case leftrightarrow = "\\leftrightarrow"
    case notin = "\\notin"
    case perp = "\\perp"
    case ll = "\\ll"
    case gg = "\\gg"
    case longrightarrow = "\\longrightarrow"
    case longleftarrow = "\\longleftarrow"
    case longleftrightarrow = "\\longleftrightarrow"
    case doubleLongRightarrow = "\\Longrightarrow"
    case doubleLongLeftarrow = "\\Longleftarrow"
    case doubleLongLeftrightarrow = "\\Longleftrightarrow"
    case longmapsto = "\\longmapsto"
    // Binary
    case setminus = "\\setminus"
    case circ = "\\circ"
    case oplus = "\\oplus"
    case otimes = "\\otimes"
    case wedge = "\\wedge"
    case vee = "\\vee"
    case colon = ":"
    case comma = ","
    case semicolon = ";"
    case bang = "!"
}

/// Named symbols (Greek letters, special constants, etc.).
enum MathSymbol: String, Equatable, Sendable {
    // Lowercase Greek
    case alpha = "\\alpha"
    case beta = "\\beta"
    case gamma = "\\gamma"
    case delta = "\\delta"
    case epsilon = "\\epsilon"
    case varepsilon = "\\varepsilon"
    case zeta = "\\zeta"
    case eta = "\\eta"
    case theta = "\\theta"
    case vartheta = "\\vartheta"
    case iota = "\\iota"
    case kappa = "\\kappa"
    case lambda = "\\lambda"
    case mu = "\\mu"
    case nu = "\\nu"
    case xi = "\\xi"
    case pi = "\\pi"
    case rho = "\\rho"
    case varrho = "\\varrho"
    case sigma = "\\sigma"
    case varsigma = "\\varsigma"
    case tau = "\\tau"
    case upsilon = "\\upsilon"
    case phi = "\\phi"
    case varphi = "\\varphi"
    case chi = "\\chi"
    case psi = "\\psi"
    case omega = "\\omega"

    // Uppercase Greek
    case capitalGamma = "\\Gamma"
    case capitalDelta = "\\Delta"
    case capitalTheta = "\\Theta"
    case capitalLambda = "\\Lambda"
    case capitalXi = "\\Xi"
    case capitalPi = "\\Pi"
    case capitalSigma = "\\Sigma"
    case capitalUpsilon = "\\Upsilon"
    case capitalPhi = "\\Phi"
    case capitalPsi = "\\Psi"
    case capitalOmega = "\\Omega"

    // Special symbols
    case infty = "\\infty"
    case partial = "\\partial"
    case nabla = "\\nabla"
    case forall = "\\forall"
    case exists = "\\exists"
    case neg = "\\neg"
    case ell = "\\ell"
    case hbar = "\\hbar"
    case emptyset = "\\emptyset"
    case cdots = "\\cdots"
    case ldots = "\\ldots"
    case vdots = "\\vdots"
    case ddots = "\\ddots"
    case prime = "\\prime"
    case top = "\\top"
    case aleph = "\\aleph"
}

/// Delimiter symbols for \left / \right.
enum Delimiter: String, Equatable, Sendable {
    case paren = "("
    case closeParen = ")"
    case bracket = "["
    case closeBracket = "]"
    case brace = "\\{"
    case closeBrace = "\\}"
    case pipe = "|"
    case doublePipe = "\\|"
    case angle = "\\langle"
    case closeAngle = "\\rangle"
    case floor = "\\lfloor"
    case closeFloor = "\\rfloor"
    case ceil = "\\lceil"
    case closeCeil = "\\rceil"
    case none = "."
}

/// Matrix environment styles.
enum MatrixStyle: String, Equatable, Sendable {
    case plain = "matrix"          // no delimiters
    case parenthesized = "pmatrix" // ( )
    case bracketed = "bmatrix"     // [ ]
    case braced = "Bmatrix"        // { }
    case pipe = "vmatrix"          // | |
    case doublePipe = "Vmatrix"    // || ||
    case small = "smallmatrix"     // inline
}

/// Whitespace commands.
enum MathSpace: String, Equatable, Sendable {
    case thinSpace = "\\,"         // 3/18 em
    case mediumSpace = "\\:"       // 4/18 em
    case thickSpace = "\\;"        // 5/18 em
    case quad = "\\quad"           // 1 em
    case qquad = "\\qquad"        // 2 em
    case negThin = "\\!"           // -3/18 em
    case backslashSpace = "\\ "    // normal space
}

/// Accent kinds (above and below marks).
enum MathAccentKind: String, Equatable, Sendable {
    case hat = "\\hat"
    case bar = "\\bar"
    case vec = "\\vec"
    case dot = "\\dot"
    case ddot = "\\ddot"
    case tilde = "\\tilde"
    case overline = "\\overline"
    case underline = "\\underline"
    case widehat = "\\widehat"
    case widetilde = "\\widetilde"
    case overbrace = "\\overbrace"
    case underbrace = "\\underbrace"
    case check = "\\check"
    case breve = "\\breve"
}

/// Font style commands.
enum MathFontStyle: String, Equatable, Sendable {
    case blackboard = "\\mathbb"   // double-struck
    case calligraphic = "\\mathcal"
    case fraktur = "\\mathfrak"
    case roman = "\\mathrm"
    case bold = "\\mathbf"
    case italic = "\\mathit"
    case sansSerif = "\\mathsf"
    case typewriter = "\\mathtt"
    case boldItalic = "\\boldsymbol"
}

/// Big operator kinds.
enum BigOpKind: String, Equatable, Sendable {
    case sum = "\\sum"
    case prod = "\\prod"
    case coprod = "\\coprod"
    case int = "\\int"
    case iint = "\\iint"
    case iiint = "\\iiint"
    case oint = "\\oint"
    case bigcup = "\\bigcup"
    case bigcap = "\\bigcap"
    case bigoplus = "\\bigoplus"
    case bigotimes = "\\bigotimes"
    case lim = "\\lim"
    case sup = "\\sup"
    case inf = "\\inf"
    case min = "\\min"
    case max = "\\max"
    case det = "\\det"
    case log = "\\log"
    case ln = "\\ln"
    case sin = "\\sin"
    case cos = "\\cos"
    case tan = "\\tan"
    case exp = "\\exp"
    /// amsmath extensible arrow; limits are the over/under scripts.
    case xrightarrow = "\\xrightarrow"
    case xleftarrow = "\\xleftarrow"
}

/// Limits for big operators.
struct MathLimits: Equatable, Sendable {
    let lower: [MathNode]?
    let upper: [MathNode]?
    /// \limits or \nolimits after the operator; `.automatic` follows TeX's
    /// default for the operator and style.
    var placement: MathLimitPlacement = .automatic
}

enum MathLimitPlacement: Equatable, Sendable {
    case automatic
    case stacked
    case beside
}
