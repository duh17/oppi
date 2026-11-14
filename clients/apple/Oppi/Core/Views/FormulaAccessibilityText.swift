import Foundation

/// What VoiceOver reads for a formula: its math as plain text, or its TeX
/// source when plain text would drop something that changes the meaning.
extension FlatSegment {
    static func formulaAccessibilityLabel(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = TeXMathParser().parseValidated(trimmed)
        let plain = parsed.isRenderable && !containsLossyAccessibilityNode(in: parsed.nodes)
            ? mathPlainText(from: parsed.nodes)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let accessibleValue = plain.isEmpty ? trimmed : plain
        if plain.isEmpty {
            return String(
                format: String(localized: "Math formula source: %@"),
                accessibleValue
            )
        }
        return String(format: String(localized: "Math formula: %@"), accessibleValue)
    }

    private static func mathPlainText(from nodes: [MathNode]) -> String {
        var output = ""
        for node in nodes {
            appendMathPlainText(node, to: &output)
        }
        return output
    }

    private static func appendMathPlainText(_ node: MathNode, to output: inout String) {
        switch node {
        case .number(let value), .variable(let value), .text(let value):
            appendMathToken(value, to: &output)
        case .operator(let op):
            appendMathOperator(op, to: &output)
        case .symbol(let symbol):
            appendMathToken(mathSymbolText(symbol), to: &output)
        case .fraction(let numerator, let denominator):
            appendMathToken(groupedFractionOperand(numerator), to: &output)
            appendMathToken("/", to: &output)
            appendMathToken(groupedFractionOperand(denominator), to: &output)
        case .superscript(let base, let exponent):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("^", to: &output)
            appendMathToken(groupedScriptOperand(exponent), to: &output)
        case .subscript(let base, let index):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("_", to: &output)
            appendMathToken(groupedScriptOperand(index), to: &output)
        case .subSuperscript(let base, let sub, let sup):
            appendMathToken(mathPlainText(from: base), to: &output)
            appendMathToken("_", to: &output)
            appendMathToken(groupedScriptOperand(sub), to: &output)
            appendMathToken("^", to: &output)
            appendMathToken(groupedScriptOperand(sup), to: &output)
        case .sqrt(let index, let radicand):
            appendMathToken("√", to: &output)
            if let index {
                appendMathToken("[", to: &output)
                appendMathToken(mathPlainText(from: index), to: &output)
                appendMathToken("]", to: &output)
            }
            appendMathToken("(", to: &output)
            appendMathToken(mathPlainText(from: radicand), to: &output)
            appendMathToken(")", to: &output)
        case .group(let body), .font(_, let body), .accent(_, let body), .style(_, let body),
             .color(_, let body):
            appendMathToken(mathPlainText(from: body), to: &output)
        case .phantom:
            break
        case .stack(let base, let over, let under, _):
            appendMathToken(mathPlainText(from: base), to: &output)
            if let under {
                appendMathToken("_", to: &output)
                appendMathToken(groupedScriptOperand(under), to: &output)
            }
            if let over {
                appendMathToken("^", to: &output)
                appendMathToken(groupedScriptOperand(over), to: &output)
            }
        case .operatorName(let name, let limits, _):
            appendMathToken(mathPlainText(from: name), to: &output)
            if let lower = limits?.lower {
                appendMathToken("_", to: &output)
                appendMathToken(groupedScriptOperand(lower), to: &output)
            }
            if let upper = limits?.upper {
                appendMathToken("^", to: &output)
                appendMathToken(groupedScriptOperand(upper), to: &output)
            }
            appendSpace(to: &output)
        case .substack(let rows):
            appendMathToken(rows.map { mathPlainText(from: $0) }.joined(separator: ", "), to: &output)
        case .tag(let body, let parenthesized):
            appendSpace(to: &output)
            let label = mathPlainText(from: body)
            appendMathToken(parenthesized ? "(\(label))" : label, to: &output)
        case .binomial(let top, let bottom):
            appendMathToken("(", to: &output)
            appendMathToken(mathPlainText(from: top), to: &output)
            appendSpacedMathToken("choose", to: &output)
            appendMathToken(mathPlainText(from: bottom), to: &output)
            appendMathToken(")", to: &output)
        case .sizedDelimiter(let delimiter, _):
            appendMathToken(delimiterText(delimiter), to: &output)
        case .leftRight(let left, let right, let body):
            appendMathToken(delimiterText(left), to: &output)
            appendMathToken(mathPlainText(from: body), to: &output)
            appendMathToken(delimiterText(right), to: &output)
        case .matrix(let rows, _), .environment(_, let rows):
            let rowText = rows.map { row in
                row.map { mathPlainText(from: $0) }.joined(separator: " | ")
            }.joined(separator: "; ")
            appendMathToken(rowText, to: &output)
        case .space:
            appendSpace(to: &output)
        case .bigOperator(let kind, let limits):
            appendMathToken(bigOperatorText(kind), to: &output)
            if let lower = limits?.lower {
                appendMathToken("_", to: &output)
                appendMathToken(groupedScriptOperand(lower), to: &output)
            }
            if let upper = limits?.upper {
                appendMathToken("^", to: &output)
                appendMathToken(groupedScriptOperand(upper), to: &output)
            }
        }
    }

