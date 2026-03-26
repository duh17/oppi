// MARK: - Core AST

/// A node in the math expression tree.
///
/// Designed for a two-phase pipeline: parse → layout → draw.
/// The parser produces `[MathNode]`; the layout engine (future) converts
/// to positioned boxes. All types are value types, `Equatable` and `Sendable`.
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
    case fraction(numerator: [MathNode], denominator: [MathNode])

    /// base^{exponent}
    case superscript(base: [MathNode], exponent: [MathNode])

    /// base_{index}
    case `subscript`(base: [MathNode], index: [MathNode])

    /// base_{sub}^{sup} — combined sub and superscript
    case subSuperscript(base: [MathNode], sub: [MathNode], sup: [MathNode])

    /// \sqrt[index]{radicand}
    case sqrt(index: [MathNode]?, radicand: [MathNode])

    /// Brace group {a + b}
    case group([MathNode])

    /// \left( ... \right)
    case leftRight(left: Delimiter, right: Delimiter, body: [MathNode])

    /// \begin{pmatrix} a & b \\ c & d \end{pmatrix}
    case matrix(rows: [[[MathNode]]], style: MatrixStyle)

    /// \text{...}
    case text(String)

    /// Whitespace commands: \, \; \: \quad \qquad \! \<space>
    case space(MathSpace)

    /// \hat{x}, \vec{v}, \overline{AB}
    case accent(MathAccentKind, base: [MathNode])

    /// \mathbb{R}, \mathcal{L}, etc.
    case font(MathFontStyle, body: [MathNode])

    /// \sum, \prod, \int, \lim — with optional limits
    case bigOperator(BigOpKind, limits: MathLimits?)

    /// \begin{cases} ... \end{cases} and other named environments
    case environment(String, rows: [[[MathNode]]])
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
}

/// Limits for big operators.
struct MathLimits: Equatable, Sendable {
    let lower: [MathNode]?
    let upper: [MathNode]?
}
