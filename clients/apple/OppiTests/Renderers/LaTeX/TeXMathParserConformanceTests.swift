import Testing
@testable import Oppi

// SPEC: KaTeX Supported Functions (katex.org/docs/supported.html)
// COVERAGE:
// [x] Variables and numbers
// [x] Binary operators (+, -, \times, \div, \cdot, \pm, \mp)
// [x] Relations (=, <, >, \leq, \geq, \neq, \approx, \equiv, \sim)
// [x] Fractions (\frac)
// [x] Superscripts (^)
// [x] Subscripts (_)
// [x] Combined sub+superscript
// [x] Groups ({...})
// [x] Greek letters (lowercase + uppercase)
// [x] Parentheses/brackets — literal
// [x] \left / \right delimiters
// [x] Square roots (\sqrt, \sqrt[n]{...})
// [x] \text{...}
// [x] Big operators (\sum, \prod, \int, \lim) with limits
// [x] Matrices (pmatrix, bmatrix, vmatrix, Bmatrix, Vmatrix, matrix)
// [x] Cases environment
// [x] Accents (\hat, \bar, \vec, \dot, \tilde, \overline, \underline)
// [x] Font commands (\mathbb, \mathcal, \mathfrak, \mathrm, \mathbf)
// [x] Spaces (\, \; \: \quad \qquad \! \ )
// [x] Empty input
// [x] Complex real-world expressions

@Suite("TeXMathParser Conformance")
struct TeXMathParserConformanceTests {
    let parser = TeXMathParser()

    // MARK: - Variables and Numbers

    @Test func variablesAndNumbers() {
        #expect(parser.parse("x") == [.variable("x")])
        #expect(parser.parse("y") == [.variable("y")])
        #expect(parser.parse("3") == [.number("3")])
        #expect(parser.parse("42") == [.number("4"), .number("2")])
        // Each digit is a separate number node (TeX treats digits individually)
    }

