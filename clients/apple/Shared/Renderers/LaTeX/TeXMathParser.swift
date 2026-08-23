enum TeXMathLimits {
    static let maxSourceUTF8Bytes = 64 * 1_024
    static let maxTokenCount = 8_192
    static let maxNestingDepth = 128
}

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
        parseValidated(source).nodes
    }

    /// Parse with a conservative validation preflight for graphical rendering.
    /// The parser still recovers partial ASTs for editing and diagnostics, while
    /// render callers can reject recovered or unsupported source deterministically.
    nonisolated func parseValidated(_ source: String) -> TeXMathParseResult {
        var diagnostics = TeXMathValidator.validate(source)
        if diagnostics.contains(where: { diagnostic in
            switch diagnostic {
            case .sourceTooLong, .nestingTooDeep:
                return true
            default:
                return false
            }
        }) {
            return TeXMathParseResult(nodes: [], diagnostics: diagnostics)
        }

        var state = ParserState(source: source)
        state.tokenize()
        guard state.tokens.count <= TeXMathLimits.maxTokenCount else {
            diagnostics.append(.tooManyTokens(max: TeXMathLimits.maxTokenCount))
            return TeXMathParseResult(nodes: [], diagnostics: diagnostics)
        }
        return TeXMathParseResult(
            nodes: state.parseTopLevel(),
            diagnostics: diagnostics
        )
    }
}

struct TeXMathParseResult: Equatable, Sendable {
    let nodes: [MathNode]
    let diagnostics: [TeXMathDiagnostic]

    var isRenderable: Bool {
        !nodes.isEmpty && diagnostics.isEmpty
    }
}

enum TeXMathDiagnostic: Equatable, Sendable {
    case unsupportedCommand(String)
    case unsupportedEnvironment(String)
    case missingArgument(command: String, position: Int)
    case unclosedGroup
    case unmatchedClosingBrace
    case unmatchedLeft
    case unmatchedRight
    case unclosedEnvironment(String)
    case mismatchedEnvironmentEnd(expected: String, found: String)
    case trailingBackslash
    case missingScriptBase(String)
    case duplicateScript(String)
    case missingDelimiter(command: String)
    case unsupportedDelimiter(command: String, delimiter: String)
    case sourceTooLong(maxUTF8Bytes: Int)
    case tooManyTokens(max: Int)
    case nestingTooDeep(max: Int)
}

/// Narrow validation layer for the supported renderer subset.
///
/// This is intentionally not a full TeX grammar. It verifies balanced groups,
/// mandatory arguments, supported commands/environments, and paired structural
/// delimiters before a recovered AST may become pixels. Valid TeX outside this
/// renderer's explicit subset falls back to exact source rather than being
/// approximated misleadingly.
private enum TeXMathValidator {
    private static let rowEnvironments = Set(["cases", "aligned", "gathered"])

