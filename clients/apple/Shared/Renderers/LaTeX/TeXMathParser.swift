/// Recursive descent parser for TeX math mode.
///
/// Converts raw LaTeX math strings into `[MathNode]` ASTs.
/// Conforms to `DocumentParser` — safe to call from any thread.
///
/// Design:
/// 1. Tokenizer splits input into tokens (commands, groups, literals, etc.)
/// 2. Parser consumes tokens recursively, building the AST
/// 3. Malformed input produces partial results — never crashes
///
/// Supports Phase 1 KaTeX commands: variables, numbers, operators, relations,
/// fractions, sub/superscripts, Greek letters, delimiters, roots, text,
/// big operators, matrices, cases, accents, fonts, spaces.
struct TeXMathParser: DocumentParser, Sendable {
    nonisolated func parse(_ source: String) -> [MathNode] {
        var state = ParserState(source: source)
        state.tokenize()
        return state.parseTopLevel()
    }
}

// MARK: - Token

private enum Token: Equatable {
    case command(String)     // \alpha, \frac, etc. (without backslash)
    case openBrace           // {
    case closeBrace          // }
    case openBracket         // [
    case closeBracket        // ]
    case superscriptOp       // ^
    case subscriptOp         // _
    case ampersand           // &
    case doubleBslash        // \\
    case literal(Character)  // a, b, 1, +, (, etc.
    case textContent(String) // Raw text from \text{...} (preserves whitespace)
}

// MARK: - Tokenizer + Parser State

/// Mutable state for a single parse invocation.
/// Holds the token stream and a cursor into it.
private struct ParserState {
    let source: String
    var tokens: [Token] = []
    var pos: Int = 0

    var atEnd: Bool { pos >= tokens.count }

    // MARK: Tokenization

    mutating func tokenize() {
        var chars = source.makeIterator()
        var pending: Character?

        while true {
            let ch: Character
            if let p = pending {
                ch = p
                pending = nil
            } else if let next = chars.next() {
                ch = next
            } else {
                break
            }

            switch ch {
            case "\\":
                // Check for \\ (row separator)
                if let next = chars.next() {
                    if next == "\\" {
                        tokens.append(.doubleBslash)
                    } else if next.isLetter {
                        // Read full command name
                        var name = String(next)
                        while let c = chars.next() {
                            if c.isLetter {
                                name.append(c)
                            } else {
                                pending = c
                                break
                            }
                        }

                        // Special case: \text{...} preserves whitespace
                        if name == "text" {
                            // Skip any whitespace before the brace
                            while let p = pending, p.isWhitespace {
                                pending = chars.next()
                            }
                            if pending == Character("{") {
                                pending = nil
                                var content = ""
                                var depth = 1
                                while let c = chars.next() {
                                    if c == "{" {
                                        depth += 1
                                        content.append(c)
                                    } else if c == "}" {
                                        depth -= 1
                                        if depth == 0 { break }
                                        content.append(c)
                                    } else {
                                        content.append(c)
                                    }
                                }
                                tokens.append(.textContent(content))
                            } else {
                                // \text without braces
                                tokens.append(.command(name))
                            }
                        } else {
                            tokens.append(.command(name))
                        }
                    } else {
                        // Single-char command: \, \; \: \! \{ \} \| \<space>
                        tokens.append(.command(String(next)))
                    }
                }
                // else: trailing backslash — ignore

            case "{": tokens.append(.openBrace)
            case "}": tokens.append(.closeBrace)
            case "[": tokens.append(.openBracket)
            case "]": tokens.append(.closeBracket)
            case "^": tokens.append(.superscriptOp)
            case "_": tokens.append(.subscriptOp)
            case "&": tokens.append(.ampersand)
            case " ", "\t", "\n", "\r":
                // Whitespace is insignificant in math mode
                continue
            default:
                tokens.append(.literal(ch))
            }
        }
    }

    // MARK: Token Helpers

