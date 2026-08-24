import Foundation

// MARK: - Timeline diagram types
//
// The AST types live here instead of MermaidNode.swift so timeline work can
// land in parallel with other diagram types. Integrator hook:
//
//   MermaidDiagram:            case timeline(TimelineDiagram)
//   parseHeader:               case "timeline": .timeline
//   parse():                   MermaidTimelineParser.parse(lines: body)
//   renderer dispatch:         MermaidTimelineRenderer.layout(diagram, configuration:)

/// Direction declared after the `timeline` / `timeline-beta` keyword (v11.14.0+).
///
/// Official grammar accepts only `LR` (default) and `TD`. Any other leftover
/// header token is period text, not a silent fallback direction.
enum TimelineDirection: String, Equatable, Sendable {
    case LR
    case TD
}

/// A time period on the spine with its events stacked in source order.
///
/// Both the period label and events are free text, not limited to numbers.
struct TimelinePeriod: Equatable, Sendable {
    let label: String
    let events: [String]

    init(label: String, events: [String] = []) {
        self.label = label
        self.events = events
    }
}

/// A group of time periods. `name == nil` is the implicit section that holds
/// periods declared before any `section` keyword.
struct TimelineSection: Equatable, Sendable {
    let name: String?
    let periods: [TimelinePeriod]

    init(name: String?, periods: [TimelinePeriod]) {
        self.name = name
        self.periods = periods
    }
}

struct TimelineDiagram: Equatable, Sendable {
    let title: String?
    let direction: TimelineDirection
    let sections: [TimelineSection]

    init(
        title: String?,
        direction: TimelineDirection = .LR,
        sections: [TimelineSection]
    ) {
        self.title = title
        self.direction = direction
        self.sections = sections
    }

    static let empty = TimelineDiagram(title: nil, sections: [])
}

// MARK: - Parser

/// Parser for Mermaid timeline syntax.
///
/// SPEC: https://mermaid.js.org/syntax/timeline.html
/// Grammar reference (authoritative at fetch time; mermaid stopped tagging
/// releases after v11.0.0, so develop matches the v11.17-era spec page):
/// https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/diagrams/timeline/parser/timeline.jison
///
/// Handles:
/// - `title <text>`
/// - `section <name>` (name stops at a colon, like the official lexer)
/// - `<period> : <event>` with one or more inline events (`p : e1 : e2`)
/// - continuation lines starting with `:` that add events to the previous period
/// - bare text lines, which are periods with no events
/// - periods before any `section`, collected into an implicit unnamed section
/// - `%%` comments and full-line `#` comments
/// - the `timeline` / `timeline-beta` header line with optional `LR`/`TD`
///   when callers pass it through (the shared parser keeps the keyword)
///
/// Event splitting follows the official grammar: a colon separates events
/// only when followed by whitespace or end of line, so embedded colons such
/// as `10:30` stay inside the event text.
///
/// Intentional divergences from the jison lexer, both documented upstream
/// as bugs (mermaid-js/mermaid#4175): `#` inside period/event/title text is
/// kept instead of truncating the line, and events tolerate missing space
/// after the colon instead of failing the parse.
///
/// Icon integration is experimental upstream and intentionally not parsed.
enum MermaidTimelineParser {

    nonisolated static func parse(lines: [String]) -> TimelineDiagram {
        var state = ParseState()

        for rawLine in lines {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Official grammar: `#` starts a comment. Only full-line comments
            // are skipped; inline `#` is kept (see divergence note above).
            if line.hasPrefix("#") { continue }

            // Multi-line `accDescr { ... }` block: skip until the closing brace.
            if state.inAccDescrBlock {
                if line.contains("}") { state.inAccDescrBlock = false }
                continue
            }

            // The shared parser keeps the `timeline` / `timeline-beta` header
            // so this parser can read official `LR` / `TD`. Leftover tokens
            // that are not those two directions become period text.
            if !state.headerChecked {
                state.headerChecked = true
                if let header = consumeTimelineHeader(line) {
                    switch header {
                    case .empty:
                        break
                    case .direction(let dir):
                        state.direction = dir
                    case .leftover(let rest):
                        handleStatement(rest, state: &state)
                    }
                    continue
                }
                if let dir = TimelineDirection(rawValue: line.uppercased()) {
                    state.direction = dir
                    continue
                }
            }

            handleStatement(line, state: &state)
        }

        flushSection(state: &state)

        return TimelineDiagram(
            title: state.title,
            direction: state.direction,
            sections: state.sections
        )
    }

    // MARK: - Parse state

    private struct ParseState {
        var title: String?
        var direction = TimelineDirection.LR
        var sections: [TimelineSection] = []
        var currentSectionName: String?
        var currentPeriods: [TimelinePeriod] = []
        var headerChecked = false
        var inAccDescrBlock = false
    }

    // MARK: - Statement handling