    static func validate(_ source: String) -> [TeXMathDiagnostic] {
        guard source.utf8.count <= TeXMathLimits.maxSourceUTF8Bytes else {
            return [.sourceTooLong(maxUTF8Bytes: TeXMathLimits.maxSourceUTF8Bytes)]
        }

        var diagnostics: [TeXMathDiagnostic] = []
        var braceDepth = 0
        var environmentStack: [String] = []
        var leftDepth = 0
        var index = source.startIndex

        func append(_ diagnostic: TeXMathDiagnostic) {
            if !diagnostics.contains(diagnostic) {
                diagnostics.append(diagnostic)
            }
        }

        func validateNestingDepth() {
            if braceDepth + environmentStack.count + leftDepth > TeXMathLimits.maxNestingDepth {
                append(.nestingTooDeep(max: TeXMathLimits.maxNestingDepth))
            }
        }

        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                let commandStart = source.index(after: index)
                guard commandStart < source.endIndex else {
                    append(.trailingBackslash)
                    break
                }

                if source[commandStart] == "\\" {
                    index = source.index(after: commandStart)
                    continue
                }

                let commandEnd: String.Index
                let command: String
                if source[commandStart].isLetter {
                    commandEnd = source[commandStart...].firstIndex(where: { !$0.isLetter })
                        ?? source.endIndex
                    command = String(source[commandStart..<commandEnd])
                } else {
                    commandEnd = source.index(after: commandStart)
                    command = String(source[commandStart..<commandEnd])
                }

                if command == "text" {
                    let argument = argumentInfo(in: source, after: commandEnd)
                    if argument == nil || argument?.isEmpty == true {
                        append(.missingArgument(command: command, position: 1))
                    }
                    if let argument, argument.isBraced {
                        if !argument.isClosed {
                            append(.unclosedGroup)
                            break
                        }
                        index = argument.end
                        continue
                    }
                } else if command == "begin" || command == "end" {
                    let environment = bracedText(in: source, after: commandEnd)
                    guard let environment else {
                        append(.missingArgument(command: command, position: 1))
                        index = commandEnd
                        continue
                    }
                    if !isSupportedEnvironment(environment.value) {
                        append(.unsupportedEnvironment(environment.value))
                    }
                    if command == "begin" {
                        environmentStack.append(environment.value)
                        validateNestingDepth()
                    } else if let expected = environmentStack.last {
                        if expected == environment.value {
                            environmentStack.removeLast()
                        } else {
                            append(.mismatchedEnvironmentEnd(
                                expected: expected,
                                found: environment.value
                            ))
                        }
                    } else {
                        append(.mismatchedEnvironmentEnd(expected: "", found: environment.value))
                    }
                } else if command == "left" {
                    validateDelimiter(
                        command: command,
                        source: source,
                        after: commandEnd,
                        append: append
                    )
                    leftDepth += 1
                    validateNestingDepth()
                } else if command == "right" {
                    validateDelimiter(
                        command: command,
                        source: source,
                        after: commandEnd,
                        append: append
                    )
                    if leftDepth > 0 {
                        leftDepth -= 1
                    } else {
                        append(.unmatchedRight)
                    }
                } else if case .sizedDelimiter = MathSymbolTable.lookup(command) {
                    validateDelimiter(
                        command: command,
                        source: source,
                        after: commandEnd,
                        append: append
                    )
                } else if MathSymbolTable.lookup(command) == nil,
                          MathSymbolTable.escapedLiteral(for: command) == nil {
                    append(.unsupportedCommand(command))
                }

                switch MathSymbolTable.lookup(command) {
                case .fraction:
                    validateArguments(
                        command: command,
                        count: 2,
                        source: source,
                        after: commandEnd,
                        append: append
                    )
                case .sqrt:
                    var argumentStart = skipWhitespace(in: source, from: commandEnd)
                    if argumentStart < source.endIndex, source[argumentStart] == "[" {
                        if let close = matchingDelimiter(
                            in: source,
                            from: argumentStart,
                            open: "[",
                            close: "]"
                        ) {
                            argumentStart = source.index(after: close)
                        } else {
                            append(.unclosedGroup)
                        }
                    }
                    validateArguments(
                        command: command,
                        count: 1,
                        source: source,
                        after: argumentStart,
                        append: append
                    )
                case .accent, .font:
                    validateArguments(
                        command: command,
                        count: 1,
                        source: source,
                        after: commandEnd,
                        append: append
                    )
                default:
                    break
                }

                index = commandEnd
                continue
            }