    mutating func peek() -> Token? {
        guard pos < tokens.count else { return nil }
        return tokens[pos]
    }

    mutating func advance() -> Token? {
        guard pos < tokens.count else { return nil }
        let tok = tokens[pos]
        pos += 1
        return tok
    }

    mutating func expect(_ token: Token) -> Bool {
        if peek() == token {
            pos += 1
            return true
        }
        return false
    }

    // MARK: Top-Level Parse

    mutating func parseTopLevel() -> [MathNode] {
        parseNodeList(until: { _ in false })
    }

    // MARK: Node List

    /// Parse nodes until `stop` returns true or we hit end-of-tokens.
    /// `stop` is checked *before* consuming each token.
    mutating func parseNodeList(until stop: (Token) -> Bool) -> [MathNode] {
        var nodes: [MathNode] = []
        while let tok = peek() {
            if stop(tok) { break }
            let before = pos
            if let node = parseAtom() {
                let result = attachScripts(base: node)
                nodes.append(result)
            } else if pos == before {
                // parseAtom returned nil without consuming — skip to avoid infinite loop
                pos += 1
            }
        }
        return nodes
    }

    // MARK: Atom Parsing

    /// Parse a single atom (before sub/superscript attachment).
    mutating func parseAtom() -> MathNode? {
        guard let tok = peek() else { return nil }

        switch tok {
        case .textContent(let content):
            pos += 1
            return .text(content)

        case .command(let name):
            return parseCommand(name)

        case .openBrace:
            return parseGroup()

        case .literal(let ch):
            pos += 1
            return parseLiteral(ch)

        case .openBracket:
            pos += 1
            return .variable("[")

        case .closeBracket:
            pos += 1
            return .variable("]")

        case .closeBrace:
            // Unmatched close brace — skip
            pos += 1
            return nil

        case .superscriptOp, .subscriptOp:
            // Bare ^ or _ without a base — use empty base
            return nil

        case .ampersand, .doubleBslash:
            // Row/column separators — handled by matrix/environment parsing
            return nil
        }
    }

    // MARK: Literal Classification

    func parseLiteral(_ ch: Character) -> MathNode {
        if ch.isNumber || ch == "." {
            return .number(String(ch))
        }
        if let op = literalOperator(ch) {
            return .operator(op)
        }
        return .variable(String(ch))
    }

    func literalOperator(_ ch: Character) -> MathOperator? {
        switch ch {
        case "+": return .plus
        case "-": return .minus
        case "*": return .star
        case "=": return .equal
        case "<": return .lessThan
        case ">": return .greaterThan
        case ":": return .colon
        case ",": return .comma
        case ";": return .semicolon
        case "!": return .bang
        default: return nil
        }
    }

    // MARK: Command Parsing

    mutating func parseCommand(_ name: String) -> MathNode? {
        guard let result = MathSymbolTable.lookup(name) else {
            // Unknown command — skip it and return as a variable
            pos += 1
            return .variable("\\" + name)
        }

        pos += 1 // consume the command token

        switch result {
        case .symbol(let sym):
            return .symbol(sym)

        case .operator(let op):
            return .operator(op)

        case .bigOperator(let kind):
            return parseBigOperator(kind)

        case .accent(let kind):
            return parseAccent(kind)

        case .font(let style):
            return parseFont(style)

        case .space(let sp):
            return .space(sp)

        case .delimiter(let del):
            // Bare delimiter command (not inside \left/\right)
            // Treat as a literal delimiter character
            return literalDelimiter(del)

        case .fraction:
            return parseFraction()

        case .sqrt:
            return parseSqrt()

        case .text:
            return parseText()

        case .left:
            return parseLeftRight()

        case .right:
            // Stray \right without matching \left — return delimiter literal
            return parseStrayRight()

        case .begin:
            return parseEnvironment()

        case .end:
            // Stray \end — skip
            _ = parseBraceArg()
            return nil
        }
    }

