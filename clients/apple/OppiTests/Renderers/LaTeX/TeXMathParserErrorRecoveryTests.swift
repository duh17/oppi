import Testing
@testable import Oppi

/// Error recovery tests for TeXMathParser.
///
/// The parser must never crash on malformed input. It should produce
/// partial results and skip over things it cannot understand.
@Suite("TeXMathParser Error Recovery")
struct TeXMathParserErrorRecoveryTests {
    let parser = TeXMathParser()

    // MARK: - No Crash on Malformed Input

    @Test func noCrashOnMalformedInputs() {
        RendererTestSupport.assertNoParseFailure(parser: parser, inputs: [
            // Unmatched braces
            "{",
            "}",
            "{{",
            "}}",
            "{{}",
            "{}}",
            "\\frac{a}",
            "\\frac{a}{b",
            "\\frac{a{b}",

            // Missing arguments
            "\\frac",
            "\\frac{}",
            "\\frac{}{}",
            "\\sqrt",
            "\\sqrt{}",
            "\\hat",
            "\\mathbb",
            "\\text",

            // Unmatched \left/\right
            "\\left(",
            "\\right)",
            "\\left( x",
            "\\left( x \\right",

            // Bare special characters
            "^",
            "_",
            "^ ^",
            "_ _",
            "^_",
            "_^",

            // Empty environments
            "\\begin{pmatrix}\\end{pmatrix}",
            "\\begin{}\\end{}",
            "\\begin{pmatrix}",
            "\\end{pmatrix}",

            // Unknown commands
            "\\nonexistent",
            "\\foo{bar}",
            "\\unknowncommand with args",

            // Deeply nested
            "{{{{{{{{{{x}}}}}}}}}}",
            "\\frac{\\frac{\\frac{\\frac{a}{b}}{c}}{d}}{e}",

            // Trailing backslash
            "x\\",

            // Random garbage
            "}{}{}{",
            "^_^_^_",
            "\\\\\\\\",

            // Unicode
            "\u{00e9}\u{00fc}\u{00f1}",
            "\u{03b1}", // literal alpha (U+03B1)
        ])
    }

    // MARK: - Validation diagnostics for graphical rendering

    @Test func xrightarrowBaselSumIsRenderable() {
        let result = parser.parseValidated(
            #"\sum_{n=1}^{N} \frac{1}{n^2} \;\xrightarrow{N\to\infty}\; \frac{\pi^2}{6}"#
        )
        #expect(result.diagnostics.isEmpty, "Unexpected diagnostics: \(result.diagnostics)")
        #expect(result.isRenderable)
    }

