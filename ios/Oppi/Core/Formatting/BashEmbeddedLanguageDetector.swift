/// Detects embedded language regions inside bash commands.
///
/// Bash commands from agents commonly embed full scripts via heredocs
/// (`node - <<'NODE'`) or inline flags (`python3 -c '...'`). This detector
/// splits the command into shell and embedded-code segments so each region
/// can receive language-appropriate syntax highlighting.
enum BashEmbeddedLanguageDetector {

    /// A contiguous region of a bash command.
    struct Segment: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case shell
            case embeddedCode(SyntaxLanguage)
        }

        let text: String
        let kind: Kind
    }

    /// Analyse a bash command string and return highlighting segments.
    ///
    /// Returns a single `.shell` segment when no embedded language is detected.
    static func detect(_ command: String) -> [Segment] {
        if let heredocResult = detectHeredoc(command) {
            return heredocResult
        }
        if let inlineResult = detectInlineFlag(command) {
            return inlineResult
        }
        return [Segment(text: command, kind: .shell)]
    }

    // MARK: - Heredoc Detection

    /// Matches heredoc patterns like `<<'NODE'`, `<<"EOF"`, `<<PYTHON`, `<<-RUBY`.
    ///
    /// Captures:
    /// - Everything up to and including the heredoc start line → shell
    /// - The heredoc body → embedded code
    /// - The closing marker line → shell
    /// - Any trailing content after the marker → shell
    private static func detectHeredoc(_ command: String) -> [Segment]? {
        // Find `<<` followed by optional `-`, optional quotes, then a marker word.
        // The marker must be at least 2 characters to avoid false positives.
        guard let heredocRange = command.range(
            of: #"<<-?\s*['"]?([A-Za-z_]\w{1,})['"]?"#,
            options: .regularExpression
        ) else {
            return nil
        }

        // Extract the marker name (strip quotes and <<- prefix)
        let heredocToken = command[heredocRange]
        let markerName = extractMarkerName(String(heredocToken))
        guard !markerName.isEmpty else { return nil }

        // Find the end of the heredoc start line
        let afterHeredoc = heredocRange.upperBound
        guard let startLineEnd = command[afterHeredoc...].firstIndex(of: "\n") else {
            // No body — just a single line, treat as plain shell
            return nil
        }

        let bodyStart = command.index(after: startLineEnd)

        // Find the closing marker: a line that is exactly the marker name
        // (with optional leading whitespace for <<- form).
        let body = command[bodyStart...]
        guard let markerLineRange = findClosingMarker(in: body, marker: markerName) else {
            // Unclosed heredoc — highlight body from heredoc start to end as embedded
            let language = detectLanguageFromCommandPrefix(command, beforeHeredoc: heredocRange.lowerBound)
            guard let language, language != .unknown else { return nil }

            let shellPrefix = String(command[..<bodyStart])
            let embeddedBody = String(command[bodyStart...])
            guard !embeddedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return [
                Segment(text: shellPrefix, kind: .shell),
                Segment(text: embeddedBody, kind: .embeddedCode(language)),
            ]
        }

        let language = detectLanguageFromCommandPrefix(command, beforeHeredoc: heredocRange.lowerBound)
        guard let language, language != .unknown else { return nil }

        var segments: [Segment] = []

        // Shell: everything up to and including the heredoc start line
        let shellPrefix = String(command[..<bodyStart])
        segments.append(Segment(text: shellPrefix, kind: .shell))

        // Embedded code body (between start line and closing marker)
        let embeddedBody = String(command[bodyStart..<markerLineRange.lowerBound])
        if !embeddedBody.isEmpty {
            segments.append(Segment(text: embeddedBody, kind: .embeddedCode(language)))
        }

        // Shell: closing marker + anything after
        let shellSuffix = String(command[markerLineRange.lowerBound...])
        if !shellSuffix.isEmpty {
            segments.append(Segment(text: shellSuffix, kind: .shell))
        }

        return segments
    }

    /// Extract the marker name from a heredoc token like `<<'NODE'` or `<<-"EOF"`.
    private static func extractMarkerName(_ token: String) -> String {
        var s = token[token.startIndex...]

        // Skip <<
        guard s.hasPrefix("<<") else { return "" }
        s = s.dropFirst(2)

        // Skip optional -
        if s.hasPrefix("-") { s = s.dropFirst() }

        // Skip optional whitespace
        while s.first?.isWhitespace == true { s = s.dropFirst() }

        // Skip optional opening quote
        if s.first == "'" || s.first == "\"" { s = s.dropFirst() }

        // Read the marker word
        var marker = ""
        for c in s {
            if c.isLetter || c.isNumber || c == "_" {
                marker.append(c)
            } else {
                break
            }
        }
        return marker
    }

    /// Find a line in `body` that consists of exactly `marker` (with optional
    /// leading whitespace for `<<-` heredocs).
    private static func findClosingMarker(
        in body: Substring,
        marker: String
    ) -> Range<String.Index>? {
        var searchStart = body.startIndex

        while searchStart < body.endIndex {
            // Find next occurrence of the marker text
            guard let markerRange = body[searchStart...].range(of: marker) else {
                return nil
            }

            // Check that the marker is at the start of a line (possibly with leading whitespace)
            let lineStart = lineStartIndex(in: body, before: markerRange.lowerBound)
            let prefix = body[lineStart..<markerRange.lowerBound]
            let isLineStart = prefix.allSatisfy { $0 == " " || $0 == "\t" }

            // Check that nothing follows the marker on the same line (except newline/end)
            let afterMarker = markerRange.upperBound
            let isLineEnd = afterMarker >= body.endIndex
                || body[afterMarker] == "\n"

            if isLineStart && isLineEnd {
                return lineStart..<(afterMarker < body.endIndex ? body.index(after: afterMarker) : afterMarker)
            }

            searchStart = markerRange.upperBound
        }

        return nil
    }

    private static func lineStartIndex(in text: Substring, before index: String.Index) -> String.Index {
        var i = index
        while i > text.startIndex {
            let prev = text.index(before: i)
            if text[prev] == "\n" { return i }
            i = prev
        }
        return text.startIndex
    }

    // MARK: - Inline Flag Detection (-e / -c)

    /// Detects `<interpreter> -e '...'` or `<interpreter> -c '...'` patterns.
    ///
    /// Handles both single-quoted and double-quoted inline script bodies.
    private static func detectInlineFlag(_ command: String) -> [Segment]? {
        // Match: <command> <options> -e|-c <space> <quote> ... <quote>
        // We look for -e or -c followed by a quoted body.
        guard let flagRange = command.range(
            of: #"\s-[ec]\s+(['"])"#,
            options: .regularExpression
        ) else {
            return nil
        }

        // Determine language from the command prefix
        let prefixEnd = flagRange.lowerBound
        let language = detectLanguageFromInlinePrefix(command, beforeFlag: prefixEnd)
        guard let language, language != .unknown else { return nil }

        // Find the quoted body
        let quoteChar = command[command.index(before: flagRange.upperBound)]
        let bodyStart = flagRange.upperBound // character after the opening quote
        guard bodyStart < command.endIndex else { return nil }

        // Scan for matching closing quote (respecting backslash escapes)
        var i = bodyStart
        while i < command.endIndex {
            if command[i] == "\\" {
                // Skip escaped character
                i = command.index(after: i)
                if i < command.endIndex {
                    i = command.index(after: i)
                }
                continue
            }
            if command[i] == quoteChar {
                // Found closing quote
                let shellBefore = String(command[command.startIndex..<flagRange.upperBound])
                let embedded = String(command[bodyStart..<i])
                guard !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let shellAfter = String(command[i..<command.endIndex])

                return [
                    Segment(text: shellBefore, kind: .shell),
                    Segment(text: embedded, kind: .embeddedCode(language)),
                    Segment(text: shellAfter, kind: .shell),
                ]
            }
            i = command.index(after: i)
        }

        // Unclosed quote — treat everything after as embedded
        let shellBefore = String(command[command.startIndex..<flagRange.upperBound])
        let embedded = String(command[bodyStart...])
        guard !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return [
            Segment(text: shellBefore, kind: .shell),
            Segment(text: embedded, kind: .embeddedCode(language)),
        ]
    }

    // MARK: - Language Detection from Command

    /// Map interpreter names found before a heredoc to syntax languages.
    private static let interpreterMap: [(pattern: String, language: SyntaxLanguage)] = [
        ("node", .javascript),
        ("npx", .javascript),
        ("deno", .typescript),
        ("bun", .javascript),
        ("python3", .python),
        ("python", .python),
        ("ruby", .ruby),
        ("swift", .swift),
        ("go", .go),
        ("rustc", .rust),
        ("perl", .unknown), // no perl highlighting yet
        ("sqlite3", .sql),
        ("psql", .sql),
        ("mysql", .sql),
    ]

    /// Detect language from the command text before a heredoc start marker.
    ///
    /// Scans the text for known interpreter names. For example, in
    /// `node - <<'NODE'`, the presence of `node` maps to JavaScript.
    private static func detectLanguageFromCommandPrefix(
        _ command: String,
        beforeHeredoc: String.Index
    ) -> SyntaxLanguage? {
        let prefix = String(command[command.startIndex..<beforeHeredoc]).lowercased()
        return matchInterpreter(in: prefix)
    }

    /// Detect language from the command prefix before an inline flag (-e/-c).
    private static func detectLanguageFromInlinePrefix(
        _ command: String,
        beforeFlag: String.Index
    ) -> SyntaxLanguage? {
        let prefix = String(command[command.startIndex...beforeFlag]).lowercased()
        return matchInterpreter(in: prefix)
    }

    /// Find the first matching interpreter name in a text fragment.
    private static func matchInterpreter(in text: String) -> SyntaxLanguage? {
        // Check each interpreter — order matters (python3 before python)
        for (pattern, language) in interpreterMap {
            // Match the interpreter as a word boundary: preceded by start/space/slash,
            // followed by end/space/newline (avoids matching "golem" as "go").
            if let range = text.range(of: pattern) {
                let beforeOk = range.lowerBound == text.startIndex
                    || { let c = text[text.index(before: range.lowerBound)]; return c == " " || c == "/" || c == "\n" || c == "|" || c == ";" }()
                let afterOk = range.upperBound == text.endIndex
                    || { let c = text[range.upperBound]; return c == " " || c == "\n" || c == "\t" }()
                if beforeOk && afterOk {
                    return language
                }
            }
        }
        // Also check for the heredoc marker name itself as a language hint
        return nil
    }

    // MARK: - Convenience

    /// Returns the detected embedded language, if any.
    static func embeddedLanguage(in command: String) -> SyntaxLanguage? {
        let segments = detect(command)
        return segments.first(where: {
            if case .embeddedCode = $0.kind { return true }
            return false
        }).flatMap {
            if case .embeddedCode(let lang) = $0.kind { return lang }
            return nil
        }
    }
}
