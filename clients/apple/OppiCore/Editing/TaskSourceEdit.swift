import Foundation

/// The reader's task edits, as rewrites of the source lines they come from.
///
/// Every function takes the whole document and a 1-based line, and returns the
/// document with only the lines that edit owns changed (nil when the line is no
/// longer what the reader drew). Nothing else is reformatted: the text is split
/// on `\n` and joined again, a line's own `\r` stays, and an edited line keeps
/// its spacing outside the bytes that change.
enum TaskSourceEdit {
    enum Dialect: Sendable {
        case markdown
        case org
    }

    // MARK: - Checkbox

    /// Flips the checkbox on `line`: `[ ]` and `[-]` become checked (`[X]` in
    /// Org, `[x]` in Markdown), a checked box becomes `[ ]`. The progress cookie
    /// of the list item above it, or else of the heading over it, is
    /// recounted when it covers this list.
    static func toggleCheckbox(in source: String, line: Int, dialect: Dialect) -> String? {
        var lines = Lines(source)
        if dialect == .org { lines.keywords = OrgParser().todoKeywords(in: source) }
        guard lines.rows.indices.contains(line - 1),
              let item = listItem(lines.body(line - 1), dialect: dialect),
              let box = item.box else { return nil }
        let replacement: Character = item.isChecked ? " " : (dialect == .org ? "X" : "x")
        var text = String(lines.body(line - 1))
        let at = text.index(text.startIndex, offsetBy: lines.body(line - 1).distance(from: lines.body(line - 1).startIndex, to: box))
        text.replaceSubrange(at...at, with: String(replacement))
        lines.replace(line - 1, with: text)
        updateCookies(after: line - 1, in: &lines, dialect: dialect)
        return lines.text
    }

    /// Whether the box on `line` is checked; nil when `line` has none.
    static func isChecked(in source: String, line: Int, dialect: Dialect) -> Bool? {
        let lines = Lines(source)
        guard lines.rows.indices.contains(line - 1),
              let item = listItem(lines.body(line - 1), dialect: dialect),
              item.box != nil else { return nil }
        return item.isChecked
    }

    // MARK: - Org TODO state

    /// The keyword on the heading at `line`, or nil without one (or when
    /// `line` is no heading).
    static func state(in source: String, headingLine line: Int, keywords: OrgTodoKeywords) -> String? {
        let lines = Lines(source)
        guard lines.rows.indices.contains(line - 1) else { return nil }
        return orgHeading(lines.body(line - 1), keywords: keywords)?.keyword
    }

    /// Moves the heading at `line` to `keyword` (nil removes the state).
    /// Moving into a done state writes `CLOSED: [YYYY-MM-DD Day HH:MM]` on the
    /// planning line under the heading, and moving out of one removes it; the
    /// rest of that line stays as it was. A move between two done states, or two
    /// open ones, leaves the planning line alone.
    static func setState(
        in source: String,
        headingLine line: Int,
        to keyword: String?,
        keywords: OrgTodoKeywords,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        var lines = Lines(source)
        guard lines.rows.indices.contains(line - 1),
              let heading = orgHeading(lines.body(line - 1), keywords: keywords) else { return nil }
        if let keyword, keyword.isEmpty || keyword.contains(where: \.isWhitespace) { return nil }
        guard heading.keyword != keyword else { return source }

        let wasDone = heading.keyword.map(keywords.isDone) ?? false
        let isDone = keyword.map(keywords.isDone) ?? false

        var text = String(heading.prefix)
        if let keyword {
            text += keyword
            if !heading.rest.isEmpty { text += " " }
        }
        lines.replace(line - 1, with: text + heading.rest)
        if isDone, !wasDone {
            setPlanning(.closed, at: line - 1, in: &lines, value: closedText(now: now, calendar: calendar))
        } else if wasDone, !isDone {
            setPlanning(.closed, at: line - 1, in: &lines, value: nil)
        }
        return lines.text
    }

    /// `[2026-11-06 Fri 14:00]`.
    static func closedText(now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let value = OrgDateValue(
            year: parts.year ?? 1970,
            month: parts.month ?? 1,
            day: parts.day ?? 1,
            time: (parts.hour ?? 0, parts.minute ?? 0)
        )
        return "[" + value.orgText + "]"
    }

    // MARK: - Org dates

