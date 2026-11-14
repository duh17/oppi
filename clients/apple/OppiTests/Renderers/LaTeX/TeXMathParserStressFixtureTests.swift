import Testing
@testable import Oppi

/// Regression: display math from `.pi/markdown-rendering-stress-test.md`
/// section “Math and LaTeX” must validate as renderable formulas.
@Suite("TeXMathParser stress-fixture commands")
struct TeXMathParserStressFixtureTests {
    private let parser = TeXMathParser()

    private static let integral = #"""
    \int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
    """#

    private static let alignedMatrices = #"""
    \begin{aligned}
      A &= \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}, &
      \det(A) &= -2 \\
      B &= A^{-1}, &
      AB &= I
    \end{aligned}
    """#

    private static let conditionalProbability = #"""
    P(A \mid B) = \frac{P(B \mid A)P(A)}{P(B)}
    """#

    private static let boxedEuler = #"""
    \boxed{e^{i\pi} + 1 = 0}
    """#

    private static let baselXrightarrow = #"""
    \sum_{n=1}^{N} \frac{1}{n^2} \;\xrightarrow{N\to\infty}\; \frac{\pi^2}{6}
    """#

    private static let argmin = #"""
    \operatorname*{arg\,min}_{\theta \in \mathbb{R}^{d}}\left[\frac{1}{n}\sum_{i=1}^{n}\left(f_{\theta}(x_i)-y_i\right)^2 + \lambda\lVert\theta\rVert_2^2\right]
    """#

    @Test(arguments: [
        integral,
        alignedMatrices,
        conditionalProbability,
        boxedEuler,
        argmin,
        baselXrightarrow,
    ])
    func fixtureDisplayMathIsRenderable(_ source: String) {
        let result = parser.parseValidated(source)
        #expect(result.diagnostics.isEmpty, "Unexpected diagnostics for \(source): \(result.diagnostics)")
        #expect(result.isRenderable)
        #expect(!result.nodes.isEmpty)
    }

    /// Formulas from the LaTeX stress file that fell back to source because
    /// a command was missing (`\displaystyle`, `\binom`, `\propto`), and
    /// the styled fraction forms.
    @Test(arguments: [
        #"\displaystyle \int_{-\infty}^{\infty} \frac{\sin x}{x}\,dx = \pi"#,
        #"\binom{n}{k} = \frac{n!}{k!(n-k)!}"#,
        #"\sum_{k=0}^{n} \binom{n}{k} = 2^n"#,
        #"\frac{1}{\displaystyle 1 + \frac{1}{\displaystyle 1 + \frac{1}{1 + \cdots}}} = \frac{\sqrt{5} - 1}{2}"#,
        #"i \propto j"#,
        #"\dfrac{a}{b} + \tfrac{c}{d} + \cfrac{1}{2} + \dbinom{n}{2} + \tbinom{n}{2}"#,
        #"\textstyle a \scriptstyle b \scriptscriptstyle c"#,
    ])
    func stressFileFormulasRender(_ source: String) {
        let result = parser.parseValidated(source)
        #expect(result.diagnostics.isEmpty, "Unexpected diagnostics for \(source): \(result.diagnostics)")
        #expect(result.isRenderable)
    }

    /// Section 13 of the LaTeX stress file: alignment environments, colour,
    /// over/under stacks, limits control, tags, phantoms, the dots family, and
    /// the symbols, arrows and delimiters agents write most.
    @Test(arguments: [
        #"a \notin B,\ A \setminus B,\ f \circ g,\ u \oplus v,\ u \otimes v,\ p \wedge q,\ p \vee q,\ u \perp v"#,
        #"\epsilon \ll 1,\ N \gg 1,\ \aleph_0,\ \lfloor x \rfloor,\ \lceil x \rceil"#,
        #"a_1, \dots, a_n,\ a_1 + \dots + a_n,\ 1, 2, \ldots, n,\ x_1 \cdots x_n"#,
        #"A \longrightarrow B \longleftarrow C \longleftrightarrow D \Longrightarrow E \Longleftarrow F \Longleftrightarrow G,\ x \longmapsto x^2"#,
        #"\check{x},\ \breve{a},\ \boldsymbol{x} = \boldsymbol{\alpha} + \mathbf{x},\ a\phantom{bb}c\hphantom{x}\vphantom{\int}"#,
        #"""
        \begin{align}
        f(x) &= (x + 1)^2 \\
        &= x^2 + 2x + 1 \tag{1} \\
        &\ge 0 \nonumber
        \end{align}
        """#,
        #"\begin{align*} \lVert u + v \rVert^2 &= \lVert u \rVert^2 + \lVert v \rVert^2 & u \perp v &\Longrightarrow \langle u, v \rangle = 0 \end{align*}"#,
        #"\begin{gather} a^2 + b^2 = c^2 \\ e^{i\pi} + 1 = 0 \notag \end{gather}"#,
        #"\begin{equation*} \begin{split} (a + b)^3 &= (a + b)(a + b)^2 \\ &= a^3 + 3a^2 b + 3ab^2 + b^3 \end{split} \end{equation*}"#,
        #"{\color{red} F = ma}, \quad \textcolor{green}{\nabla \cdot \mathbf{B} = 0}, \quad \textcolor{#ff8800}{\text{hex}}, \quad \color[HTML]{6A5ACD} \phi"#,
        #"x \overset{\text{def}}{=} \lim_{n \to \infty} x_n, \qquad A \underset{n \to \infty}{\longrightarrow} B, \qquad a \stackrel{?}{=} b"#,
        #"\sum_{\substack{0 \le i \le m \\ 0 < j < n}} P(i, j), \qquad \int\limits_0^1 f(x)\,dx, \qquad \sum\nolimits_{k=1}^{n} k, \qquad \operatorname*{arg\,max}_{x \in X} f(x)"#,
        #"\overbrace{1 + 2 + \cdots + n}^{n \text{ terms}} = \underbrace{\frac{n(n+1)}{2}}_{\text{Gauss}} \tag*{(G)}"#,
        #"\left\lfloor \frac{n}{2} \right\rfloor + \left\lceil \frac{n}{2} \right\rceil = n, \qquad \aleph_0 < 2^{\aleph_0}"#,
        #"\dotsc \dotsb \dotsm \dotsi \dotso \vdots \ddots \land \lor"#,
    ])
    func batchTwoFormulasRender(_ source: String) {
        let result = parser.parseValidated(source)
        #expect(result.diagnostics.isEmpty, "Unexpected diagnostics for \(source): \(result.diagnostics)")
        #expect(result.isRenderable)
    }

    @Test(arguments: [
        #"\textcolor{red}"#, #"\color"#, #"\overset{a}"#, #"\stackrel{a}"#, #"\tag"#,
        #"\phantom"#, #"\substack"#, #"\begin{align} a &= b"#,
    ])
    func batchTwoCommandsNeedTheirArguments(_ source: String) {
        #expect(!parser.parseValidated(source).isRenderable, "\(source) should fall back to source")
    }

    @Test(arguments: [#"\binom{n}"#, #"\dfrac{1}"#])
    func twoArgumentCommandsNeedBothArguments(_ source: String) {
        #expect(!parser.parseValidated(source).isRenderable)
    }

    @Test func midIsARelationAndDoesNotRemainACommandToken() {
        let result = parser.parse(#"P(A \mid B)"#)
        #expect(result.contains { node in
            switch node {
            case .operator, .variable("|"), .text("|"):
                return true
            default:
                return false
            }
        })
        #expect(!result.contains(.variable(#"\mid"#)))
    }

    @Test func boxedWrapsItsArgumentInsteadOfRemainingUnknown() {
        let result = parser.parse(#"\boxed{e^{i\pi} + 1 = 0}"#)
        #expect(!result.isEmpty)
        #expect(!result.contains(.variable(#"\boxed"#)))
        #expect(result.contains { node in
            if case .superscript(let base, _) = node, base == [.variable("e")] {
                return true
            }
            return false
        } || result.contains { node in
            if case .group(let children) = node {
                return children.contains { child in
                    if case .superscript(let base, _) = child, base == [.variable("e")] {
                        return true
                    }
                    return false
                }
            }
            return false
        })
    }

    @Test func operatornameStarRendersAsUprightNameWithLimits() {
        let result = parser.parse(#"\operatorname*{arg\,min}_{\theta}"#)
        #expect(!result.contains(.variable(#"\operatorname"#)))
        #expect(result.contains { node in
            switch node {
            case .operatorName(_, .some, true):
                return true
            default:
                return false
            }
        })
    }

    @Test func xrightarrowConsumesOverscriptInsteadOfRemainingUnknown() {
        let result = parser.parse(#"\xrightarrow{N\to\infty}"#)
        #expect(!result.contains(.variable(#"\xrightarrow"#)))
        #expect(result.contains { node in
            switch node {
            case .bigOperator, .superscript, .subSuperscript, .accent, .operator(.rightarrow):
                return true
            default:
                return false
            }
        })
    }

    @Test func xleftarrowConsumesOverscriptInsteadOfRemainingUnknown() {
        let result = parser.parse(#"\xleftarrow{f}"#)
        #expect(!result.contains(.variable(#"\xleftarrow"#)))
        #expect(result.contains { node in
            switch node {
            case .bigOperator, .superscript, .subSuperscript, .accent, .operator(.leftarrow):
                return true
            default:
                return false
            }
        })
    }

    @Test func xrightarrowOptionalUnderscriptIsRenderable() {
        let result = parser.parseValidated(#"\xrightarrow[n=1]{N\to\infty}"#)
        #expect(result.diagnostics.isEmpty, "Unexpected diagnostics: \(result.diagnostics)")
        #expect(result.isRenderable)
        #expect(!result.nodes.contains(.variable(#"\xrightarrow"#)))
    }
}
