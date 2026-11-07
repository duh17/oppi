/// The grammar of an Org planning line and of a timestamp, with source ranges.
///
/// The parser reads a heading's planning line through `parse`, and the reader's
/// task edits (`TaskSourceEdit`) rewrite the same line through the ranges it
/// returns, so both agree on which lines are planning lines and what a
/// timestamp is.
enum OrgPlanningLine {
    /// One `KEYWORD: timestamp` pair, located in the text it was parsed from.
    struct Entry: Equatable {
        let kind: OrgPlanningKind
        /// From the keyword through the timestamp's closing bracket.
        let range: Range<String.Index>
        /// The timestamp with its brackets.
        let timestampRange: Range<String.Index>
        let timestamp: OrgTimestamp
    }

    /// `SCHEDULED: <ts> DEADLINE: <ts> CLOSED: [ts]`. Every token on the line
    /// must belong to a planning entry; anything else is not a planning line,
    /// so prose that happens to start with `CLOSED:` is never swallowed.
    /// Leading whitespace is skipped.
    static func parse(_ text: String) -> [Entry]? {
        var entries: [Entry] = []
        var pos = text.startIndex

        func skipSpaces() {
            while pos < text.endIndex, text[pos] == " " || text[pos] == "\t" {
                pos = text.index(after: pos)
            }
        }

        skipSpaces()
        while pos < text.endIndex {
            let start = pos
            let rest = text[pos...]
            let kind: OrgPlanningKind
            let label: String
            if rest.hasPrefix("SCHEDULED:") {
                kind = .scheduled
                label = "SCHEDULED:"
            } else if rest.hasPrefix("DEADLINE:") {
                kind = .deadline
                label = "DEADLINE:"
            } else if rest.hasPrefix("CLOSED:") {
                kind = .closed
                label = "CLOSED:"
            } else {
                return nil
            }
            pos = text.index(pos, offsetBy: label.count)
            skipSpaces()
            guard pos < text.endIndex,
                  let (timestamp, end) = timestamp(in: text, at: pos) else { return nil }
            entries.append(Entry(
                kind: kind,
                range: start..<end,
                timestampRange: pos..<end,
                timestamp: timestamp
            ))
            pos = end
            skipSpaces()
        }
        return entries.isEmpty ? nil : entries
    }

    /// `<2026-11-11 Wed>` or `[2026-11-06 Fri 14:00 +1w]`: a date, then anything
    /// up to the matching bracket on the same line.
    static func timestamp(in text: String, at pos: String.Index) -> (OrgTimestamp, String.Index)? {
        let open = text[pos]
        let isActive = open == "<"
        guard isActive || open == "[" else { return nil }
        let close: Character = isActive ? ">" : "]"

        var idx = text.index(after: pos)
        for shape in "0000-00-00" {
            guard idx < text.endIndex else { return nil }
            let c = text[idx]
            if shape == "0" {
                guard c.isASCII, c.isNumber else { return nil }
            } else if c != shape {
                return nil
            }
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, text[idx] == close || text[idx] == " " else { return nil }

        while idx < text.endIndex {
            let c = text[idx]
            if c == close {
                let content = String(text[text.index(after: pos)..<idx])
                return (OrgTimestamp(isActive: isActive, text: content), text.index(after: idx))
            }
            if c == "<" || c == ">" || c == "[" || c == "]" { return nil }
            idx = text.index(after: idx)
        }
        return nil
    }
}
