// swiftlint:disable todo - Org-mode headline keyword examples, not unfinished work
/// Line-oriented recursive descent parser for org mode documents.
///
/// Conforms to `DocumentParser` — safe to call from any thread.
/// Produces `[OrgBlock]` AST matching org-syntax spec.
///
/// Strategy:
/// 1. Split input into lines
/// 2. Classify each line (heading, keyword, block delimiter, list item, etc.)
/// 3. Consume lines greedily, building block-level AST
/// 4. Parse inline markup within paragraph/heading text
///
/// Error recovery: malformed input is treated as plain paragraphs. Never crashes.
struct OrgParser: DocumentParser, Sendable {

    typealias Document = [OrgBlock]
    // MARK: - Allocation-free trim

    /// Strip leading/trailing ASCII whitespace returning Substring (no allocation).
    /// Foundation's trimmingCharacters returns String — allocates every call.
    @inline(__always)
    private static func stripped(_ s: Substring) -> Substring {
        let utf8 = s.utf8
        guard !utf8.isEmpty else { return s[s.endIndex...] }
        var lo = utf8.startIndex
        while lo < utf8.endIndex, utf8[lo] == 0x20 || utf8[lo] == 0x09 {
            utf8.formIndex(after: &lo)
        }
        guard lo < utf8.endIndex else { return s[s.endIndex...] }
        var hi = utf8.index(before: utf8.endIndex)
        while hi > lo, utf8[hi] == 0x20 || utf8[hi] == 0x09 {
            utf8.formIndex(before: &hi)
        }
        return s[lo...hi]
    }

    @inline(__always)
    private static func stripped(_ s: String) -> Substring {
        stripped(s[...])
    }

    /// The document's lines. A nested parse (a quote's body) gets a slice of
    /// the same array, so every index, and every line number derived from
    /// one, stays the file's own.
    private typealias Lines = ArraySlice<Substring>

    /// Whether `text` equals `upper` (an ASCII uppercase marker such as
    /// `#+END_SRC`) ignoring ASCII case, without allocating an uppercased copy
    /// of every line a block or drawer scan passes over.
    @inline(__always)
    private static func equalsIgnoringASCIICase(_ text: Substring, _ upper: String) -> Bool {
        let lhs = text.utf8
        let rhs = upper.utf8
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex {
            let byte = lhs[left]
            guard (byte >= 0x61 && byte <= 0x7A ? byte - 0x20 : byte) == rhs[right] else { return false }
            lhs.formIndex(after: &left)
            rhs.formIndex(after: &right)
        }
        return left == lhs.endIndex && right == rhs.endIndex
    }

    /// Whether `line` is a headline: stars from column 0, then a space.
    @inline(__always)
    private static func isHeadline(_ line: Substring) -> Bool {
        let utf8 = line.utf8
        var index = utf8.startIndex
        guard index < utf8.endIndex, utf8[index] == 0x2A else { return false }
        while index < utf8.endIndex, utf8[index] == 0x2A { utf8.formIndex(after: &index) }
        return index < utf8.endIndex && utf8[index] == 0x20
    }

    /// The line closing the block or drawer opened at `start`: the first later
    /// line equal to `endMarker` (`#+END_SRC`, `:END:`), ignoring case and
    /// surrounding whitespace. Otherwise, `sectionEnd` is where the search
    /// stopped: the next headline, or the end of `lines`. Org ends every block
    /// and drawer with its section, so neither an opener never closed nor a
    /// later section's closer ever runs one on over the rest of the file.
    private static func closingLine(
        in lines: Lines,
        after start: Int,
        endMarker: String
    ) -> (closer: Int?, sectionEnd: Int) {
        var cursor = start + 1
        while cursor < lines.endIndex {
            let line = lines[cursor]
            if isHeadline(line) { break }
            if equalsIgnoringASCIICase(stripped(line), endMarker) { return (cursor, cursor) }
            cursor += 1
        }
        return (nil, cursor)
    }

    /// `#+begin_NAME params` split into its name and parameters; nil when
    /// `trimmed` is no block opener.
    private static func blockOpener(_ trimmed: Substring) -> (name: Substring, parameters: Substring)? {
        let prefix = "#+BEGIN_"
        guard trimmed.utf8.count > prefix.utf8.count,
              equalsIgnoringASCIICase(trimmed.prefix(prefix.count), prefix) else { return nil }
        let afterPrefix = trimmed.dropFirst(prefix.count)
        let nameEnd = afterPrefix.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? afterPrefix.endIndex
        let name = afterPrefix[..<nameEnd]
        let parameters = nameEnd < afterPrefix.endIndex ? stripped(afterPrefix[afterPrefix.index(after: nameEnd)...]) : afterPrefix[nameEnd...]
        return (name, parameters)
    }

    /// The block `start` opens: its body runs to its closing line, or, when
    /// it is never closed, to the end of its section. Org itself reads an
    /// unclosed opener as text; running it to the section's end instead keeps
    /// a file cut off mid-block (truncated tool output) readable as the code
    /// it was, while a headline still ends it. `next` is the line after it.
    private static func block(in lines: Lines, at start: Int) -> (name: Substring, parameters: Substring, bodyEnd: Int, next: Int)? {
        guard let opener = blockOpener(stripped(lines[start])) else { return nil }
        let end = closingLine(in: lines, after: start, endMarker: "#+END_" + opener.name.uppercased())
        return (opener.name, opener.parameters, end.sectionEnd, end.closer.map { $0 + 1 } ?? end.sectionEnd)
    }