    /// A date, and a time when the stamp has one.
    struct OrgDateValue: Equatable, Sendable {
        var year: Int
        var month: Int
        var day: Int
        var time: (hour: Int, minute: Int)?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
                && lhs.time?.hour == rhs.time?.hour && lhs.time?.minute == rhs.time?.minute
        }

        private static let weekdays = ["Sat", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri"]

        /// Three-letter English weekday, as Org writes it in the C locale
        /// (Zeller's congruence, so no calendar or locale is involved).
        var weekday: String {
            let m = month < 3 ? month + 12 : month
            let y = month < 3 ? year - 1 : year
            let h = (day + (13 * (m + 1)) / 5 + y % 100 + (y % 100) / 4 + (y / 100) / 4 + 5 * (y / 100)) % 7
            return Self.weekdays[h]
        }

        /// `2026-11-11 Wed` or `2026-11-11 Wed 09:30`, without brackets.
        var orgText: String {
            var text = String(format: "%04d-%02d-%02d %@", year, month, day, weekday)
            if let time { text += String(format: " %02d:%02d", time.hour, time.minute) }
            return text
        }
    }

    /// The date of the Scheduled or Deadline entry on the planning line under
    /// the heading at `line`, or nil without one.
    static func planningDate(in source: String, headingLine line: Int, kind: OrgPlanningKind) -> OrgDateValue? {
        let lines = Lines(source)
        guard let planning = planningLine(under: line - 1, in: lines),
              let entry = planning.entries.first(where: { $0.kind == kind }) else { return nil }
        return OrgDateValue(timestampText: entry.timestamp.text)
    }

    /// Sets the Scheduled or Deadline date of the heading at `line`, or clears
    /// it when `value` is nil. An existing stamp keeps its brackets, repeater and
    /// warning period; a new entry joins the heading's planning line, which is
    /// created under the heading when it has none.
    static func setPlanningDate(
        in source: String,
        headingLine line: Int,
        kind: OrgPlanningKind,
        to value: OrgDateValue?
    ) -> String? {
        guard kind != .closed else { return nil }
        var lines = Lines(source)
        guard lines.rows.indices.contains(line - 1), isOrgHeading(lines.body(line - 1)) else { return nil }
        setPlanning(kind, at: line - 1, in: &lines, value: value.map { "<" + $0.orgText + ">" }, keepsSuffix: true)
        return lines.text
    }

    // MARK: - Planning line

    /// Writes (or removes, for a nil `value`) one entry of the planning line
    /// under the heading at row `heading`. `value` is a whole stamp with its
    /// brackets. With `keepsSuffix`, the repeater and warning tokens of the
    /// stamp being replaced move into the new one.
    private static func setPlanning(
        _ kind: OrgPlanningKind,
        at heading: Int,
        in lines: inout Lines,
        value: String?,
        keepsSuffix: Bool = false
    ) {
        let row = heading + 1
        let planning = planningLine(under: heading, in: lines)
        let existing = planning?.entries.first { $0.kind == kind }

        guard let planning else {
            // No planning line: a new one under the heading, at its indent.
            guard let value else { return }
            let indent = String(lines.body(heading).prefix(while: { $0 == " " || $0 == "\t" }))
            lines.rows.insert(indent + kind.keyword + " " + value + lines.cr(heading), at: row)
            return
        }

        var text = planning.text
        switch (existing, value) {
        case let (existing?, value?):
            var stamp = String(value.dropFirst().dropLast())
            if keepsSuffix, let suffix = suffix(ofStamp: existing.timestamp.text) { stamp += " " + suffix }
            // Keeps the stamp's own bracket shape when it had one.
            let (open, close) = existing.timestamp.isActive ? ("<", ">") : ("[", "]")
            text.replaceSubrange(existing.timestampRange, with: open + stamp + close)
        case let (existing?, nil):
            text = removing(existing, from: text)
        case let (nil, value?):
            // CLOSED leads, as Org writes it; the others follow what is there.
            if kind == .closed {
                text = planning.indent + kind.keyword + " " + value + " " + String(text.dropFirst(planning.indent.count))
            } else {
                text += " " + kind.keyword + " " + value
            }
        case (nil, nil):
            break
        }
        lines.replace(row, with: text)
        if text.allSatisfy(\.isWhitespace) {
            lines.rows.remove(at: row)
        }
    }