    private static func groupedFractionOperand(_ nodes: [MathNode]) -> String {
        groupedMathOperand(nodes)
    }

    private static func groupedScriptOperand(_ nodes: [MathNode]) -> String {
        groupedMathOperand(nodes)
    }

    private static func groupedMathOperand(_ nodes: [MathNode]) -> String {
        let plain = mathPlainText(from: nodes)
        guard nodes.count != 1 || !isAtomicFractionOperand(nodes[0]) else {
            return plain
        }
        return "(\(plain))"
    }

    private static func isAtomicFractionOperand(_ node: MathNode) -> Bool {
        switch node {
        case .number, .variable, .text, .symbol:
            return true
        default:
            return false
        }
    }

    private static func containsLossyAccessibilityNode(in nodes: [MathNode]) -> Bool {
        nodes.contains(where: containsLossyAccessibilityNode)
    }

    private static func containsLossyAccessibilityNode(_ node: MathNode) -> Bool {
        switch node {
        case .accent:
            // Omitting an accent changes the expression. Until a spoken accent
            // vocabulary is available, preserve exact TeX instead.
            return true
        case .fraction(let numerator, let denominator):
            return containsLossyAccessibilityNode(in: numerator)
                || containsLossyAccessibilityNode(in: denominator)
        case .superscript(let base, let exponent):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: exponent)
        case .subscript(let base, let index):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: index)
        case .subSuperscript(let base, let sub, let sup):
            return containsLossyAccessibilityNode(in: base)
                || containsLossyAccessibilityNode(in: sub)
                || containsLossyAccessibilityNode(in: sup)
        case .sqrt(let index, let radicand):
            return (index.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || containsLossyAccessibilityNode(in: radicand)
        case .group(let body), .font(_, let body), .style(_, let body), .color(_, let body),
             .tag(let body, _):
            return containsLossyAccessibilityNode(in: body)
        case .stack(let base, let over, let under, _):
            return containsLossyAccessibilityNode(in: base)
                || (over.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || (under.map { containsLossyAccessibilityNode(in: $0) } ?? false)
        case .operatorName(let name, let limits, _):
            return containsLossyAccessibilityNode(in: name)
                || (limits?.lower.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || (limits?.upper.map { containsLossyAccessibilityNode(in: $0) } ?? false)
        case .substack(let rows):
            return rows.contains { containsLossyAccessibilityNode(in: $0) }
        case .phantom:
            return false
        case .binomial(let top, let bottom):
            return containsLossyAccessibilityNode(in: top)
                || containsLossyAccessibilityNode(in: bottom)
        case .leftRight(_, _, let body):
            return containsLossyAccessibilityNode(in: body)
        case .matrix(let rows, _), .environment(_, let rows):
            return rows.flatMap { $0 }.contains { containsLossyAccessibilityNode(in: $0) }
        case .bigOperator(_, let limits):
            return (limits?.lower.map { containsLossyAccessibilityNode(in: $0) } ?? false)
                || (limits?.upper.map { containsLossyAccessibilityNode(in: $0) } ?? false)
        case .number, .variable, .operator, .symbol, .text, .space, .sizedDelimiter:
            return false
        }
    }

    private static func appendMathOperator(_ op: MathOperator, to output: inout String) {
        let text: String
        switch op {
        case .plus: text = "+"
        case .minus: text = "−"
        case .times: text = "×"
        case .div: text = "÷"
        case .cdot: text = "·"
        case .pm: text = "±"
        case .mp: text = "∓"
        case .star: text = "*"
        case .equal: text = "="
        case .lessThan: text = "<"
        case .greaterThan: text = ">"
        case .leq: text = "≤"
        case .geq: text = "≥"
        case .neq: text = "≠"
        case .approx: text = "≈"
        case .equiv: text = "≡"
        case .sim: text = "∼"
        case .propto: text = "∝"
        case .mid: text = "∣"
        case .in: text = "∈"
        case .subset: text = "⊂"
        case .supset: text = "⊃"
        case .subseteq: text = "⊆"
        case .supseteq: text = "⊇"
        case .cup: text = "∪"
        case .cap: text = "∩"
        case .to, .rightarrow: text = "→"
        case .leftarrow: text = "←"
        case .mapsto: text = "↦"
        case .iff: text = "⟺"
        case .doubleRightarrow: text = "⇒"
        case .doubleLeftarrow: text = "⇐"
        case .doubleLeftrightarrow: text = "⇔"
        case .leftrightarrow: text = "↔"
        case .notin: text = "∉"
        case .perp: text = "⊥"
        case .ll: text = "≪"
        case .gg: text = "≫"
        case .longrightarrow: text = "⟶"
        case .longleftarrow: text = "⟵"
        case .longleftrightarrow: text = "⟷"
        case .doubleLongRightarrow: text = "⟹"
        case .doubleLongLeftarrow: text = "⟸"
        case .doubleLongLeftrightarrow: text = "⟺"
        case .longmapsto: text = "⟼"
        case .setminus: text = "∖"
        case .circ: text = "∘"
        case .oplus: text = "⊕"
        case .otimes: text = "⊗"
        case .wedge: text = "∧"
        case .vee: text = "∨"
        case .colon: text = ":"
        case .comma: text = ","
        case .semicolon: text = ";"
        case .bang: text = "!"
        }
        appendSpacedMathToken(text, to: &output)
    }

    private static func appendMathToken(_ token: String, to output: inout String) {
        guard !token.isEmpty else { return }
        if isArrowToken(token) {
            appendSpacedMathToken(token, to: &output)
        } else {
            output.append(token)
        }
    }

    private static func appendSpacedMathToken(_ token: String, to output: inout String) {
        guard !token.isEmpty else { return }
        appendSpace(to: &output)
        output.append(token)
        appendSpace(to: &output)
    }

    private static func appendSpace(to output: inout String) {
        if output.last?.isWhitespace != true {
            output.append(" ")
        }
    }

    private static func isArrowToken(_ token: String) -> Bool {
        ["→", "←", "↔", "⇒", "⇐", "⇔", "⟶", "⟵", "⟷", "⟹", "⟸", "⟺", "↦", "⟼"].contains(token)
    }

    private static func delimiterText(_ delimiter: Delimiter) -> String {
        switch delimiter {
        case .paren: return "("
        case .closeParen: return ")"
        case .bracket: return "["
        case .closeBracket: return "]"
        case .brace: return "{"
        case .closeBrace: return "}"
        case .pipe: return "|"
        case .doublePipe: return "‖"
        case .angle: return "⟨"
        case .closeAngle: return "⟩"
        case .floor: return "⌊"
        case .closeFloor: return "⌋"
        case .ceil: return "⌈"
        case .closeCeil: return "⌉"
        case .none: return ""
        }
    }

    private static func bigOperatorText(_ kind: BigOpKind) -> String {
        switch kind {
        case .sum: return "∑"
        case .prod: return "∏"
        case .coprod: return "∐"
        case .int: return "∫"
        case .iint: return "∬"
        case .iiint: return "∭"
        case .oint: return "∮"
        case .bigcup: return "⋃"
        case .bigcap: return "⋂"
        case .bigoplus: return "⨁"
        case .bigotimes: return "⨂"
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
        case .xrightarrow: return "⟶"
        case .xleftarrow: return "⟵"
        }
    }

    private static func mathSymbolText(_ symbol: MathSymbol) -> String {
        switch symbol {
        case .alpha: return "α"
        case .beta: return "β"
        case .gamma: return "γ"
        case .delta: return "δ"
        case .epsilon, .varepsilon: return "ε"
        case .zeta: return "ζ"
        case .eta: return "η"
        case .theta, .vartheta: return "θ"
        case .iota: return "ι"
        case .kappa: return "κ"
        case .lambda: return "λ"
        case .mu: return "μ"
        case .nu: return "ν"
        case .xi: return "ξ"
        case .pi: return "π"
        case .rho, .varrho: return "ρ"
        case .sigma, .varsigma: return "σ"
        case .tau: return "τ"
        case .upsilon: return "υ"
        case .phi, .varphi: return "φ"
        case .chi: return "χ"
        case .psi: return "ψ"
        case .omega: return "ω"
        case .capitalGamma: return "Γ"
        case .capitalDelta: return "Δ"
        case .capitalTheta: return "Θ"
        case .capitalLambda: return "Λ"
        case .capitalXi: return "Ξ"
        case .capitalPi: return "Π"
        case .capitalSigma: return "Σ"
        case .capitalUpsilon: return "Υ"
        case .capitalPhi: return "Φ"
        case .capitalPsi: return "Ψ"
        case .capitalOmega: return "Ω"
        case .infty: return "∞"
        case .partial: return "∂"
        case .nabla: return "∇"
        case .forall: return "∀"
        case .exists: return "∃"
        case .neg: return "¬"
        case .ell: return "ℓ"
        case .hbar: return "ℏ"
        case .emptyset: return "∅"
        case .cdots: return "⋯"
        case .ldots: return "…"
        case .vdots: return "⋮"
        case .ddots: return "⋱"
        case .prime: return "′"
        case .top: return "⊤"
        case .aleph: return "ℵ"
        }
    }
}