    private static func handleStatement(_ line: String, state: inout ParseState) {
        // Official grammar recognizes only `accTitle:`, `accDescr:`, and
        // `accDescr {`. A period such as `accTitle rollout : shipped` must
        // still parse as content.
        if let directive = accessibilityDirective(line) {
            if directive == .block, !line.contains("}") {
                state.inAccDescrBlock = true
            }
            return
        }

        if let value = keywordValue(line, keyword: "title") {
            state.title = sanitizeText(value)
            return
        }

        if let value = keywordValue(line, keyword: "section") {
            flushSection(state: &state)
            // Official section names stop at a colon: `"section"\s[^:\n]+`.
            let name = sanitizeText(String(value.prefix(while: { $0 != ":" })))
            state.currentSectionName = name.isEmpty ? nil : name
            return
        }

        // Period / event line.
        guard let colonIndex = line.firstIndex(of: ":") else {
            // Bare text line: a period with no events.
            let label = sanitizeText(line)
            if !label.isEmpty {
                state.currentPeriods.append(TimelinePeriod(label: label))
            }
            return
        }

        let periodText = sanitizeText(String(line[line.startIndex..<colonIndex]))
        let events = splitEvents(String(line[line.index(after: colonIndex)...]))

        if periodText.isEmpty {
            // Continuation line `: event` — attach to the previous period.
            // Orphan events before any period are dropped; upstream this
            // is a hard parse error.
            guard !events.isEmpty, let last = state.currentPeriods.last else { return }
            state.currentPeriods[state.currentPeriods.count - 1] = TimelinePeriod(
                label: last.label,
                events: last.events + events
            )
        } else {
            state.currentPeriods.append(TimelinePeriod(label: periodText, events: events))
        }
    }

    /// Flush accumulated periods into a section. Declared sections with no
    /// periods are dropped: they would draw nothing.
    private static func flushSection(state: inout ParseState) {
        guard !state.currentPeriods.isEmpty else { return }
        state.sections.append(
            TimelineSection(name: state.currentSectionName, periods: state.currentPeriods)
        )
        state.currentPeriods = []
    }

    // MARK: - Header

    private enum TimelineHeader {
        case empty
        case direction(TimelineDirection)
        case leftover(String)
    }

    /// Official jison: `timeline`, `timeline LR`, `timeline TD`.
    /// `timeline-beta` is accepted as an alias. Any other leftover token
    /// is period text, matching the official lexer.
    private static func consumeTimelineHeader(_ line: String) -> TimelineHeader? {
        let lower = line.lowercased()
        for keyword in ["timeline-beta", "timeline"] {
            if lower == keyword { return .empty }
            if lower.hasPrefix(keyword + " ") || lower.hasPrefix(keyword + "\t") {
                let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty { return .empty }
                if let dir = TimelineDirection(rawValue: rest.uppercased()) {
                    return .direction(dir)
                }
                return .leftover(rest)
            }
        }
        return nil
    }

    // MARK: - Line helpers

    private enum AccessibilityDirective {
        case singleLine
        case block
    }

    /// Official lexer: `accTitle\s*":"`, `accDescr\s*":"`, `accDescr\s*"{"`.
    private static func accessibilityDirective(_ line: String) -> AccessibilityDirective? {
        let lower = line.lowercased()
        if matchesKeywordThenMarker(lower, keyword: "acctitle", marker: ":") {
            return .singleLine
        }
        if matchesKeywordThenMarker(lower, keyword: "accdescr", marker: "{") {
            return .block
        }
        if matchesKeywordThenMarker(lower, keyword: "accdescr", marker: ":") {
            return .singleLine
        }
        return nil
    }

    private static func matchesKeywordThenMarker(
        _ lowercasedLine: String,
        keyword: String,
        marker: Character
    ) -> Bool {
        guard lowercasedLine.hasPrefix(keyword) else { return false }
        let rest = lowercasedLine[lowercasedLine.index(
            lowercasedLine.startIndex,
            offsetBy: keyword.count
        )...]
        return rest.drop(while: { $0.isWhitespace }).first == marker
    }

    /// Match a case-insensitive keyword followed by whitespace and a value,
    /// mirroring the official lexer rules `"title"\s[^\n]+` and
    /// `"section"\s[^:\n]+`. A bare keyword with no value falls through and
    /// is treated as period text, same as upstream.
    private static func keywordValue(_ line: String, keyword: String) -> String? {
        guard line.lowercased().hasPrefix(keyword) else { return nil }
        let rest = line[line.index(line.startIndex, offsetBy: keyword.count)...]
        guard let first = rest.first, first.isWhitespace else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Split the event portion of a line on colons that are followed by
    /// whitespace or end of line. Colons inside event text (clock times,
    /// `key:value`) survive, matching the official event token
    /// `":"\s(?:[^:\n]|":"(?!\s))+`.
    private static func splitEvents(_ text: String) -> [String] {
        var events: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == ":" {
                let isBoundary = i + 1 >= chars.count || chars[i + 1].isWhitespace
                if isBoundary {
                    events.append(sanitizeText(current))
                    current = ""
                    i += 1
                    continue
                }
            }
            current.append(char)
            i += 1
        }
        events.append(sanitizeText(current))
        return events.filter { !$0.isEmpty }
    }

    /// Normalize one piece of timeline text.
    ///
    /// SPEC: `<br>` forces a line break in long periods and events.
    private static func sanitizeText(_ text: String) -> String {
        MermaidTextUtils.normalizeBrTags(text).trimmingCharacters(in: .whitespaces)
    }

    /// Remove a `%%` comment, ignoring `%%` inside double quotes.
    /// Mirrors the shared MermaidParser behavior for direct callers.
    private static func stripComment(_ line: String) -> String {
        var inDoubleQuote = false
        let chars = Array(line)
        for i in 0..<chars.count {
            if chars[i] == "\"" { inDoubleQuote.toggle() }
            if !inDoubleQuote, i + 1 < chars.count, chars[i] == "%", chars[i + 1] == "%" {
                return String(chars[0..<i])
            }
        }
        return line
    }
}