    // MARK: Group

    mutating func parseGroup() -> MathNode? {
        guard expect(.openBrace) else { return nil }
        let children = parseNodeList { $0 == .closeBrace }
        _ = expect(.closeBrace) // consume if present, tolerate missing
        if children.count == 1 {
            return children[0]
        }
        return .group(children)
    }

    // MARK: Brace Argument

    /// Parse a mandatory `{...}` argument. Returns the node list inside.
    mutating func parseBraceArg() -> [MathNode] {
        guard expect(.openBrace) else {
            // Missing brace — try to parse a single atom as the argument
            if let atom = parseAtom() {
                return [atom]
            }
            return []
        }
        let nodes = parseNodeList { $0 == .closeBrace }
        _ = expect(.closeBrace)
        return nodes
    }

    /// Parse a mandatory `{...}` and return raw text content (for environment names).
    mutating func parseBraceText() -> String {
        guard expect(.openBrace) else { return "" }
        var text = ""
        while let tok = peek() {
            if tok == .closeBrace { break }
            pos += 1
            switch tok {
            case .literal(let ch): text.append(ch)
            case .command(let name): text.append(name)
            default: break
            }
        }
        _ = expect(.closeBrace)
        return text
    }

    // MARK: Sub/Superscript

    /// Attach `_` and `^` scripts to a base node.
    mutating func attachScripts(base: MathNode) -> MathNode {
        var sub: [MathNode]?
        var sup: [MathNode]?

        // Handle _ and ^ in either order, and handle combined
        while let tok = peek() {
            if tok == .subscriptOp, sub == nil {
                pos += 1
                sub = parseBraceArg()
            } else if tok == .superscriptOp, sup == nil {
                pos += 1
                sup = parseBraceArg()
            } else {
                break
            }
        }

        // BigOperator with limits gets special handling
        if case .bigOperator(let kind, _) = base {
            if sub != nil || sup != nil {
                return .bigOperator(kind, limits: MathLimits(lower: sub, upper: sup))
            }
            return base
        }

        if let sub, let sup {
            return .subSuperscript(base: [base], sub: sub, sup: sup)
        } else if let sup {
            return .superscript(base: [base], exponent: sup)
        } else if let sub {
            return .subscript(base: [base], index: sub)
        }
        return base
    }

    // MARK: Fraction

    mutating func parseFraction() -> MathNode {
        let numerator = parseBraceArg()
        let denominator = parseBraceArg()
        return .fraction(numerator: numerator, denominator: denominator)
    }

    // MARK: Square Root

    mutating func parseSqrt() -> MathNode {
        // Optional [index]
        var index: [MathNode]?
        if peek() == .openBracket {
            pos += 1
            index = parseNodeList { $0 == .closeBracket }
            _ = expect(.closeBracket)
        }
        let radicand = parseBraceArg()
        return .sqrt(index: index, radicand: radicand)
    }

    // MARK: Text

    mutating func parseText() -> MathNode {
        guard expect(.openBrace) else { return .text("") }
        var content = ""
        var depth = 1
        while let tok = advance() {
            switch tok {
            case .openBrace: depth += 1; content.append("{")
            case .closeBrace:
                depth -= 1
                if depth == 0 { return .text(content) }
                content.append("}")
            case .literal(let ch): content.append(ch)
            case .command(let name): content.append("\\" + name)
            default: break
            }
        }
        return .text(content) // unclosed — return what we have
    }

    // MARK: Left/Right Delimiters

    mutating func parseLeftRight() -> MathNode {
        let leftDel = parseDelimiter()
        let body = parseNodeList { tok in
            if case .command("right") = tok { return true }
            return false
        }
        let rightDel: Delimiter
        if case .command("right") = peek() {
            pos += 1
            rightDel = parseDelimiter()
        } else {
            rightDel = .none // missing \right — error recovery
        }
        return .leftRight(left: leftDel, right: rightDel, body: body)
    }