    @Test func xleftarrowOverscriptIsRenderable() {
        let result = parser.parseValidated(#"A \xleftarrow{f} B"#)
        #expect(result.diagnostics.isEmpty, "Unexpected diagnostics: \(result.diagnostics)")
        #expect(result.isRenderable)
    }

    @Test func validSupportedDisplaysHaveNoDiagnostics() {
        let valid = [
            "x",
            "x + y",
            "\\frac12",
            "\\frac{a}{b}",
            "\\left(x\\right)",
            "\\begin{aligned}a&=b\\\\c&=d\\end{aligned}",
            "\\begin{bmatrix}1&2\\\\3&4\\end{bmatrix}",
            "\\begin{cases}x,&x\\ge0\\\\-x,&x<0\\end{cases}",
        ]

        for source in valid {
            let result = parser.parseValidated(source)
            #expect(result.diagnostics.isEmpty, "Unexpected diagnostics for \(source): \(result.diagnostics)")
            #expect(result.isRenderable)
        }
    }

    @Test func escapedUnderscoreInsideMathrmIsRenderable() {
        let sources = [
            #"\mathrm{target\_burn} = R / T"#,
            #"\mathrm{recent\_burn} = \max(0, R_{\mathrm{prev}} - R_{\mathrm{now}}) / \mathrm{lookback}"#,
            #"\mathrm{pace\_ratio} = \mathrm{recent\_burn} \times T / R"#,
        ]
        for source in sources {
            let result = parser.parseValidated(source)
            #expect(result.diagnostics.isEmpty, "Unexpected diagnostics for \(source): \(result.diagnostics)")
            #expect(result.isRenderable)
        }
    }

    @Test func recoveredOrUnsupportedTeXIsNotRenderable() {
        let malformed: [(String, TeXMathDiagnostic)] = [
            ("\\frac{a}", .missingArgument(command: "frac", position: 2)),
            ("\\begin{matrix}1&2", .unclosedEnvironment("matrix")),
            ("\\left(x", .unmatchedLeft),
            ("x \\right)", .unmatchedRight),
            ("\\unsupported{x}", .unsupportedCommand("unsupported")),
            ("{x", .unclosedGroup),
            ("x}", .unmatchedClosingBrace),
            ("x + \\", .trailingBackslash),
        ]

        for (source, diagnostic) in malformed {
            let result = parser.parseValidated(source)
            #expect(result.diagnostics.contains(diagnostic), "Missing \(diagnostic) for \(source)")
            #expect(!result.isRenderable)
            #expect(!result.nodes.isEmpty || source == "x + \\")
        }
    }

    @Test func malformedScriptsAreRejectedBeforeGraphicalRendering() {
        let malformed: [(String, TeXMathDiagnostic)] = [
            ("^2", .missingScriptBase("^")),
            ("_i", .missingScriptBase("_")),
            ("(^2)", .missingScriptBase("^")),
            ("x^^2", .duplicateScript("^")),
            ("x^2^3", .duplicateScript("^")),
            ("x_i_j", .duplicateScript("_")),
            ("x^2_i^3", .duplicateScript("^")),
        ]

        for (source, diagnostic) in malformed {
            let result = parser.parseValidated(source)
            #expect(result.diagnostics.contains(diagnostic), "Missing \(diagnostic) for \(source): \(result.diagnostics)")
            #expect(!result.isRenderable)
        }
    }

    @Test func manualDelimiterSizingAndIffAreRenderable() {
        let valid = [
            #"\hat{h}_{n+1} = \hat{h}_n + \sum_{k \in C_n} \max\bigl(h_k,\, \alpha \cdot w^{-1} \cdot \ell(s_k)\bigr) + \delta_{\text{fence}} + \delta_{\text{mermaid}}"#,
            #"\text{stable}(n) \iff \forall i \le n,\; \lvert y_i^{(n+1)} - y_i^{(n)} \rvert = 0"#,
            #"\left\lvert x \right\rvert"#,
            #"\bigl\{x\bigr\}"#,
            #"\bigl\langle x \bigr\rangle"#,
            #"\bigl\|x\bigr\|"#,
        ]

        for source in valid {
            let result = parser.parseValidated(source)
            #expect(result.diagnostics.isEmpty, "Unexpected diagnostics for \(source): \(result.diagnostics)")
            #expect(result.isRenderable)
        }
    }

    @Test func sizedDelimiterPrefixesRequireSupportedDelimiters() {
        let malformed: [(String, TeXMathDiagnostic)] = [
            (#"\bigl\alpha"#, .unsupportedDelimiter(command: "bigl", delimiter: #"\alpha"#)),
            (#"\bigl"#, .missingDelimiter(command: "bigl")),
        ]

        for (source, diagnostic) in malformed {
            let result = parser.parseValidated(source)
            #expect(result.diagnostics.contains(diagnostic), "Missing \(diagnostic) for \(source): \(result.diagnostics)")
            #expect(!result.isRenderable)
        }
    }

    @Test func leftAndRightRequireSupportedDelimiters() {
        let malformed: [(String, TeXMathDiagnostic)] = [
            (#"\left x\right)"#, .unsupportedDelimiter(command: "left", delimiter: "x")),
            (#"\left\alpha x\right)"#, .unsupportedDelimiter(command: "left", delimiter: #"\alpha"#)),
            (#"\left"#, .missingDelimiter(command: "left")),
            (#"\left(x\right"#, .missingDelimiter(command: "right")),
            (#"\left(x\right\beta"#, .unsupportedDelimiter(command: "right", delimiter: #"\beta"#)),
        ]

        for (source, diagnostic) in malformed {
            let result = parser.parseValidated(source)
            #expect(result.diagnostics.contains(diagnostic), "Missing \(diagnostic) for \(source): \(result.diagnostics)")
            #expect(!result.isRenderable)
        }
    }

    @Test func hostileSourceTokenAndDepthLimitsFailClosed() {
        let oversized = String(repeating: "x", count: TeXMathLimits.maxSourceUTF8Bytes + 1)
        let oversizedResult = parser.parseValidated(oversized)
        #expect(oversizedResult.nodes.isEmpty)
        #expect(oversizedResult.diagnostics.contains(.sourceTooLong(maxUTF8Bytes: TeXMathLimits.maxSourceUTF8Bytes)))

        let tooManyTokens = (0...TeXMathLimits.maxTokenCount).map { _ in "x" }.joined(separator: "+")
        let tokenResult = parser.parseValidated(tooManyTokens)
        #expect(tokenResult.nodes.isEmpty)
        #expect(tokenResult.diagnostics.contains(.tooManyTokens(max: TeXMathLimits.maxTokenCount)))

        let depth = TeXMathLimits.maxNestingDepth + 1
        let deeplyNested = String(repeating: "{", count: depth) + "x" + String(repeating: "}", count: depth)
        let depthResult = parser.parseValidated(deeplyNested)
        #expect(depthResult.nodes.isEmpty)
        #expect(depthResult.diagnostics.contains(.nestingTooDeep(max: TeXMathLimits.maxNestingDepth)))
    }

    @Test func unsupportedAndMismatchedEnvironmentsAreDiagnosed() {
        let unsupported = parser.parseValidated("\\begin{equation}x\\end{equation}")
        #expect(unsupported.diagnostics.contains(.unsupportedEnvironment("equation")))
        #expect(!unsupported.isRenderable)

        let mismatched = parser.parseValidated("\\begin{matrix}x\\end{cases}")
        #expect(mismatched.diagnostics.contains(
            .mismatchedEnvironmentEnd(expected: "matrix", found: "cases")
        ))
        #expect(!mismatched.isRenderable)
    }

    // MARK: - Partial Results

    @Test func unmatchedOpenBrace() {
        // Should parse what it can
        let result = parser.parse("x + {y")
        // x and + should parse fine, then {y is a group missing close brace
        #expect(result.count >= 2, "Should produce at least x and +")
        #expect(result[0] == .variable("x"))
        #expect(result[1] == .operator(.plus))
    }

    @Test func unmatchedCloseBrace() {
        let result = parser.parse("x + y}")
        #expect(result.count >= 3, "Should produce x, +, y before stray }")
        #expect(result[0] == .variable("x"))
        #expect(result[1] == .operator(.plus))
        #expect(result[2] == .variable("y"))
    }

    @Test func fracMissingSecondArg() {
        let result = parser.parse("\\frac{a}")
        // Should produce a fraction with empty denominator
        #expect(result.count == 1)
        if case .fraction(let num, let den) = result[0] {
            #expect(num == [.variable("a")])
            #expect(den.isEmpty)
        } else {
            Issue.record("Expected fraction node")
        }
    }

    @Test func fracMissingBothArgs() {
        let result = parser.parse("\\frac")
        // Should produce a fraction with empty num and den
        #expect(result.count == 1)
        if case .fraction(let num, let den) = result[0] {
            #expect(num.isEmpty)
            #expect(den.isEmpty)
        } else {
            Issue.record("Expected fraction node")
        }
    }

    @Test func unmatchedLeftDelimiter() {
        let result = parser.parse("\\left( x + y")
        // Should produce a leftRight with .none for right delimiter
        #expect(result.count == 1)
        if case .leftRight(let left, let right, let body) = result[0] {
            #expect(left == .paren)
            #expect(right == .none)
            #expect(body.count == 3) // x, +, y
        } else {
            Issue.record("Expected leftRight node")
        }
    }

    @Test func strayRightDelimiter() {
        let result = parser.parse("x \\right)")
        // Should produce x and a literal )
        #expect(result.count == 2)
        #expect(result[0] == .variable("x"))
    }

    @Test func unknownCommand() {
        let result = parser.parse("\\foo + x")
        // Should produce the unknown command as a variable, then + and x
        #expect(result.count == 3)
        #expect(result[0] == .variable("\\foo"))
        #expect(result[1] == .operator(.plus))
        #expect(result[2] == .variable("x"))
    }

    @Test func bareSuperscript() {
        // ^ with no base — produces nothing for the base
        let result = parser.parse("^2 + x")
        // The ^ has no base, so it produces nothing; then 2, +, x
        #expect(result.count >= 2, "Should parse at least some nodes")
    }

    @Test func bareSubscript() {
        let result = parser.parse("_i + x")
        #expect(result.count >= 2, "Should parse at least some nodes")
    }

    @Test func emptyGroup() {
        let result = parser.parse("{}")
        // Empty group — should produce empty group or nothing
        #expect(result.isEmpty || result == [.group([])])
    }

    @Test func emptyEnvironmentBody() {
        let result = parser.parse("\\begin{pmatrix}\\end{pmatrix}")
        // Should produce an empty matrix
        #expect(result.count == 1)
        if case .matrix(let rows, let style) = result[0] {
            #expect(style == .parenthesized)
            // Empty matrix — no rows or one empty row
            #expect(rows.isEmpty || rows == [[[]]])
        } else {
            Issue.record("Expected matrix node")
        }
    }

    @Test func unclosedEnvironment() {
        // \begin without matching \end
        let result = parser.parse("\\begin{pmatrix} a & b")
        // Should return partial result
        #expect(!result.isEmpty)
    }

    @Test func strayEnd() {
        let result = parser.parse("x + \\end{pmatrix} + y")
        // Should skip the stray \end and continue
        #expect(result.count >= 2, "Should parse x and + at minimum")
    }

    @Test func sqrtMissingArg() {
        let result = parser.parse("\\sqrt")
        #expect(result.count == 1)
        if case .sqrt(let idx, let rad) = result[0] {
            #expect(idx == nil)
            #expect(rad.isEmpty)
        } else {
            Issue.record("Expected sqrt node")
        }
    }

    @Test func textMissingArg() {
        let result = parser.parse("\\text")
        #expect(result == [.text("")])
    }

    @Test func doubleSuperscript() {
        // x^2^3 — second ^ should just be ignored/skipped
        let result = parser.parse("x^2^3")
        // First ^ produces superscript(x, 2), second ^ has no base
        #expect(!result.isEmpty)
        #expect(result[0] == .superscript(base: [.variable("x")], exponent: [.number("2")]))
    }

    @Test func trailingBackslash() {
        let result = parser.parse("x + \\")
        #expect(result.count >= 2)
        #expect(result[0] == .variable("x"))
        #expect(result[1] == .operator(.plus))
    }

    @Test func unicodeCharacters() {
        // Non-ASCII should be treated as variables
        let result = parser.parse("\u{00e9}")
        #expect(result == [.variable("\u{00e9}")])
    }

    // MARK: - Stress

    @Test func deeplyNestedBraces() {
        let depth = 50
        let input = String(repeating: "{", count: depth) + "x" + String(repeating: "}", count: depth)
        let result = parser.parse(input)
        // Should eventually resolve to x (groups of one element unwrap)
        #expect(!result.isEmpty)
    }

    @Test func deeplyNestedFractions() {
        // \frac{\frac{\frac{a}{b}}{c}}{d}
        var input = "a"
        for _ in 0..<20 {
            input = "\\frac{\(input)}{x}"
        }
        let result = parser.parse(input)
        #expect(!result.isEmpty)
    }

    @Test func longInput() {
        // 1000 variables
        let input = String(repeating: "x+", count: 500) + "y"
        let result = parser.parse(input)
        #expect(result.count == 1001, "500 x's + 500 +'s + y")
    }
}
