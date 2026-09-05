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
            case .font(.roman, _), .subscript, .subSuperscript, .bigOperator:
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