    nonisolated func parse(_ source: String) -> [OrgBlock] {
        parseLocated(source).map(\.block)
    }

    /// `\r\n` becomes `\n` before anything splits the source into lines, the
    /// same normalization `TaskSourceEdit`'s own line splitting already does
    /// per line (so line numbers the two agree on stay aligned). Left as is, a
    /// `\r` stuck to the end of every split line reaches a text view as its
    /// own paragraph break, breaking the document into far more visual lines
    /// than it has blocks. The common case has no `\r` at all, so this skips
    /// the allocation.
    @inline(__always)
    private static func normalizedLineEndings(_ source: String) -> String {
        guard source.utf8.contains(0x0D) else { return source }
        return source.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// The top-level blocks with the 1-based source line each starts on, for
    /// readers that edit the lines a block came from.
    nonisolated func parseLocated(_ source: String) -> [LocatedOrgBlock] {
        let lines = Self.normalizedLineEndings(source).split(separator: "\n", omittingEmptySubsequences: false)[...]
        return parseBlocks(lines: lines, todoKeywords: scanTodoKeywords(lines))
    }

    /// The keywords `parse` classifies headings with: the file's `#+TODO:`
    /// declarations, or the defaults.
    nonisolated func todoKeywords(in source: String) -> OrgTodoKeywords {
        scanTodoKeywords(Self.normalizedLineEndings(source).split(separator: "\n", omittingEmptySubsequences: false)[...])
    }

    /// Org applies `#+TODO:` to the whole file wherever the line sits, so the
    /// declarations are read before any heading is classified. A declaration
    /// quoted inside any `#+begin_NAME … #+end_NAME` block — not just `src` —
    /// is text or code, not a setting.
    private func scanTodoKeywords(_ lines: Lines) -> OrgTodoKeywords {
        var declarations: [OrgBlock] = []
        var cursor = lines.startIndex
        while cursor < lines.endIndex {
            let line = lines[cursor]
            cursor += 1
            guard let first = line.utf8.first, first == 0x23 || first == 0x20 || first == 0x09 else { continue }
            let trimmed = Self.stripped(line)
            guard trimmed.hasPrefix("#+") else { continue }
            // Skips exactly the lines `parseBlocks` reads as a block's body.
            if let block = Self.block(in: lines, at: cursor - 1) {
                cursor = block.next
                continue
            }
            guard let keyword = parseKeyword(line),
                  case let .keyword(key, _) = keyword,
                  OrgTodoKeywords.isDeclarationKey(key) else { continue }
            declarations.append(keyword)
        }
        return declarations.isEmpty ? .standard : OrgTodoKeywords.declared(in: declarations)
    }

    private func parseBlocks(lines: Lines, todoKeywords: OrgTodoKeywords) -> [LocatedOrgBlock] {
        var cursor = lines.startIndex
        var blocks: [LocatedOrgBlock] = []
        func add(_ block: OrgBlock) {
            blocks.append(LocatedOrgBlock(block: block, line: cursor + 1))
        }
        // Line a planning line may sit on: directly under a heading.
        var planningCursor = -1

        while cursor < lines.endIndex {
            let line = lines[cursor]

            if cursor == planningCursor, let planning = parsePlanning(line) {
                add(planning)
                cursor += 1
                continue
            }

            // Fast-path: classify by first non-whitespace character.
            // Avoids running every parser on every line.
            guard let firstNonWS = line.first(where: { !$0.isWhitespace }) else {
                // Blank line — skip
                cursor += 1
                continue
            }

            switch firstNonWS {
            case "*":
                // Possible heading (stars + space)
                if let heading = parseHeading(line, todoKeywords: todoKeywords) {
                    add(heading)
                    cursor += 1
                    planningCursor = cursor
                    continue
                }
                // Not a heading — an indented `*` bullet, or a paragraph
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor, todoKeywords: todoKeywords)
                    add(list)
                    cursor = newCursor
                    continue
                }

            case "-", "+", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if isListItemStart(line) {
                    let (list, newCursor) = parseList(lines: lines, startCursor: cursor, todoKeywords: todoKeywords)
                    add(list)
                    cursor = newCursor
                    continue
                }

            default:
                break
            }

            if let (block, newCursor) = parseLeafBlock(
                lines: lines, at: cursor, firstNonWS: firstNonWS, todoKeywords: todoKeywords
            ) {
                add(block)
                cursor = newCursor
                continue
            }

            // Default: paragraph — collect contiguous non-blank, non-structural lines
            let (paragraph, newCursor) = parseParagraph(lines: lines, startCursor: cursor)
            add(paragraph)
            // Safety: always advance at least one line to prevent infinite loops.
            cursor = max(newCursor, cursor + 1)
        }