    /// `+1w -2d` of `2026-11-12 Thu 09:00 +1w -2d`: what follows the date,
    /// weekday and time.
    private static func suffix(ofStamp text: String) -> String? {
        let tokens = text.split(separator: " ").dropFirst().filter { token in
            guard let first = token.first else { return false }
            if first.isLetter { return false }
            if first.isNumber, token.contains(":") { return false }
            return true
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }

    /// `text` without `entry`, and the gap that held it.
    private static func removing(_ entry: OrgPlanningLine.Entry, from text: String) -> String {
        var range = entry.range
        if entry.range.upperBound < text.endIndex {
            // Take the spaces after it, so the next entry closes up.
            while range.upperBound < text.endIndex, text[range.upperBound] == " " || text[range.upperBound] == "\t" {
                range = range.lowerBound..<text.index(after: range.upperBound)
            }
        } else {
            // The last entry takes the spaces before it instead.
            while range.lowerBound > text.startIndex {
                let previous = text.index(before: range.lowerBound)
                guard text[previous] == " " || text[previous] == "\t" else { break }
                range = previous..<range.upperBound
            }
        }
        var result = text
        result.removeSubrange(range)
        return result
    }

    private struct PlanningRow {
        let text: String
        let indent: String
        let entries: [OrgPlanningLine.Entry]
    }

    /// The planning line directly under the heading at row `heading`.
    private static func planningLine(under heading: Int, in lines: Lines) -> PlanningRow? {
        let row = heading + 1
        guard lines.rows.indices.contains(heading), lines.rows.indices.contains(row),
              isOrgHeading(lines.body(heading)) else { return nil }
        let text = String(lines.body(row))
        guard let entries = OrgPlanningLine.parse(text) else { return nil }
        return PlanningRow(
            text: text,
            indent: String(text.prefix(while: { $0 == " " || $0 == "\t" })),
            entries: entries
        )
    }

    // MARK: - Headings

    private struct OrgHeading {
        /// Leading whitespace, the stars and the one space after them.
        let prefix: Substring
        let keyword: String?
        /// What follows the keyword and its space.
        let rest: Substring
        let level: Int
    }

    private static func orgHeading(_ line: Substring, keywords: OrgTodoKeywords) -> OrgHeading? {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        let starsStart = i
        while i < line.endIndex, line[i] == "*" { i = line.index(after: i) }
        let level = line.distance(from: starsStart, to: i)
        guard level > 0, i < line.endIndex, line[i] == " " else { return nil }
        let bodyStart = line.index(after: i)
        let body = line[bodyStart...]
        for candidate in keywords.all where body.hasPrefix(candidate) {
            let after = body.index(body.startIndex, offsetBy: candidate.count)
            if after == body.endIndex || body[after] == " " {
                let rest = after < body.endIndex ? body[body.index(after: after)...] : body[after...]
                return OrgHeading(prefix: line[..<bodyStart], keyword: candidate, rest: rest, level: level)
            }
        }
        return OrgHeading(prefix: line[..<bodyStart], keyword: nil, rest: body, level: level)
    }

    private static func isOrgHeading(_ line: Substring) -> Bool {
        orgHeading(line, keywords: OrgTodoKeywords(active: [], done: [])) != nil
    }

    private static func markdownHeadingLevel(_ line: Substring) -> Int? {
        var i = line.startIndex
        var spaces = 0
        while i < line.endIndex, line[i] == " ", spaces < 3 { i = line.index(after: i); spaces += 1 }
        let start = i
        while i < line.endIndex, line[i] == "#" { i = line.index(after: i) }
        let level = line.distance(from: start, to: i)
        guard (1...6).contains(level) else { return nil }
        guard i == line.endIndex || line[i] == " " || line[i] == "\t" else { return nil }
        return level
    }

    // MARK: - List items

    private struct ListItem {
        /// Columns of leading whitespace, after any Markdown quote marker.
        let indent: Int
        /// The character between `[` and `]`, when the item has a checkbox.
        let box: String.Index?
        let boxCharacter: Character?

        var isChecked: Bool { boxCharacter == "x" || boxCharacter == "X" }
    }

    private static func listItem(_ line: Substring, dialect: Dialect) -> ListItem? {
        var i = line.startIndex
        if dialect == .markdown {
            // `> - [ ] task`: the quote marker is not indentation.
            while true {
                var j = i
                var spaces = 0
                while j < line.endIndex, line[j] == " ", spaces < 3 { j = line.index(after: j); spaces += 1 }
                guard j < line.endIndex, line[j] == ">" else { break }
                i = line.index(after: j)
                if i < line.endIndex, line[i] == " " { i = line.index(after: i) }
            }
        }
        var indent = 0
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            indent += line[i] == "\t" ? 4 : 1
            i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        let marker = line[i]
        var markerEnd: String.Index
        if marker == "-" || marker == "+" || (dialect == .markdown && marker == "*") {
            markerEnd = line.index(after: i)
        } else if marker.isASCII, marker.isNumber {
            markerEnd = i
            while markerEnd < line.endIndex, line[markerEnd].isASCII, line[markerEnd].isNumber {
                markerEnd = line.index(after: markerEnd)
            }
            guard markerEnd < line.endIndex, line[markerEnd] == "." || line[markerEnd] == ")" else { return nil }
            markerEnd = line.index(after: markerEnd)
        } else {
            return nil
        }
        guard markerEnd < line.endIndex, line[markerEnd] == " " || line[markerEnd] == "\t" else { return nil }
        var k = markerEnd
        while k < line.endIndex, line[k] == " " || line[k] == "\t" { k = line.index(after: k) }
        if k < line.endIndex, line[k] == "[" {
            let box = line.index(after: k)
            if box < line.endIndex, " xX-".contains(line[box]) {
                let close = line.index(after: box)
                if close < line.endIndex, line[close] == "]" {
                    let after = line.index(after: close)
                    if after == line.endIndex || line[after] == " " || line[after] == "\t" {
                        return ListItem(indent: indent, box: box, boxCharacter: line[box])
                    }
                }
            }
        }
        return ListItem(indent: indent, box: nil, boxCharacter: nil)
    }

    private static func leadingColumns(_ line: Substring) -> Int {
        var columns = 0
        for character in line {
            guard character == " " || character == "\t" else { break }
            columns += character == "\t" ? 4 : 1
        }
        return columns
    }

    // MARK: - Progress cookies

    /// Recounts the cookie the checkbox at row `row` is counted by: its parent
    /// list item's, or else its heading's.
    private static func updateCookies(after row: Int, in lines: inout Lines, dialect: Dialect) {
        guard let item = listItem(lines.body(row), dialect: dialect) else { return }
        let verbatim = verbatimRows(lines, dialect: dialect)

        if let parent = parentItem(of: row, indent: item.indent, in: lines, verbatim: verbatim, dialect: dialect) {
            let children = childRows(of: parent.row, indent: parent.indent, in: lines, verbatim: verbatim, dialect: dialect)
            recount(row: parent.row, over: children, in: &lines, verbatim: verbatim, dialect: dialect)
            return
        }
        guard let heading = headingRow(above: row, in: lines, verbatim: verbatim, dialect: dialect),
              !heading.countsChildHeadings else { return }
        let section = (heading.row + 1)..<heading.sectionEnd
        recount(row: heading.row, over: Array(section), in: &lines, verbatim: verbatim, dialect: dialect)
    }

    /// The item above `row` that holds it: the nearest one indented less.
    private static func parentItem(
        of row: Int,
        indent: Int,
        in lines: Lines,
        verbatim: [Bool],
        dialect: Dialect
    ) -> (row: Int, indent: Int)? {
        var i = row - 1
        while i >= 0 {
            defer { i -= 1 }
            let body = lines.body(i)
            if verbatim[i] || body.allSatisfy(\.isWhitespace) { continue }
            if let item = listItem(body, dialect: dialect) {
                if item.indent < indent { return (i, item.indent) }
                continue
            }
            // Text of a sibling item, set under its marker.
            if leadingColumns(body) >= indent, indent > 0 { continue }
            return nil
        }
        return nil
    }

    /// The rows that belong to the item at `row`: everything under it up to the
    /// next line that is not indented past it.
    private static func childRows(
        of row: Int,
        indent: Int,
        in lines: Lines,
        verbatim: [Bool],
        dialect: Dialect
    ) -> [Int] {
        var rows: [Int] = []
        var i = row + 1
        while i < lines.rows.count {
            let body = lines.body(i)
            if !verbatim[i], !body.allSatisfy(\.isWhitespace) {
                let columns = listItem(body, dialect: dialect)?.indent ?? leadingColumns(body)
                if columns <= indent { break }
            }
            rows.append(i)
            i += 1
        }
        return rows
    }

    private struct HeadingRow {
        let row: Int
        let sectionEnd: Int
        /// An Org heading whose cookie counts its TODO child headings.
        let countsChildHeadings: Bool
    }

    private static func headingRow(
        above row: Int,
        in lines: Lines,
        verbatim: [Bool],
        dialect: Dialect
    ) -> HeadingRow? {
        var i = row - 1
        while i >= 0, verbatim[i] || !isHeading(lines.body(i), dialect: dialect) { i -= 1 }
        guard i >= 0 else { return nil }
        let level = headingLevel(lines.body(i), dialect: dialect) ?? 1
        let sectionEnd = firstHeadingRow(after: i, in: lines, verbatim: verbatim, dialect: dialect)
        // A cookie on an Org heading counts its TODO child headings when it has
        // any, not the checkboxes under it.
        var countsChildHeadings = false
        if dialect == .org {
            var j = sectionEnd
            while j < lines.rows.count, !countsChildHeadings {
                let body = lines.body(j)
                if !verbatim[j], let next = headingLevel(body, dialect: dialect) {
                    if next <= level { break }
                    countsChildHeadings = orgHeading(body, keywords: lines.keywords)?.keyword != nil
                }
                j += 1
            }
        }
        return HeadingRow(row: i, sectionEnd: sectionEnd, countsChildHeadings: countsChildHeadings)
    }

    private static func firstHeadingRow(after row: Int, in lines: Lines, verbatim: [Bool], dialect: Dialect) -> Int {
        var i = row + 1
        while i < lines.rows.count, verbatim[i] || !isHeading(lines.body(i), dialect: dialect) { i += 1 }
        return i
    }

    private static func isHeading(_ line: Substring, dialect: Dialect) -> Bool {
        headingLevel(line, dialect: dialect) != nil
    }

    private static func headingLevel(_ line: Substring, dialect: Dialect) -> Int? {
        switch dialect {
        case .markdown: markdownHeadingLevel(line)
        case .org: orgHeading(line, keywords: OrgTodoKeywords(active: [], done: []))?.level
        }
    }

    /// Rows inside a fenced code block (Markdown) or `#+begin_src` (Org), the
    /// delimiters included: their `- [ ]` lines are text, not tasks.
    private static func verbatimRows(_ lines: Lines, dialect: Dialect) -> [Bool] {
        var mask = [Bool](repeating: false, count: lines.rows.count)
        var fence: Substring?
        for index in lines.rows.indices {
            let body = lines.body(index)
            let trimmed = body.drop(while: { $0 == " " || $0 == "\t" })
            switch dialect {
            case .markdown:
                if let open = fence {
                    mask[index] = true
                    if trimmed.hasPrefix(open.prefix(3)), trimmed.allSatisfy({ $0 == open.first || $0 == " " }) {
                        fence = nil
                    }
                } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    mask[index] = true
                    fence = trimmed.prefix(3)
                }
            case .org:
                let upper = trimmed.uppercased()
                if fence != nil {
                    mask[index] = true
                    if upper.hasPrefix("#+END_SRC") { fence = nil }
                } else if upper.hasPrefix("#+BEGIN_SRC") {
                    mask[index] = true
                    fence = trimmed.prefix(1)
                }
            }
        }
        return mask
    }