    mutating func parseStrayRight() -> MathNode? {
        let del = parseDelimiter()
        return literalDelimiter(del)
    }

    mutating func parseDelimiter() -> Delimiter {
        guard let tok = peek() else { return .none }
        switch tok {
        case .literal(let ch):
            pos += 1
            switch ch {
            case "(": return .paren
            case ")": return .closeParen
            case "|": return .pipe
            case ".": return .none
            default: return .none
            }
        case .openBracket:
            pos += 1
            return .bracket
        case .closeBracket:
            pos += 1
            return .closeBracket
        case .command(let name):
            pos += 1
            if let result = MathSymbolTable.lookup(name),
               case .delimiter(let del) = result {
                return del
            }
            // Handle \| specifically
            if name == "|" { return .doublePipe }
            return .none
        default:
            return .none
        }
    }

    func literalDelimiter(_ del: Delimiter) -> MathNode {
        switch del {
        case .paren: return .variable("(")
        case .closeParen: return .variable(")")
        case .bracket: return .variable("[")
        case .closeBracket: return .variable("]")
        case .pipe: return .variable("|")
        default: return .variable(del.rawValue)
        }
    }

    // MARK: Big Operators

    mutating func parseBigOperator(_ kind: BigOpKind) -> MathNode {
        // Don't consume limits here — attachScripts handles _ and ^
        return .bigOperator(kind, limits: nil)
    }

    // MARK: Accents

    mutating func parseAccent(_ kind: MathAccentKind) -> MathNode {
        let base = parseBraceArg()
        return .accent(kind, base: base)
    }

    // MARK: Fonts

    mutating func parseFont(_ style: MathFontStyle) -> MathNode {
        let body = parseBraceArg()
        return .font(style, body: body)
    }

    // MARK: Environments

    mutating func parseEnvironment() -> MathNode? {
        let name = parseBraceText()
        guard !name.isEmpty else { return nil }

        // Matrix environments
        if let style = MatrixStyle(rawValue: name) {
            let rows = parseMatrixRows(endName: name)
            return .matrix(rows: rows, style: style)
        }

        // Cases and other row-based environments
        if name == "cases" || name == "aligned" || name == "gathered" {
            let rows = parseMatrixRows(endName: name)
            return .environment(name, rows: rows)
        }

        // Unknown environment — skip to \end{name}
        skipToEnd(name: name)
        return nil
    }

    mutating func parseMatrixRows(endName: String) -> [[[MathNode]]] {
        var rows: [[[MathNode]]] = []
        var currentRow: [[MathNode]] = []
        var currentCell: [MathNode] = []

        while !atEnd {
            guard let tok = peek() else { break }

            // Check for \end{name}
            if case .command("end") = tok {
                let saved = pos
                pos += 1
                let endEnvName = parseBraceText()
                if endEnvName == endName {
                    // Found matching \end — finalize
                    if !currentCell.isEmpty || !currentRow.isEmpty {
                        currentRow.append(currentCell)
                        rows.append(currentRow)
                    }
                    return rows
                }
                // Not our \end — restore and continue
                pos = saved
            }

            if tok == .ampersand {
                pos += 1
                currentRow.append(currentCell)
                currentCell = []
            } else if tok == .doubleBslash {
                pos += 1
                currentRow.append(currentCell)
                rows.append(currentRow)
                currentRow = []
                currentCell = []
            } else if let node = parseAtom() {
                let result = attachScripts(base: node)
                currentCell.append(result)
            } else {
                // Skip unparseable token
                pos += 1
            }
        }

        // Unclosed environment — return what we have
        if !currentCell.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentCell)
            rows.append(currentRow)
        }
        return rows
    }

    mutating func skipToEnd(name: String) {
        while !atEnd {
            if case .command("end") = peek() {
                pos += 1
                let endName = parseBraceText()
                if endName == name { return }
            } else {
                pos += 1
            }
        }
    }
}