    @Test func multipleVariables() {
        #expect(parser.parse("xy") == [.variable("x"), .variable("y")])
        #expect(parser.parse("abc") == [
            .variable("a"), .variable("b"), .variable("c"),
        ])
    }

    // MARK: - Binary Operators

    @Test func binaryOperators() {
        #expect(parser.parse("+") == [.operator(.plus)])
        #expect(parser.parse("-") == [.operator(.minus)])
        #expect(parser.parse("=") == [.operator(.equal)])

        let result = parser.parse("a+b")
        #expect(result == [
            .variable("a"), .operator(.plus), .variable("b"),
        ])
    }

    @Test func latexOperators() {
        #expect(parser.parse("\\times") == [.operator(.times)])
        #expect(parser.parse("\\div") == [.operator(.div)])
        #expect(parser.parse("\\cdot") == [.operator(.cdot)])
        #expect(parser.parse("\\pm") == [.operator(.pm)])
        #expect(parser.parse("\\mp") == [.operator(.mp)])
    }

    // MARK: - Relations

    @Test func relations() {
        #expect(parser.parse("\\leq") == [.operator(.leq)])
        #expect(parser.parse("\\geq") == [.operator(.geq)])
        #expect(parser.parse("\\neq") == [.operator(.neq)])
        #expect(parser.parse("\\approx") == [.operator(.approx)])
        #expect(parser.parse("\\equiv") == [.operator(.equiv)])
        #expect(parser.parse("\\sim") == [.operator(.sim)])
    }

    @Test func relationalExpression() {
        let result = parser.parse("a \\leq b")
        #expect(result == [
            .variable("a"), .operator(.leq), .variable("b"),
        ])
    }

    // MARK: - Fractions

    @Test func simpleFraction() {
        let result = parser.parse("\\frac{a}{b}")
        #expect(result == [
            .fraction(numerator: [.variable("a")], denominator: [.variable("b")]),
        ])
    }

    @Test func fractionWithExpressions() {
        let result = parser.parse("\\frac{x+1}{y-2}")
        #expect(result == [
            .fraction(
                numerator: [.variable("x"), .operator(.plus), .number("1")],
                denominator: [.variable("y"), .operator(.minus), .number("2")]
            ),
        ])
    }

    @Test func nestedFraction() {
        let result = parser.parse("\\frac{\\frac{a}{b}}{c}")
        #expect(result == [
            .fraction(
                numerator: [
                    .fraction(numerator: [.variable("a")], denominator: [.variable("b")]),
                ],
                denominator: [.variable("c")]
            ),
        ])
    }

    // MARK: - Superscripts

    @Test func simpleSuperscript() {
        let result = parser.parse("x^2")
        #expect(result == [
            .superscript(base: [.variable("x")], exponent: [.number("2")]),
        ])
    }

    @Test func bracedSuperscript() {
        let result = parser.parse("x^{2n}")
        #expect(result == [
            .superscript(
                base: [.variable("x")],
                exponent: [.number("2"), .variable("n")]
            ),
        ])
    }

    // MARK: - Subscripts

    @Test func simpleSubscript() {
        let result = parser.parse("x_i")
        #expect(result == [
            .subscript(base: [.variable("x")], index: [.variable("i")]),
        ])
    }

    @Test func bracedSubscript() {
        let result = parser.parse("x_{ij}")
        #expect(result == [
            .subscript(
                base: [.variable("x")],
                index: [.variable("i"), .variable("j")]
            ),
        ])
    }

    // MARK: - Combined Sub+Superscript

    @Test func subSuperscript() {
        let result = parser.parse("x_i^2")
        #expect(result == [
            .subSuperscript(
                base: [.variable("x")],
                sub: [.variable("i")],
                sup: [.number("2")]
            ),
        ])
    }

    @Test func superSubReversed() {
        // x^2_i should produce the same AST as x_i^2
        let result = parser.parse("x^2_i")
        #expect(result == [
            .subSuperscript(
                base: [.variable("x")],
                sub: [.variable("i")],
                sup: [.number("2")]
            ),
        ])
    }

    @Test func bracedSubSuperscript() {
        let result = parser.parse("x_{ij}^{2n}")
        #expect(result == [
            .subSuperscript(
                base: [.variable("x")],
                sub: [.variable("i"), .variable("j")],
                sup: [.number("2"), .variable("n")]
            ),
        ])
    }

    // MARK: - Groups

    @Test func simpleGroup() {
        let result = parser.parse("{a+b}")
        #expect(result == [
            .group([.variable("a"), .operator(.plus), .variable("b")]),
        ])
    }

    @Test func singletonGroup() {
        // {x} should unwrap to just x
        let result = parser.parse("{x}")
        #expect(result == [.variable("x")])
    }

    @Test func nestedGroup() {
        let result = parser.parse("{{a}}")
        #expect(result == [.variable("a")])
    }

    // MARK: - Greek Letters

    @Test func lowercaseGreek() {
        #expect(parser.parse("\\alpha") == [.symbol(.alpha)])
        #expect(parser.parse("\\beta") == [.symbol(.beta)])
        #expect(parser.parse("\\gamma") == [.symbol(.gamma)])
        #expect(parser.parse("\\delta") == [.symbol(.delta)])
        #expect(parser.parse("\\epsilon") == [.symbol(.epsilon)])
        #expect(parser.parse("\\zeta") == [.symbol(.zeta)])
        #expect(parser.parse("\\eta") == [.symbol(.eta)])
        #expect(parser.parse("\\theta") == [.symbol(.theta)])
        #expect(parser.parse("\\iota") == [.symbol(.iota)])
        #expect(parser.parse("\\kappa") == [.symbol(.kappa)])
        #expect(parser.parse("\\lambda") == [.symbol(.lambda)])
        #expect(parser.parse("\\mu") == [.symbol(.mu)])
        #expect(parser.parse("\\nu") == [.symbol(.nu)])
        #expect(parser.parse("\\xi") == [.symbol(.xi)])
        #expect(parser.parse("\\pi") == [.symbol(.pi)])
        #expect(parser.parse("\\rho") == [.symbol(.rho)])
        #expect(parser.parse("\\sigma") == [.symbol(.sigma)])
        #expect(parser.parse("\\tau") == [.symbol(.tau)])
        #expect(parser.parse("\\upsilon") == [.symbol(.upsilon)])
        #expect(parser.parse("\\phi") == [.symbol(.phi)])
        #expect(parser.parse("\\chi") == [.symbol(.chi)])
        #expect(parser.parse("\\psi") == [.symbol(.psi)])
        #expect(parser.parse("\\omega") == [.symbol(.omega)])
    }

    @Test func uppercaseGreek() {
        #expect(parser.parse("\\Gamma") == [.symbol(.capitalGamma)])
        #expect(parser.parse("\\Delta") == [.symbol(.capitalDelta)])
        #expect(parser.parse("\\Theta") == [.symbol(.capitalTheta)])
        #expect(parser.parse("\\Lambda") == [.symbol(.capitalLambda)])
        #expect(parser.parse("\\Xi") == [.symbol(.capitalXi)])
        #expect(parser.parse("\\Pi") == [.symbol(.capitalPi)])
        #expect(parser.parse("\\Sigma") == [.symbol(.capitalSigma)])
        #expect(parser.parse("\\Phi") == [.symbol(.capitalPhi)])
        #expect(parser.parse("\\Psi") == [.symbol(.capitalPsi)])
        #expect(parser.parse("\\Omega") == [.symbol(.capitalOmega)])
    }

    @Test func greekInExpression() {
        let result = parser.parse("\\alpha + \\beta")
        #expect(result == [
            .symbol(.alpha), .operator(.plus), .symbol(.beta),
        ])
    }

    // MARK: - Parentheses/Brackets (literal)

    @Test func literalParentheses() {
        let result = parser.parse("(x+y)")
        #expect(result == [
            .variable("("), .variable("x"), .operator(.plus),
            .variable("y"), .variable(")"),
        ])
    }

    @Test func literalBrackets() {
        let result = parser.parse("[a,b]")
        #expect(result == [
            .variable("["), .variable("a"), .operator(.comma),
            .variable("b"), .variable("]"),
        ])
    }

    // MARK: - Left/Right Delimiters

    @Test func leftRightParens() {
        let result = parser.parse("\\left( \\frac{1}{2} \\right)")
        #expect(result == [
            .leftRight(
                left: .paren,
                right: .closeParen,
                body: [
                    .fraction(numerator: [.number("1")], denominator: [.number("2")]),
                ]
            ),
        ])
    }

    @Test func leftRightBrackets() {
        let result = parser.parse("\\left[ x \\right]")
        #expect(result == [
            .leftRight(left: .bracket, right: .closeBracket, body: [.variable("x")]),
        ])
    }

    @Test func leftRightWithDot() {
        // \left. ... \right| — one invisible delimiter
        let result = parser.parse("\\left. x \\right|")
        #expect(result == [
            .leftRight(left: .none, right: .pipe, body: [.variable("x")]),
        ])
    }

    // MARK: - Square Roots

    @Test func simpleSquareRoot() {
        let result = parser.parse("\\sqrt{x}")
        #expect(result == [
            .sqrt(index: nil, radicand: [.variable("x")]),
        ])
    }

    @Test func squareRootWithIndex() {
        let result = parser.parse("\\sqrt[3]{x}")
        #expect(result == [
            .sqrt(index: [.number("3")], radicand: [.variable("x")]),
        ])
    }

    @Test func squareRootWithExpression() {
        let result = parser.parse("\\sqrt{a^2 + b^2}")
        #expect(result == [
            .sqrt(index: nil, radicand: [
                .superscript(base: [.variable("a")], exponent: [.number("2")]),
                .operator(.plus),
                .superscript(base: [.variable("b")], exponent: [.number("2")]),
            ]),
        ])
    }

    // MARK: - Text

    @Test func textCommand() {
        let result = parser.parse("\\text{for all }")
        #expect(result == [.text("for all ")])
    }

    @Test func textInExpression() {
        let result = parser.parse("x \\text{if} y")
        #expect(result == [
            .variable("x"), .text("if"), .variable("y"),
        ])
    }

    // MARK: - Big Operators

    @Test func sumWithLimits() {
        let result = parser.parse("\\sum_{i=0}^{n}")
        #expect(result == [
            .bigOperator(.sum, limits: MathLimits(
                lower: [.variable("i"), .operator(.equal), .number("0")],
                upper: [.variable("n")]
            )),
        ])
    }

    @Test func integralWithLimits() {
        let result = parser.parse("\\int_a^b")
        #expect(result == [
            .bigOperator(.int, limits: MathLimits(
                lower: [.variable("a")],
                upper: [.variable("b")]
            )),
        ])
    }

    @Test func sumWithBody() {
        let result = parser.parse("\\sum_{i=0}^{n} x_i")
        #expect(result == [
            .bigOperator(.sum, limits: MathLimits(
                lower: [.variable("i"), .operator(.equal), .number("0")],
                upper: [.variable("n")]
            )),
            .subscript(base: [.variable("x")], index: [.variable("i")]),
        ])
    }

    @Test func productOperator() {
        let result = parser.parse("\\prod_{k=1}^{n}")
        #expect(result == [
            .bigOperator(.prod, limits: MathLimits(
                lower: [.variable("k"), .operator(.equal), .number("1")],
                upper: [.variable("n")]
            )),
        ])
    }

    @Test func limOperator() {
        let result = parser.parse("\\lim_{n \\to \\infty}")
        #expect(result == [
            .bigOperator(.lim, limits: MathLimits(
                lower: [.variable("n"), .operator(.to), .symbol(.infty)],
                upper: nil
            )),
        ])
    }

    @Test func bigOperatorWithoutLimits() {
        let result = parser.parse("\\int f(x)")
        #expect(result == [
            .bigOperator(.int, limits: nil),
            .variable("f"),
            .variable("("),
            .variable("x"),
            .variable(")"),
        ])
    }

    @Test func trigFunctions() {
        #expect(parser.parse("\\sin") == [.bigOperator(.sin, limits: nil)])
        #expect(parser.parse("\\cos") == [.bigOperator(.cos, limits: nil)])
        #expect(parser.parse("\\tan") == [.bigOperator(.tan, limits: nil)])
        #expect(parser.parse("\\log") == [.bigOperator(.log, limits: nil)])
        #expect(parser.parse("\\ln") == [.bigOperator(.ln, limits: nil)])
        #expect(parser.parse("\\exp") == [.bigOperator(.exp, limits: nil)])
    }

    // MARK: - Matrices

    @Test func pmatrix() {
        let result = parser.parse("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
        #expect(result == [
            .matrix(rows: [
                [[.variable("a")], [.variable("b")]],
                [[.variable("c")], [.variable("d")]],
            ], style: .parenthesized),
        ])
    }

    @Test func bmatrix() {
        let result = parser.parse("\\begin{bmatrix} 1 & 0 \\\\ 0 & 1 \\end{bmatrix}")
        #expect(result == [
            .matrix(rows: [
                [[.number("1")], [.number("0")]],
                [[.number("0")], [.number("1")]],
            ], style: .bracketed),
        ])
    }

    @Test func vmatrix() {
        let result = parser.parse("\\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix}")
        #expect(result == [
            .matrix(rows: [
                [[.variable("a")], [.variable("b")]],
                [[.variable("c")], [.variable("d")]],
            ], style: .pipe),
        ])
    }

    @Test func matrixWithExpressions() {
        let result = parser.parse("\\begin{pmatrix} x+1 & y \\\\ z & w-2 \\end{pmatrix}")
        #expect(result == [
            .matrix(rows: [
                [
                    [.variable("x"), .operator(.plus), .number("1")],
                    [.variable("y")],
                ],
                [
                    [.variable("z")],
                    [.variable("w"), .operator(.minus), .number("2")],
                ],
            ], style: .parenthesized),
        ])
    }

    // MARK: - Cases Environment

    @Test func casesEnvironment() {
        let input = "\\begin{cases} a & \\text{if } x > 0 \\\\ b & \\text{otherwise} \\end{cases}"
        let result = parser.parse(input)
        #expect(result == [
            .environment("cases", rows: [
                [
                    [.variable("a")],
                    [.text("if "), .variable("x"), .operator(.greaterThan), .number("0")],
                ],
                [
                    [.variable("b")],
                    [.text("otherwise")],
                ],
            ]),
        ])
    }

    // MARK: - Accents

    @Test func hatAccent() {
        let result = parser.parse("\\hat{x}")
        #expect(result == [.accent(.hat, base: [.variable("x")])])
    }

    @Test func vecAccent() {
        let result = parser.parse("\\vec{v}")
        #expect(result == [.accent(.vec, base: [.variable("v")])])
    }

    @Test func overlineAccent() {
        let result = parser.parse("\\overline{AB}")
        #expect(result == [
            .accent(.overline, base: [.variable("A"), .variable("B")]),
        ])
    }

    @Test func barAccent() {
        let result = parser.parse("\\bar{x}")
        #expect(result == [.accent(.bar, base: [.variable("x")])])
    }

    @Test func dotAccent() {
        let result = parser.parse("\\dot{x}")
        #expect(result == [.accent(.dot, base: [.variable("x")])])
    }

    @Test func tildeAccent() {
        let result = parser.parse("\\tilde{x}")
        #expect(result == [.accent(.tilde, base: [.variable("x")])])
    }

    @Test func underlineAccent() {
        let result = parser.parse("\\underline{x}")
        #expect(result == [.accent(.underline, base: [.variable("x")])])
    }

    // MARK: - Font Commands

    @Test func mathbbFont() {
        let result = parser.parse("\\mathbb{R}")
        #expect(result == [.font(.blackboard, body: [.variable("R")])])
    }

    @Test func mathcalFont() {
        let result = parser.parse("\\mathcal{L}")
        #expect(result == [.font(.calligraphic, body: [.variable("L")])])
    }

    @Test func mathfrakFont() {
        let result = parser.parse("\\mathfrak{g}")
        #expect(result == [.font(.fraktur, body: [.variable("g")])])
    }

    @Test func mathrmFont() {
        let result = parser.parse("\\mathrm{d}")
        #expect(result == [.font(.roman, body: [.variable("d")])])
    }

    @Test func mathbfFont() {
        let result = parser.parse("\\mathbf{x}")
        #expect(result == [.font(.bold, body: [.variable("x")])])
    }

    // MARK: - Spaces

    @Test func spaceCommands() {
        #expect(parser.parse("\\,") == [.space(.thinSpace)])
        #expect(parser.parse("\\;") == [.space(.thickSpace)])
        #expect(parser.parse("\\:") == [.space(.mediumSpace)])
        #expect(parser.parse("\\quad") == [.space(.quad)])
        #expect(parser.parse("\\qquad") == [.space(.qquad)])
        #expect(parser.parse("\\!") == [.space(.negThin)])
    }

    @Test func backslashSpace() {
        let result = parser.parse("a\\ b")
        #expect(result == [
            .variable("a"), .space(.backslashSpace), .variable("b"),
        ])
    }

    @Test func spacesInExpression() {
        let result = parser.parse("a \\quad b \\, c")
        #expect(result == [
            .variable("a"), .space(.quad), .variable("b"),
            .space(.thinSpace), .variable("c"),
        ])
    }

    // MARK: - Empty Input

    @Test func emptyInput() {
        #expect(parser.parse("") == [])
    }

    @Test func whitespaceOnly() {
        #expect(parser.parse("   \t\n  ") == [])
    }

    // MARK: - Complex Real-World Expressions

    @Test func pythagoreanTheorem() {
        // x^2 + y^2 = z^2
        let result = parser.parse("x^2 + y^2 = z^2")
        #expect(result == [
            .superscript(base: [.variable("x")], exponent: [.number("2")]),
            .operator(.plus),
            .superscript(base: [.variable("y")], exponent: [.number("2")]),
            .operator(.equal),
            .superscript(base: [.variable("z")], exponent: [.number("2")]),
        ])
    }

    @Test func eulerIdentity() {
        // e^{i\pi} + 1 = 0
        let result = parser.parse("e^{i\\pi} + 1 = 0")
        #expect(result == [
            .superscript(
                base: [.variable("e")],
                exponent: [.variable("i"), .symbol(.pi)]
            ),
            .operator(.plus),
            .number("1"),
            .operator(.equal),
            .number("0"),
        ])
    }

    @Test func quadraticFormula() {
        // x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
        let result = parser.parse("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}")
        #expect(result == [
            .variable("x"),
            .operator(.equal),
            .fraction(
                numerator: [
                    .operator(.minus),
                    .variable("b"),
                    .operator(.pm),
                    .sqrt(index: nil, radicand: [
                        .superscript(base: [.variable("b")], exponent: [.number("2")]),
                        .operator(.minus),
                        .number("4"),
                        .variable("a"),
                        .variable("c"),
                    ]),
                ],
                denominator: [
                    .number("2"),
                    .variable("a"),
                ]
            ),
        ])
    }

    @Test func taylorSeries() {
        // \sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!}(x-a)^n
        // In TeX, ^n binds to the preceding atom (the closing paren)
        let result = parser.parse("\\sum_{n=0}^{\\infty} \\frac{f^{(n)}(a)}{n!}(x-a)^n")
        #expect(result == [
            .bigOperator(.sum, limits: MathLimits(
                lower: [.variable("n"), .operator(.equal), .number("0")],
                upper: [.symbol(.infty)]
            )),
            .fraction(
                numerator: [
                    .superscript(
                        base: [.variable("f")],
                        exponent: [.variable("("), .variable("n"), .variable(")")]
                    ),
                    .variable("("),
                    .variable("a"),
                    .variable(")"),
                ],
                denominator: [
                    .variable("n"),
                    .operator(.bang),
                ]
            ),
            .variable("("),
            .variable("x"),
            .operator(.minus),
            .variable("a"),
            .superscript(base: [.variable(")")], exponent: [.variable("n")]),
        ])
    }

    @Test func integralExpression() {
        // \int_a^b f(x) \, dx
        let result = parser.parse("\\int_a^b f(x) \\, dx")
        #expect(result == [
            .bigOperator(.int, limits: MathLimits(
                lower: [.variable("a")],
                upper: [.variable("b")]
            )),
            .variable("f"),
            .variable("("),
            .variable("x"),
            .variable(")"),
            .space(.thinSpace),
            .variable("d"),
            .variable("x"),
        ])
    }

    @Test func matrixDeterminant() {
        // \det \begin{vmatrix} a & b \\ c & d \end{vmatrix} = ad - bc
        let result = parser.parse(
            "\\det \\begin{vmatrix} a & b \\\\ c & d \\end{vmatrix} = ad - bc"
        )
        #expect(result == [
            .bigOperator(.det, limits: nil),
            .matrix(rows: [
                [[.variable("a")], [.variable("b")]],
                [[.variable("c")], [.variable("d")]],
            ], style: .pipe),
            .operator(.equal),
            .variable("a"),
            .variable("d"),
            .operator(.minus),
            .variable("b"),
            .variable("c"),
        ])
    }

    @Test func limitDefinition() {
        // \lim_{n \to \infty} \frac{1}{n} = 0
        let result = parser.parse("\\lim_{n \\to \\infty} \\frac{1}{n} = 0")
        #expect(result == [
            .bigOperator(.lim, limits: MathLimits(
                lower: [.variable("n"), .operator(.to), .symbol(.infty)],
                upper: nil
            )),
            .fraction(numerator: [.number("1")], denominator: [.variable("n")]),
            .operator(.equal),
            .number("0"),
        ])
    }

    @Test func setNotation() {
        // \mathbb{R} \subset \mathbb{C}
        let result = parser.parse("\\mathbb{R} \\subset \\mathbb{C}")
        #expect(result == [
            .font(.blackboard, body: [.variable("R")]),
            .operator(.subset),
            .font(.blackboard, body: [.variable("C")]),
        ])
    }

    @Test func gaussianIntegral() {
        // \int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}
        let result = parser.parse(
            "\\int_{-\\infty}^{\\infty} e^{-x^2} \\, dx = \\sqrt{\\pi}"
        )
        #expect(result == [
            .bigOperator(.int, limits: MathLimits(
                lower: [.operator(.minus), .symbol(.infty)],
                upper: [.symbol(.infty)]
            )),
            .superscript(
                base: [.variable("e")],
                exponent: [
                    .operator(.minus),
                    .superscript(base: [.variable("x")], exponent: [.number("2")]),
                ]
            ),
            .space(.thinSpace),
            .variable("d"),
            .variable("x"),
            .operator(.equal),
            .sqrt(index: nil, radicand: [.symbol(.pi)]),
        ])
    }
}