    /// Rewrites the first cookie on the line at `row` to count the checkbox
    /// items directly among `candidates` (the shallowest ones).
    private static func recount(
        row: Int,
        over candidates: [Int],
        in lines: inout Lines,
        verbatim: [Bool],
        dialect: Dialect
    ) {
        guard let cookie = firstCookie(in: lines.body(row), dialect: dialect) else { return }
        let items = candidates.compactMap { index -> (indent: Int, checked: Bool)? in
            guard !verbatim[index], let item = listItem(lines.body(index), dialect: dialect),
                  item.box != nil else { return nil }
            return (item.indent, item.isChecked)
        }
        guard let shallowest = items.map(\.indent).min() else { return }
        let direct = items.filter { $0.indent == shallowest }
        let done = direct.filter(\.checked).count
        let total = direct.count
        let counted = cookie.isPercent ? "[\(total == 0 ? 0 : done * 100 / total)%]" : "[\(done)/\(total)]"
        let line = lines.body(row)
        var text = String(line)
        let from = text.index(text.startIndex, offsetBy: line.distance(from: line.startIndex, to: cookie.range.lowerBound))
        let to = text.index(text.startIndex, offsetBy: line.distance(from: line.startIndex, to: cookie.range.upperBound))
        text.replaceSubrange(from..<to, with: counted)
        lines.replace(row, with: text)
    }

