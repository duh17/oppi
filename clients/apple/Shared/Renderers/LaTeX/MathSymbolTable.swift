/// Central lookup tables for TeX command → AST enum mapping.
///
/// All command-to-enum resolution goes through this table.
/// The parser calls `MathSymbolTable.lookup(_:)` to classify a
/// `\command` token and determine how to handle it.
enum MathSymbolTable {

    /// Result of looking up a `\command` name.
    enum LookupResult: Equatable, Sendable {
        case symbol(MathSymbol)
        case `operator`(MathOperator)
        case bigOperator(BigOpKind)
        case accent(MathAccentKind)
        case font(MathFontStyle)
        case space(MathSpace)
        case delimiter(Delimiter)
        case fraction           // \frac
        case sqrt               // \sqrt
        case text               // \text
        case left               // \left
        case right              // \right
        case begin              // \begin
        case end                // \end
    }

    /// Look up a backslash command (without the leading backslash).
    ///
    /// Returns `nil` for unknown commands. The parser decides how to
    /// handle unknowns (typically: emit a symbol node or skip).
    static func lookup(_ command: String) -> LookupResult? {
        // Structural commands first (most frequent in parsing hot path)
        switch command {
        case "frac": return .fraction
        case "sqrt": return .sqrt
        case "text": return .text
        case "left": return .left
        case "right": return .right
        case "begin": return .begin
        case "end": return .end
        default: break
        }

        // Check each category
        if let op = operatorTable[command] { return .operator(op) }
        if let sym = symbolTable[command] { return .symbol(sym) }
        if let big = bigOperatorTable[command] { return .bigOperator(big) }
        if let acc = accentTable[command] { return .accent(acc) }
        if let fnt = fontTable[command] { return .font(fnt) }
        if let sp = spaceTable[command] { return .space(sp) }
        if let del = delimiterTable[command] { return .delimiter(del) }

        return nil
    }

    // MARK: - Operator Table

    private static let operatorTable: [String: MathOperator] = [
        "times": .times,
        "div": .div,
        "cdot": .cdot,
        "pm": .pm,
        "mp": .mp,
        "leq": .leq,
        "le": .leq,
        "geq": .geq,
        "ge": .geq,
        "neq": .neq,
        "ne": .neq,
        "approx": .approx,
        "equiv": .equiv,
        "sim": .sim,
        "in": .in,
        "subset": .subset,
        "supset": .supset,
        "subseteq": .subseteq,
        "supseteq": .supseteq,
        "cup": .cup,
        "cap": .cap,
        "to": .to,
        "rightarrow": .rightarrow,
        "leftarrow": .leftarrow,
        "mapsto": .mapsto,
    ]

    // MARK: - Symbol Table

    private static let symbolTable: [String: MathSymbol] = [
        // Lowercase Greek
        "alpha": .alpha,
        "beta": .beta,
        "gamma": .gamma,
        "delta": .delta,
        "epsilon": .epsilon,
        "varepsilon": .varepsilon,
        "zeta": .zeta,
        "eta": .eta,
        "theta": .theta,
        "vartheta": .vartheta,
        "iota": .iota,
        "kappa": .kappa,
        "lambda": .lambda,
        "mu": .mu,
        "nu": .nu,
        "xi": .xi,
        "pi": .pi,
        "rho": .rho,
        "varrho": .varrho,
        "sigma": .sigma,
        "varsigma": .varsigma,
        "tau": .tau,
        "upsilon": .upsilon,
        "phi": .phi,
        "varphi": .varphi,
        "chi": .chi,
        "psi": .psi,
        "omega": .omega,

        // Uppercase Greek
        "Gamma": .capitalGamma,
        "Delta": .capitalDelta,
        "Theta": .capitalTheta,
        "Lambda": .capitalLambda,
        "Xi": .capitalXi,
        "Pi": .capitalPi,
        "Sigma": .capitalSigma,
        "Upsilon": .capitalUpsilon,
        "Phi": .capitalPhi,
        "Psi": .capitalPsi,
        "Omega": .capitalOmega,

        // Special
        "infty": .infty,
        "partial": .partial,
        "nabla": .nabla,
        "forall": .forall,
        "exists": .exists,
        "neg": .neg,
        "ell": .ell,
        "hbar": .hbar,
        "emptyset": .emptyset,
        "cdots": .cdots,
        "ldots": .ldots,
        "vdots": .vdots,
        "ddots": .ddots,
        "prime": .prime,
    ]

    // MARK: - Big Operator Table

    private static let bigOperatorTable: [String: BigOpKind] = [
        "sum": .sum,
        "prod": .prod,
        "coprod": .coprod,
        "int": .int,
        "iint": .iint,
        "iiint": .iiint,
        "oint": .oint,
        "bigcup": .bigcup,
        "bigcap": .bigcap,
        "bigoplus": .bigoplus,
        "bigotimes": .bigotimes,
        "lim": .lim,
        "sup": .sup,
        "inf": .inf,
        "min": .min,
        "max": .max,
        "det": .det,
        "log": .log,
        "ln": .ln,
        "sin": .sin,
        "cos": .cos,
        "tan": .tan,
        "exp": .exp,
    ]

    // MARK: - Accent Table

    private static let accentTable: [String: MathAccentKind] = [
        "hat": .hat,
        "bar": .bar,
        "vec": .vec,
        "dot": .dot,
        "ddot": .ddot,
        "tilde": .tilde,
        "overline": .overline,
        "underline": .underline,
        "widehat": .widehat,
        "widetilde": .widetilde,
        "overbrace": .overbrace,
        "underbrace": .underbrace,
    ]

    // MARK: - Font Table

    private static let fontTable: [String: MathFontStyle] = [
        "mathbb": .blackboard,
        "mathcal": .calligraphic,
        "mathfrak": .fraktur,
        "mathrm": .roman,
        "mathbf": .bold,
        "mathit": .italic,
        "mathsf": .sansSerif,
        "mathtt": .typewriter,
    ]

    // MARK: - Space Table

    /// Space commands. Note: `\ ` (backslash-space) is handled by the tokenizer
    /// as a special case, since the "command" is just a single space.
    private static let spaceTable: [String: MathSpace] = [
        ",": .thinSpace,
        ":": .mediumSpace,
        ";": .thickSpace,
        "quad": .quad,
        "qquad": .qquad,
        "!": .negThin,
        " ": .backslashSpace,
    ]

    // MARK: - Delimiter Table

    private static let delimiterTable: [String: Delimiter] = [
        "{": .brace,
        "}": .closeBrace,
        "langle": .angle,
        "rangle": .closeAngle,
        "|": .pipe,
        "lVert": .doublePipe,
        "rVert": .doublePipe,
        "Vert": .doublePipe,
    ]
}