            if character == "{" {
                braceDepth += 1
                validateNestingDepth()
            } else if character == "}" {
                if braceDepth == 0 {
                    append(.unmatchedClosingBrace)
                } else {
                    braceDepth -= 1
                }
            } else if character == "^" || character == "_" {
                let script = String(character)
                if !hasScriptBase(in: source, before: index) {
                    append(.missingScriptBase(script))
                } else {
                    validateScriptChain(
                        source: source,
                        startingAt: index,
                        append: append
                    )
                }
            }
            index = source.index(after: index)
        }

        if braceDepth > 0 {
            append(.unclosedGroup)
        }
        if leftDepth > 0 {
            append(.unmatchedLeft)
        }
        for environment in environmentStack.reversed() {
            append(.unclosedEnvironment(environment))
        }
        return diagnostics
    }

    private static func hasScriptBase(
        in source: String,
        before scriptIndex: String.Index
    ) -> Bool {
        var cursor = scriptIndex
        while cursor > source.startIndex {
            cursor = source.index(before: cursor)
            let character = source[cursor]
            if character.isWhitespace { continue }
            return !"^_{[(&+-*/=<>!,;:".contains(character) && character != "\\"
        }
        return false
    }

    private static func validateScriptChain(
        source: String,
        startingAt start: String.Index,
        append: (TeXMathDiagnostic) -> Void
    ) {
        var cursor = start
        var seen: Set<Character> = []

        while cursor < source.endIndex,
              (source[cursor] == "^" || source[cursor] == "_") {
            let script = source[cursor]
            if !seen.insert(script).inserted {
                append(.duplicateScript(String(script)))
            }

            let argumentStart = source.index(after: cursor)
            if let argument = argumentInfo(in: source, after: argumentStart),
               !argument.isEmpty {
                if argument.isBraced, !argument.isClosed {
                    append(.unclosedGroup)
                    return
                }
                cursor = skipWhitespace(in: source, from: argument.end)
            } else {
                append(.missingArgument(command: String(script), position: 1))
                cursor = skipWhitespace(in: source, from: argumentStart)
            }
        }
    }

    private struct DelimiterInfo {
        let source: String
        let isSupported: Bool
    }

    private static func validateDelimiter(
        command: String,
        source: String,
        after start: String.Index,
        append: (TeXMathDiagnostic) -> Void
    ) {
        let cursor = skipWhitespace(in: source, from: start)
        guard cursor < source.endIndex else {
            append(.missingDelimiter(command: command))
            return
        }

        let info: DelimiterInfo
        if source[cursor] == "\\" {
            let commandStart = source.index(after: cursor)
            guard commandStart < source.endIndex else {
                append(.missingDelimiter(command: command))
                return
            }
            let commandEnd: String.Index
            if source[commandStart].isLetter {
                commandEnd = source[commandStart...].firstIndex(where: { !$0.isLetter })
                    ?? source.endIndex
            } else {
                commandEnd = source.index(after: commandStart)
            }
            let name = String(source[commandStart..<commandEnd])
            let supported: Bool
            if let lookup = MathSymbolTable.lookup(name), case .delimiter = lookup {
                supported = true
            } else {
                supported = false
            }
            info = DelimiterInfo(source: "\\" + name, isSupported: supported)
        } else {
            let delimiter = source[cursor]
            info = DelimiterInfo(
                source: String(delimiter),
                isSupported: "()[]|.".contains(delimiter)
            )
        }

        if !info.isSupported {
            append(.unsupportedDelimiter(command: command, delimiter: info.source))
        }
    }

    private struct ArgumentInfo {
        let end: String.Index
        let isBraced: Bool
        let isClosed: Bool
        let isEmpty: Bool
    }

    private static func validateArguments(
        command: String,
        count: Int,
        source: String,
        after start: String.Index,
        append: (TeXMathDiagnostic) -> Void
    ) {
        var cursor = start
        for position in 1...count {
            guard let argument = argumentInfo(in: source, after: cursor),
                  !argument.isEmpty else {
                append(.missingArgument(command: command, position: position))
                return
            }
            if argument.isBraced, !argument.isClosed {
                append(.unclosedGroup)
                return
            }
            cursor = argument.end
        }
    }

    private static func argumentInfo(
        in source: String,
        after start: String.Index
    ) -> ArgumentInfo? {
        let cursor = skipWhitespace(in: source, from: start)
        guard cursor < source.endIndex else { return nil }
        if "^_}]&+-*/=<>!,;:".contains(source[cursor]) {
            return nil
        }

        if source[cursor] == "{" {
            guard let close = matchingDelimiter(
                in: source,
                from: cursor,
                open: "{",
                close: "}"
            ) else {
                return ArgumentInfo(
                    end: source.endIndex,
                    isBraced: true,
                    isClosed: false,
                    isEmpty: source.index(after: cursor) == source.endIndex
                )
            }
            let bodyStart = source.index(after: cursor)
            return ArgumentInfo(
                end: source.index(after: close),
                isBraced: true,
                isClosed: true,
                isEmpty: bodyStart == close
            )
        }

        if source[cursor] == "\\" {
            let next = source.index(after: cursor)
            guard next < source.endIndex else { return nil }
            if source[next].isLetter {
                let end = source[next...].firstIndex(where: { !$0.isLetter }) ?? source.endIndex
                return ArgumentInfo(end: end, isBraced: false, isClosed: true, isEmpty: false)
            }
            return ArgumentInfo(
                end: source.index(after: next),
                isBraced: false,
                isClosed: true,
                isEmpty: false
            )
        }

        return ArgumentInfo(
            end: source.index(after: cursor),
            isBraced: false,
            isClosed: true,
            isEmpty: false
        )
    }

    private static func bracedText(
        in source: String,
        after start: String.Index
    ) -> (value: String, end: String.Index)? {
        let cursor = skipWhitespace(in: source, from: start)
        guard cursor < source.endIndex, source[cursor] == "{",
              let close = matchingDelimiter(
                  in: source,
                  from: cursor,
                  open: "{",
                  close: "}"
              ) else {
            return nil
        }
        let bodyStart = source.index(after: cursor)
        return (String(source[bodyStart..<close]), source.index(after: close))
    }

    private static func matchingDelimiter(
        in source: String,
        from opening: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 0
        var cursor = opening
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "\\" {
                let next = source.index(after: cursor)
                if next < source.endIndex {
                    cursor = source.index(after: next)
                    continue
                }
            }
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func skipWhitespace(
        in source: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < source.endIndex, source[cursor].isWhitespace {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    private static func isSupportedEnvironment(_ name: String) -> Bool {
        MatrixStyle(rawValue: name) != nil || rowEnvironments.contains(name)
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
        if let literal = MathSymbolTable.escapedLiteral(for: name) {
            pos += 1
            return .text(literal)
        }

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

        case .sizedDelimiter:
            // Manual sizing aliases (\bigl, \Bigr, ...). Consume the next
            // delimiter and paint it as a literal. Do not pair with a mate.
            return parseSizedDelimiter()

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

    mutating func parseSizedDelimiter() -> MathNode? {
        let del = parseDelimiter()
        // \bigl. is an invisible delimiter — emit nothing.
        guard del != .none else { return nil }
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
        // Keep in lockstep with MathLayoutEngine.delimiterDisplayString.
        // A TeX rawValue here would paint as an italic command string.
        switch del {
        case .paren: return .variable("(")
        case .closeParen: return .variable(")")
        case .bracket: return .variable("[")
        case .closeBracket: return .variable("]")
        case .brace: return .variable("{")
        case .closeBrace: return .variable("}")
        case .pipe: return .variable("|")
        case .doublePipe: return .variable("\u{2016}")
        case .angle: return .variable("\u{27E8}")
        case .closeAngle: return .variable("\u{27E9}")
        case .none: return .variable("")
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