    private struct Cookie {
        let range: Range<String.Index>
        let isPercent: Bool
    }

    /// The first `[2/5]`, `[/]`, `[40%]` or `[%]` that is not inside code and
    /// not a link label.
    private static func firstCookie(in line: Substring, dialect: Dialect) -> Cookie? {
        let codeMarkers: Set<Character> = dialect == .org ? ["=", "~"] : ["`"]
        var open = line.startIndex
        while let start = line[open...].firstIndex(of: "[") {
            open = line.index(after: start)
            var i = open
            while i < line.endIndex, line[i].isASCII, line[i].isNumber { i = line.index(after: i) }
            guard i < line.endIndex else { return nil }
            var isPercent = false
            if line[i] == "/" {
                i = line.index(after: i)
                while i < line.endIndex, line[i].isASCII, line[i].isNumber { i = line.index(after: i) }
            } else if line[i] == "%" {
                isPercent = true
                i = line.index(after: i)
            } else {
                continue
            }
            guard i < line.endIndex, line[i] == "]" else { continue }
            let end = line.index(after: i)
            // `[1/3](url)` is a link; `[[1/3]]` an Org link.
            if end < line.endIndex, line[end] == "(" { continue }
            if start > line.startIndex, line[line.index(before: start)] == "[" { continue }
            let before = line[..<start]
            let inCode = codeMarkers.contains { marker in before.filter { $0 == marker }.count % 2 == 1 }
            if inCode { continue }
            return Cookie(range: start..<end, isPercent: isPercent)
        }
        return nil
    }