        return blocks
    }

    /// A block that is not a heading, list or paragraph, starting at
    /// `cursor`: a `#+begin_NAME` block closed in its section, a keyword or
    /// comment line, a horizontal rule, a table, or a drawer closed in its
    /// section. A list item's own indented lines go through here too, so a
    /// block nested under an item is the same block it would be anywhere.
    /// nil when the line starts none of them.
    private func parseLeafBlock(
        lines: Lines,
        at cursor: Int,
        firstNonWS: Character,
        todoKeywords: OrgTodoKeywords
    ) -> (OrgBlock, Int)? {
        let line = lines[cursor]
        switch firstNonWS {
        case "#":
            // # → comment, #+ → keyword or block delimiter
            let trimmed = Self.stripped(line)
            if trimmed.hasPrefix("#+") {
                // Any `#+begin_NAME … #+end_NAME` block — `src`, `quote`,
                // `example`, `verse`, `center`, `export`, `comment`, and
                // names Org does not define — takes priority over a keyword.
                if let block = Self.block(in: lines, at: cursor) {
                    let parsed = parseGenericBlock(
                        name: block.name,
                        parameters: block.parameters,
                        body: lines[(cursor + 1)..<block.bodyEnd],
                        todoKeywords: todoKeywords
                    )
                    return (parsed, block.next)
                }
                if let keyword = parseKeyword(line) { return (keyword, cursor + 1) }
            }
            if let comment = parseComment(line) { return (comment, cursor + 1) }
            return nil

        case "-":
            return isHorizontalRule(line) ? (.horizontalRule, cursor + 1) : nil

        case "|":
            return parseTable(lines: lines, startCursor: cursor)

        case ":":
            // A drawer never closed in its section is text, as Org reads it.
            guard isDrawerStart(Self.stripped(line)),
                  let end = Self.closingLine(in: lines, after: cursor, endMarker: ":END:").closer else { return nil }
            return (parseDrawer(lines: lines[cursor..<end]), end + 1)

        default:
            return nil
        }
    }

    // MARK: - Heading

    /// Parse a heading line: `* TODO [#A] Title :tag1:tag2:`
    ///
    /// A headline starts in column 0: `  * item` is indented text (often a
    /// nested list item), never a heading, whatever follows the star.
    private func parseHeading(_ line: Substring, todoKeywords: OrgTodoKeywords) -> OrgBlock? {
        guard line.first == "*" else { return nil }
        // Trim only leading whitespace — trailing space matters for `* ` detection
        let leadTrimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        // Must start with stars followed by a space
        guard let firstNonStar = leadTrimmed.firstIndex(where: { $0 != "*" }) else { return nil }
        let level = leadTrimmed.distance(from: leadTrimmed.startIndex, to: firstNonStar)
        guard level > 0 else { return nil }
        guard firstNonStar < leadTrimmed.endIndex, leadTrimmed[firstNonStar] == " " else { return nil }

        var rest = String(leadTrimmed[leadTrimmed.index(after: firstNonStar)...])

        // Parse optional TODO keyword
        var keyword: String?
        for kw in todoKeywords.all where rest.hasPrefix(kw) {
            let afterKw = rest.index(rest.startIndex, offsetBy: kw.count)
            if afterKw == rest.endIndex || rest[afterKw] == " " {
                keyword = kw
                rest = afterKw < rest.endIndex ? String(rest[rest.index(after: afterKw)...]) : ""
                break
            }
        }

        // Parse optional priority: [#A]
        var priority: Character?
        if rest.hasPrefix("[#") {
            if let closeBracket = rest.firstIndex(of: "]") {
                let prioStart = rest.index(rest.startIndex, offsetBy: 2)
                if rest.distance(from: prioStart, to: closeBracket) == 1 {
                    priority = rest[prioStart]
                    let afterPrio = rest.index(after: closeBracket)
                    rest = afterPrio < rest.endIndex ? String(rest[afterPrio...]) : ""
                    if rest.hasPrefix(" ") {
                        rest = String(rest.dropFirst())
                    }
                }
            }
        }

        // Parse optional tags at end: `:tag1:tag2:`
        var tags: [String] = []
        let trimmedRest = Self.stripped(rest)
        if let tagResult = extractTagSection(String(trimmedRest)) {
            tags = tagResult.tags
            rest = tagResult.remainder
        }

        let titleText = Self.stripped(rest)
        let titleInlines = titleText.isEmpty ? [] : parseInlines(String(titleText))

        return .heading(level: level, keyword: keyword, priority: priority, title: titleInlines, tags: tags)
    }

    /// Extract tag section from end of heading line.
    /// Tags format: `:tag1:tag2:` — colon-separated, at end of line, preceded by whitespace.
    private func extractTagSection(_ text: String) -> (tags: [String], remainder: String)? {
        guard text.hasSuffix(":") else { return nil }

        // Walk backwards to find the start of the tag section.
        // Tag section is `:word:word:...:`  preceded by whitespace or at line start.
        var idx = text.index(before: text.endIndex)
        var colonCount = 0

        while idx >= text.startIndex {
            let ch = text[idx]
            if ch == ":" {
                colonCount += 1
                // Check if this is the start of the tag section
                if idx == text.startIndex || (idx > text.startIndex && text[text.index(before: idx)].isWhitespace) {
                    if colonCount >= 2 {
                        let tagString = String(text[idx...])
                        let remainder = String(Self.stripped(text[..<idx]))
                        let tagParts = tagString.split(separator: ":").map(String.init)
                        guard !tagParts.isEmpty else { return nil }
                        return (tags: tagParts, remainder: remainder)
                    }
                }
            } else if !ch.isLetter && !ch.isNumber && ch != "_" && ch != "@" {
                // Invalid character for tag — no tag section here
                return nil
            }
            if idx == text.startIndex { break }
            idx = text.index(before: idx)
        }

        return nil
    }

    // MARK: - Planning

    /// Parse `SCHEDULED: <ts> DEADLINE: <ts> CLOSED: [ts]`. Every token on the
    /// line must belong to a planning entry; anything else leaves the line to
    /// the paragraph parser, so prose that happens to start with `CLOSED:` is
    /// never swallowed.
    private func parsePlanning(_ line: Substring) -> OrgBlock? {
        guard let first = line.first(where: { $0 != " " && $0 != "\t" }),
              first == "S" || first == "D" || first == "C" else { return nil }
        guard let entries = OrgPlanningLine.parse(String(Self.stripped(line))) else { return nil }
        return .planning(entries.map { OrgPlanningEntry(kind: $0.kind, timestamp: $0.timestamp) })
    }

    // MARK: - Comment

    private func parseComment(_ line: Substring) -> OrgBlock? {
        let trimmed = Self.stripped(line)
        if trimmed == "#" {
            return .comment("")
        }
        if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("#+") {
            return .comment(String(trimmed.dropFirst(2)))
        }
        return nil
    }

    // MARK: - Horizontal Rule

    private func isHorizontalRule(_ line: Substring) -> Bool {
        let trimmed = Self.stripped(line)
        return trimmed.count >= 5 && trimmed.allSatisfy({ $0 == "-" })
    }

    // MARK: - Keyword

    /// Parse `#+KEY: value` lines.
    /// Block delimiters (BEGIN_SRC, BEGIN_QUOTE) are handled before this is called
    /// in the main parse loop. Remaining `#+` lines (including stray END_ lines)
    /// are treated as keywords.
    private func parseKeyword(_ line: Substring) -> OrgBlock? {
        let trimmed = Self.stripped(line)
        guard trimmed.hasPrefix("#+") else { return nil }

        let afterHash = String(trimmed.dropFirst(2))

        if let colonIdx = afterHash.firstIndex(of: ":") {
            let key = String(afterHash[..<colonIdx]).uppercased()
            let afterColon = afterHash.index(after: colonIdx)
            let value = afterColon < afterHash.endIndex
                ? String(Self.stripped(afterHash[afterColon...][...]))
                : ""
            return .keyword(key: key, value: value)
        }

        // No colon — e.g. `#+SOMETHING`
        let key = afterHash.uppercased()
        return .keyword(key: key, value: "")
    }

    // MARK: - Greater and Lesser Blocks

    /// Parse any `#+begin_NAME … #+end_NAME` block, case-insensitively
    /// matched (`#+END_NAME` closes `#+BEGIN_NAME` whatever case either uses).
    /// `src` and `quote` keep their own richer meaning (a language, recursed
    /// blocks); every other name — `example`, `verse`, `center`, `export`,
    /// `comment`, or a name Org does not define — is read from its body lines
    /// here too. Callers find where the body ends first (`block(in:at:)`).
    private func parseGenericBlock(
        name: Substring,
        parameters: Substring,
        body bodyLines: Lines,
        todoKeywords: OrgTodoKeywords
    ) -> OrgBlock {
        switch name.uppercased() {
        case "SRC":
            let language = parameters.split(separator: " ").first.map(String.init)
            return .codeBlock(language: language, code: Self.codeText(bodyLines))
        case "QUOTE":
            let inner = parseBlocks(lines: bodyLines, todoKeywords: todoKeywords).map(\.block)
            return .quote(inner)
        case "EXAMPLE":
            // Shown verbatim, never reparsed as Org prose: a `*not bold*` or a
            // URL inside an example block stays literal, as Org exports it.
            return .codeBlock(language: nil, code: Self.codeText(bodyLines))
        case "VERSE":
            return .verse(verseLines(bodyLines))
        case "CENTER":
            let joined = bodyLines.map { String(Self.stripped($0)) }.joined(separator: " ")
            return .paragraph(parseInlines(joined))
        case "EXPORT":
            // The export target (`html`, `latex`, …) labels the box; its
            // contents are shown, never rendered as that target.
            let language = parameters.split(separator: " ").first.map(String.init)
            return .codeBlock(language: language, code: Self.codeText(bodyLines))
        case "COMMENT":
            // Hidden downstream the same way a `# line` comment is.
            return .comment(bodyLines.map { String(Self.stripped($0)) }.joined(separator: "\n"))
        default:
            // An unknown or dynamic block (`clocktable`, …): a labelled box
            // naming it, not raw `#+begin_…` text.
            return .codeBlock(language: name.lowercased(), code: Self.codeText(bodyLines))
        }
    }

    /// A verbatim block's text as Org reads it: the indentation every line
    /// shares removed (a block nested in a list item is indented with it),
    /// and the comma Org writes before a line starting `*` or `#+` inside a
    /// block, so it is not read as a headline or keyword, removed again.
    private static func codeText(_ lines: Lines) -> String {
        var common: Substring?
        for line in lines where !stripped(line).isEmpty {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            guard let shared = common else {
                common = indent
                continue
            }
            common = shared.prefix(zip(shared.utf8, indent.utf8).prefix(while: { $0 == $1 }).count)
            if common?.isEmpty == true { break }
        }
        let dropCount = common?.utf8.count ?? 0
        // `,*`, `,#+`, and one comma fewer before any further commas there.
        func escapeComma(_ body: Substring) -> Substring.Index? {
            let content = body.drop(while: { $0 == " " || $0 == "\t" })
            guard content.first == "," else { return nil }
            let rest = content.drop(while: { $0 == "," })
            return rest.hasPrefix("*") || rest.hasPrefix("#+") ? content.startIndex : nil
        }
        guard dropCount > 0 || lines.contains(where: { escapeComma($0) != nil }) else {
            return lines.joined(separator: "\n")
        }
        return lines.lazy.map { line -> String in
            var body = stripped(line).isEmpty ? line[line.endIndex...] : line.dropFirst(dropCount)
            if let comma = escapeComma(body) { body.remove(at: comma) }
            return String(body)
        }.joined(separator: "\n")
    }

    /// A verse block's lines, each with its own inline markup and the
    /// indentation it has past the block's least indented line, which a verse
    /// keeps as written. That indentation becomes NO-BREAK SPACEs: ordinary
    /// leading spaces vanish once the Markdown is parsed again.
    private func verseLines(_ lines: Lines) -> [[OrgInline]] {
        let common = lines.lazy.filter { !Self.stripped($0).isEmpty }.map(indentOf).min() ?? 0
        return lines.map { line in
            let text = Self.stripped(line)
            var inlines = parseInlines(String(text))
            let extra = text.isEmpty ? 0 : indentOf(line) - common
            if extra > 0 { inlines.insert(.text(String(repeating: "\u{00A0}", count: extra)), at: 0) }
            return inlines
        }
    }

    // MARK: - List

    /// Whether `line` starts a list item: `-`, `+`, or `*` and a space, or a
    /// counter (`1.`, `1)`) and a space. A `*` bullet must be indented: in
    /// column 0 it starts a headline.
    private func isListItemStart(_ line: Substring) -> Bool {
        let trimmed = Self.stripped(line)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("+ ") { return true }
        if trimmed.hasPrefix("* ") { return line.first != "*" }
        return matchesOrderedBullet(trimmed[...])
    }

    private func matchesOrderedBullet(_ line: Substring) -> Bool {
        var idx = line.startIndex
        guard idx < line.endIndex, line[idx].isNumber else { return false }
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return false }
        let nextIdx = line.index(after: idx)
        guard nextIdx < line.endIndex, line[nextIdx] == " " else { return false }
        return true
    }

    private func parseListItemLine(_ line: Substring) -> (bullet: String, isOrdered: Bool, content: String)? {
        let trimmed = Self.stripped(line)

        if trimmed.hasPrefix("- ") {
            return (bullet: "-", isOrdered: false, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("+ ") {
            return (bullet: "+", isOrdered: false, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("* "), line.first != "*" {
            return (bullet: "*", isOrdered: false, content: String(trimmed.dropFirst(2)))
        }

        // Ordered: `1. text` or `1) text`
        var idx = trimmed.startIndex
        guard idx < trimmed.endIndex, trimmed[idx].isNumber else { return nil }
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            idx = trimmed.index(after: idx)
        }
        guard idx < trimmed.endIndex, trimmed[idx] == "." || trimmed[idx] == ")" else { return nil }
        let bulletEnd = trimmed.index(after: idx)
        let bullet = String(trimmed[..<bulletEnd])
        guard bulletEnd < trimmed.endIndex, trimmed[bulletEnd] == " " else { return nil }
        let content = String(trimmed[trimmed.index(after: bulletEnd)...])
        return (bullet: bullet, isOrdered: true, content: content)
    }

    /// Columns of leading space/tab before a line's first character, a tab
    /// advancing to the next multiple of 8 as Emacs counts it: how a list
    /// tells a nested item or continuation line from a sibling, whether the
    /// file indents with tabs, spaces or both.
    private func indentOf(_ line: Substring) -> Int {
        var columns = 0
        for byte in line.utf8 {
            if byte == 0x20 {
                columns += 1
            } else if byte == 0x09 {
                columns = (columns / 8 + 1) * 8
            } else {
                break
            }
        }
        return columns
    }

    /// `term :: description`: Org's description-list separator, `::`
    /// surrounded by whitespace. nil when `content` has no such separator.
    private func splitDescriptionTerm(_ content: String) -> (term: String, description: String)? {
        guard let range = content.range(of: " :: ") else { return nil }
        return (String(content[content.startIndex..<range.lowerBound]), String(content[range.upperBound...]))
    }

    /// Parses a plain list whose items sit at its first item's indent. The
    /// list's kind comes from that first item, as Org's does: a later item at
    /// the same indent with the other kind of bullet is still this list's next
    /// item, never a flip of the whole list's kind. Lines indented past an
    /// item's bullet belong to that item (`parseItemBody`).
    private func parseList(lines: Lines, startCursor: Int, todoKeywords: OrgTodoKeywords) -> (OrgBlock, Int) {
        let indent = indentOf(lines[startCursor])
        var items: [OrgListItem] = []
        var cursor = startCursor
        var isOrdered: Bool?

        while cursor < lines.endIndex {
            let line = lines[cursor]
            guard indentOf(line) == indent, let parsed = parseListItemLine(line) else { break }
            if isOrdered == nil { isOrdered = parsed.isOrdered }

            var content = parsed.content
            var checkbox: OrgCheckbox?
            if content.hasPrefix("[X] ") || content.hasPrefix("[x] ") {
                checkbox = .checked
                content = String(content.dropFirst(4))
            } else if content.hasPrefix("[ ] ") {
                checkbox = .unchecked
                content = String(content.dropFirst(4))
            } else if content.hasPrefix("[-] ") {
                checkbox = .partial
                content = String(content.dropFirst(4))
            }

            // Org reads `term :: description` only in an unordered list.
            var term: [OrgInline]?
            if !parsed.isOrdered, let split = splitDescriptionTerm(content) {
                term = parseInlines(split.term)
                content = split.description
            }

            let inlines = parseInlines(content)
            let itemLine = cursor + 1
            let (children, newCursor) = parseItemBody(
                lines: lines, startCursor: cursor + 1, bulletIndent: indent, todoKeywords: todoKeywords
            )
            cursor = newCursor

            items.append(OrgListItem(
                bullet: parsed.bullet, checkbox: checkbox, content: inlines,
                term: term, children: children, line: itemLine
            ))
        }

        let kind: OrgListKind = (isOrdered ?? false) ? .ordered : .unordered
        return (.list(kind: kind, items: items), cursor)
    }

    /// The blocks under one list item: the lines after its bullet line that
    /// are indented past the bullet, up to a blank line or one that is not. A
    /// bullet there starts a nested list at its own indent; a block
    /// (`#+begin_…`, a table, a drawer, a keyword or comment line) is read as
    /// it would be anywhere; any other run of lines is a continuation
    /// paragraph.
    private func parseItemBody(
        lines: Lines,
        startCursor: Int,
        bulletIndent: Int,
        todoKeywords: OrgTodoKeywords
    ) -> ([OrgBlock], Int) {
        var blocks: [OrgBlock] = []
        var cursor = startCursor
        while cursor < lines.endIndex {
            let line = lines[cursor]
            guard let firstNonWS = line.first(where: { !$0.isWhitespace }),
                  indentOf(line) > bulletIndent else { break }
            if isListItemStart(line) {
                let (list, newCursor) = parseList(lines: lines, startCursor: cursor, todoKeywords: todoKeywords)
                blocks.append(list)
                cursor = newCursor
            } else if let (block, newCursor) = parseLeafBlock(
                lines: lines, at: cursor, firstNonWS: firstNonWS, todoKeywords: todoKeywords
            ) {
                blocks.append(block)
                cursor = newCursor
            } else {
                var end = cursor + 1
                while end < lines.endIndex {
                    let next = lines[end]
                    guard !next.allSatisfy(\.isWhitespace), indentOf(next) > bulletIndent,
                          !isStructuralLine(next, lines: lines, cursor: end) else { break }
                    end += 1
                }
                blocks.append(.paragraph(parseInlines(Self.paragraphText(lines[cursor..<end]))))
                cursor = end
            }
        }
        return (blocks, cursor)
    }

    // MARK: - Paragraph

    private func parseParagraph(lines: Lines, startCursor: Int) -> (OrgBlock, Int) {
        // The first line is this paragraph's whatever it starts with: nothing
        // else took it (a block opener never closed, say), and it must not
        // vanish.
        var cursor = startCursor + 1
        while cursor < lines.endIndex {
            let line = lines[cursor]
            if line.allSatisfy(\.isWhitespace) { break }
            if isStructuralLine(line, lines: lines, cursor: cursor) { break }
            cursor += 1
        }
        return (.paragraph(parseInlines(Self.paragraphText(lines[startCursor..<cursor]))), cursor)
    }

    /// Paragraph lines joined with spaces, each stripped of its own
    /// indentation first: `org-adapt-indentation` aligns body text under a
    /// heading with spaces that carry no meaning here, and left in place, 4 or
    /// more of them would read as a Markdown indented code block once this
    /// paragraph is serialized.
    private static func paragraphText(_ lines: Lines) -> String {
        // Single-line fast path: skip the join.
        if lines.count == 1 { return String(stripped(lines[lines.startIndex])) }
        var text = ""
        text.reserveCapacity(lines.reduce(lines.count) { $0 + $1.utf8.count })
        for index in lines.indices {
            if index > lines.startIndex { text += " " }
            text += stripped(lines[index])
        }
        return text
    }

    /// Check if a line starts a new structural element.
    /// Uses first non-whitespace byte (UTF-8) for fast classification — avoids
    /// trimmingCharacters allocation for the vast majority of paragraph lines.
    /// `lines`/`cursor` let a `:NAME:` line check for its own `:END:` before it
    /// is allowed to end the paragraph as a drawer would.
    private func isStructuralLine(_ line: Substring, lines: Lines, cursor: Int) -> Bool {
        // Fast scan for first non-whitespace byte
        var firstByte: UInt8 = 0
        for b in line.utf8 {
            if b != 0x20 && b != 0x09 { // space, tab
                firstByte = b
                break
            }
        }
        guard firstByte != 0 else { return false }

        // Most paragraph lines start with a letter — fast reject
        if firstByte >= 0x61 && firstByte <= 0x7A { return false } // a-z
        if firstByte >= 0x41 && firstByte <= 0x5A { return false } // A-Z

        switch firstByte {
        case 0x2A: // *
            // A heading starts in column 0; an indented star line can only be
            // a `*` bullet.
            guard line.first == "*" else { return isListItemStart(line) }
            let trimmed = Self.stripped(line)
            guard let firstNonStar = trimmed.firstIndex(where: { $0 != "*" }) else { return false }
            return firstNonStar > trimmed.startIndex
                && firstNonStar < trimmed.endIndex
                && trimmed[firstNonStar] == " "
        case 0x23: // #
            let trimmed = Self.stripped(line)
            return trimmed == "#" || trimmed.hasPrefix("# ") || trimmed.hasPrefix("#+")
        case 0x2D: // -
            return isListItemStart(line) || isHorizontalRule(line)
        case 0x2B: // +
            return isListItemStart(line)
        case 0x7C: // |
            return true
        case 0x3A: // :
            return isDrawerStart(Self.stripped(line))
                && Self.closingLine(in: lines, after: cursor, endMarker: ":END:").closer != nil
        case 0x30...0x39: // 0-9
            return isListItemStart(line)
        default:
            return false
        }
    }

    // MARK: - Table Parsing

    /// Parse an org table (lines starting with `|`).
    ///
    /// Org table format:
    /// ```
    /// | Header 1 | Header 2 |
    /// |----------+----------|
    /// | Cell 1   | Cell 2   |
    /// ```
    /// The separator row (`|---+---|`) divides headers from data rows.
    /// If no separator, the first row is treated as the header.
    private func parseTable(lines: Lines, startCursor: Int) -> (OrgBlock, Int) {
        var cursor = startCursor
        var dataRows: [[String]] = []
        var separatorIndex: Int? = nil

        while cursor < lines.endIndex {
            let trimmed = Self.stripped(lines[cursor])
            guard trimmed.hasPrefix("|") else { break }

            // Check if separator row: contains only |, -, +, spaces
            let isSeparator = trimmed.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0 == "|" || $0 == " " }

            if isSeparator && trimmed.contains("-") {
                separatorIndex = dataRows.count
            } else {
                // Parse cells: split by `|`, trim, drop empty first/last
                let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .map { String(Self.stripped($0)) }
                // Drop leading/trailing empty strings from the split
                let cleaned: [String]
                if cells.first?.isEmpty == true && cells.last?.isEmpty == true {
                    cleaned = Array(cells.dropFirst().dropLast())
                } else if cells.first?.isEmpty == true {
                    cleaned = Array(cells.dropFirst())
                } else {
                    cleaned = cells
                }
                dataRows.append(cleaned)
            }
            cursor += 1
        }

        guard !dataRows.isEmpty else {
            return (.paragraph([.text("")]), cursor)
        }

        // First row (or row before separator) is the header. Each cell's text
        // is parsed the same as a paragraph's, so `*bold*`, `/italic/`,
        // `=verbatim=`, `~code~`, `+strike+` and links work inside a table too.
        let headerRowIndex = separatorIndex != nil ? 0 : 0
        let headerCells = dataRows[headerRowIndex].map { parseInlines($0) }

        let bodyStartIndex = separatorIndex != nil ? 1 : 1
        let bodyRows = dataRows[bodyStartIndex...].map { row in
            row.map { parseInlines($0) }
        }

        return (.table(headers: headerCells, rows: Array(bodyRows)), cursor)
    }

    // MARK: - Drawer Parsing

    /// Check if a line starts a drawer: `:NAME:` where NAME is word chars/hyphens.
    private func isDrawerStart(_ trimmed: Substring) -> Bool {
        guard trimmed.hasPrefix(":"),
              trimmed.hasSuffix(":"),
              trimmed.count > 2 else { return false }
        let name = trimmed.dropFirst().dropLast()
        // Must not be empty and must contain only word chars and hyphens.
        guard !name.isEmpty else { return false }
        // Exclude `:END:` — that's a closer, not a start.
        if name.uppercased() == "END" { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Parse a drawer: `lines` runs from its `:NAME:` line up to, not
    /// including, its `:END:` (which callers find first, `closingLine`).
    private func parseDrawer(lines: Lines) -> OrgBlock {
        let headerTrimmed = Self.stripped(lines[lines.startIndex])
        let name = String(headerTrimmed.dropFirst().dropLast())
        var properties: [OrgDrawerProperty] = []

        for raw in lines.dropFirst() {
            let line = Self.stripped(raw)

            // Property line: `:KEY: VALUE`
            if line.hasPrefix(":"), let colonIdx = line.dropFirst().firstIndex(of: ":") {
                let key = String(line[line.index(after: line.startIndex) ..< colonIdx])
                let valueStart = line.index(after: colonIdx)
                let value = String(Self.stripped(line[valueStart...][...]))
                if !key.isEmpty {
                    properties.append(OrgDrawerProperty(key: key, value: value))
                }
            }
        }

        return .drawer(name: name, properties: properties)
    }

    // MARK: - Inline Parsing

    // MARK: - Inline Parsing

    /// Parse inline markup in text.
    ///
    /// Uses String.Index scanning to avoid O(n) Array(text) Character copy.
    /// Plain-text fast path bypasses scanning entirely for lines without markers.
    func parseInlines(_ text: String) -> [OrgInline] {
        guard !text.isEmpty else { return [] }

        // Fast path: if no markup markers or link brackets exist, return plain text.
        let hasMarkup = text.utf8.contains(where: { b in
            b == 0x2A || b == 0x2F || b == 0x5F || b == 0x3D ||  // * / _ =
            b == 0x7E || b == 0x2B || b == 0x5B || b == 0x3C       // ~ + [ <
        })
        if !hasMarkup {
            return [.text(text)]
        }

        // String.Index scanning — no Array(text) copy needed.
        var result: [OrgInline] = []
        var pos = text.startIndex
        var textStart = pos

        @inline(__always)
        func flushText() {
            if textStart < pos {
                result.append(.text(String(text[textStart..<pos])))
            }
        }

        while pos < text.endIndex {
            let ch = text[pos]

            // Try link: [[url][desc]] or [[url]]
            if ch == "[" {
                let next = text.index(after: pos)
                if next < text.endIndex, text[next] == "[" {
                    if let (link, newPos) = parseLinkAt(text: text, pos: pos) {
                        flushText()
                        result.append(link)
                        pos = newPos
                        textStart = pos
                        continue
                    }
                }
            }

            // Try timestamp (`<2026-11-11 Wed>`, `[2026-11-06 Fri 14:00]`) and
            // statistics cookie (`[2/5]`, `[40%]`).
            if ch == "[" || ch == "<" {
                if let (timestamp, newPos) = parseTimestampAt(text: text, pos: pos) {
                    flushText()
                    result.append(.timestamp(timestamp))
                    pos = newPos
                    textStart = pos
                    continue
                }
                if ch == "[", let (cookie, newPos) = parseCookieAt(text: text, pos: pos) {
                    flushText()
                    result.append(cookie)
                    pos = newPos
                    textStart = pos
                    continue
                }
            }

            // Try markup markers
            if isMarkupMarker(ch), canOpenMarkup(text: text, at: pos) {
                if ch == "=" || ch == "~" {
                    if let (inline, newPos) = parseVerbatimAt(text: text, pos: pos, marker: ch) {
                        flushText()
                        result.append(inline)
                        pos = newPos
                        textStart = pos
                        continue
                    }
                } else {
                    if let (inline, newPos) = parseMarkupAt(text: text, pos: pos, marker: ch) {
                        flushText()
                        result.append(inline)
                        pos = newPos
                        textStart = pos
                        continue
                    }
                }
            }

            pos = text.index(after: pos)
        }

        if textStart < text.endIndex {
            result.append(.text(String(text[textStart..<text.endIndex])))
        }

        return result
    }

    @inline(__always)
    private func isMarkupMarker(_ c: Character) -> Bool {
        switch c {
        case "*", "/", "_", "=", "~", "+": return true
        default: return false
        }
    }

    private func canOpenMarkup(text: String, at pos: String.Index) -> Bool {
        let next = text.index(after: pos)
        guard next < text.endIndex, !text[next].isWhitespace else { return false }
        if pos == text.startIndex { return true }
        let prev = text[text.index(before: pos)]
        return prev.isWhitespace || isPre(prev)
    }

    private func canCloseMarkup(text: String, at pos: String.Index) -> Bool {
        guard pos > text.startIndex, !text[text.index(before: pos)].isWhitespace else { return false }
        let next = text.index(after: pos)
        if next >= text.endIndex { return true }
        return text[next].isWhitespace || isPost(text[next])
    }

    @inline(__always)
    private func isPre(_ c: Character) -> Bool {
        switch c {
        case "(", "-", "'", "\"", "{": return true
        default: return false
        }
    }

    @inline(__always)
    private func isPost(_ c: Character) -> Bool {
        switch c {
        case "-", ".", ",", ":", ";", "!", "?", "'", "\"", ")", "}", "]", "\\": return true
        default: return false
        }
    }

    private func parseVerbatimAt(text: String, pos: String.Index, marker: Character) -> (OrgInline, String.Index)? {
        var end = text.index(after: pos)
        while end < text.endIndex {
            if text[end] == marker, canCloseMarkup(text: text, at: end) {
                let inner = text.index(after: pos)
                guard inner < end else { return nil }
                let content = String(text[inner..<end])
                let inline: OrgInline = marker == "=" ? .verbatim(content) : .code(content)
                return (inline, text.index(after: end))
            }
            end = text.index(after: end)
        }
        return nil
    }

    private func parseMarkupAt(text: String, pos: String.Index, marker: Character) -> (OrgInline, String.Index)? {
        var end = text.index(after: pos)
        while end < text.endIndex {
            if text[end] == marker, canCloseMarkup(text: text, at: end) {
                let inner = text.index(after: pos)
                guard inner < end else { return nil }
                let innerText = String(text[inner..<end])
                let innerInlines = parseInlines(innerText)
                let inline: OrgInline
                switch marker {
                case "*": inline = .bold(innerInlines)
                case "/": inline = .italic(innerInlines)
                case "_": inline = .underline(innerInlines)
                case "+": inline = .strikethrough(innerInlines)
                default: return nil
                }
                return (inline, text.index(after: end))
            }
            end = text.index(after: end)
        }
        return nil
    }

    private func parseTimestampAt(text: String, pos: String.Index) -> (OrgTimestamp, String.Index)? {
        OrgPlanningLine.timestamp(in: text, at: pos)
    }

    /// `[2/5]`, `[/]`, `[40%]`, `[%]`.
    private func parseCookieAt(text: String, pos: String.Index) -> (OrgInline, String.Index)? {
        var idx = text.index(after: pos)
        func skipDigits() {
            while idx < text.endIndex, text[idx].isASCII, text[idx].isNumber {
                idx = text.index(after: idx)
            }
        }
        skipDigits()
        guard idx < text.endIndex else { return nil }
        if text[idx] == "/" {
            idx = text.index(after: idx)
            skipDigits()
        } else if text[idx] == "%" {
            idx = text.index(after: idx)
        } else {
            return nil
        }
        guard idx < text.endIndex, text[idx] == "]" else { return nil }
        let content = String(text[text.index(after: pos)..<idx])
        return (.progress(content), text.index(after: idx))
    }

    private func parseLinkAt(text: String, pos: String.Index) -> (OrgInline, String.Index)? {
        let next = text.index(after: pos)
        guard next < text.endIndex, text[pos] == "[", text[next] == "[" else { return nil }

        var idx = text.index(after: next)
        let urlStart = idx

        while idx < text.endIndex {
            if text[idx] == "]" { break }
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, text[idx] == "]" else { return nil }
        let url = String(text[urlStart..<idx])
        idx = text.index(after: idx)

        if idx < text.endIndex, text[idx] == "[" {
            idx = text.index(after: idx)
            let descStart = idx
            while idx < text.endIndex {
                if text[idx] == "]" { break }
                idx = text.index(after: idx)
            }
            guard idx < text.endIndex, text[idx] == "]" else { return nil }
            let descText = String(text[descStart..<idx])
            idx = text.index(after: idx)
            guard idx < text.endIndex, text[idx] == "]" else { return nil }
            idx = text.index(after: idx)

            let descInlines = parseInlines(descText)
            return (.link(url: url, description: descInlines), idx)
        }

        guard idx < text.endIndex, text[idx] == "]" else { return nil }
        idx = text.index(after: idx)

        return (.link(url: url, description: nil), idx)
    }
}