    // MARK: - Lines

    /// The document as lines, split and joined on `\n` only, so the text of
    /// every line that is not edited comes back byte for byte.
    private struct Lines {
        var rows: [String]
        /// Keywords for heading checks that read states (unset: the defaults).
        var keywords = OrgTodoKeywords.standard

        init(_ source: String) {
            var rows: [String] = []
            var start = source.startIndex
            var i = source.utf8.startIndex
            let utf8 = source.utf8
            while i < utf8.endIndex {
                if utf8[i] == 0x0A {
                    rows.append(String(source[start..<i]))
                    start = utf8.index(after: i)
                }
                i = utf8.index(after: i)
            }
            rows.append(String(source[start...]))
            self.rows = rows
        }

        var text: String { rows.joined(separator: "\n") }

        /// The line without its `\r`.
        func body(_ row: Int) -> Substring {
            let line = rows[row]
            return line.utf8.last == 0x0D ? line.dropLast() : line[...]
        }

        func cr(_ row: Int) -> String {
            rows[row].utf8.last == 0x0D ? "\r" : ""
        }

        /// Replaces the line's text, keeping its `\r`.
        mutating func replace(_ row: Int, with body: String) {
            rows[row] = body + cr(row)
        }
    }
}

private extension OrgPlanningKind {
    /// `SCHEDULED:`, as written in the file.
    var keyword: String {
        switch self {
        case .scheduled: "SCHEDULED:"
        case .deadline: "DEADLINE:"
        case .closed: "CLOSED:"
        }
    }
}

private extension TaskSourceEdit.OrgDateValue {
    /// The date and time of a stamp's text (`2026-11-12 Thu 09:00 +1w`).
    init?(timestampText text: String) {
        let tokens = text.split(separator: " ")
        let day = tokens.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard day.count == 3 else { return nil }
        var time: (hour: Int, minute: Int)?
        for token in tokens.dropFirst() where time == nil {
            guard token.first?.isNumber == true, let colon = token.firstIndex(of: ":"),
                  let hour = Int(token[..<colon]),
                  let minute = Int(token[token.index(after: colon)...].prefix(2)) else { continue }
            time = (hour, minute)
        }
        self.init(year: day[0], month: day[1], day: day[2], time: time)
    }
}
