// swiftlint:disable todo - Org-mode headline keyword examples, not unfinished work
// MARK: - Org Mode AST Types

/// Block-level elements in an org mode document.
///
/// Covers the org-syntax spec sections:
/// - Headlines (§2.2)
/// - Greater blocks: quote (§3.3)
/// - Blocks: source, example (§3.4)
/// - Lists: plain lists (§3.5)
/// - Keywords (§3.6)
/// - Horizontal rules (§3.8)
/// - Paragraphs (§3.1)
/// - Comments (§3.7)
enum OrgBlock: Equatable, Sendable {
    /// Headline with stars, optional TODO keyword, optional priority cookie,
    /// title inlines, and optional tags.
    ///
    /// `* TODO [#A] Title text   :tag1:tag2:`
    case heading(level: Int, keyword: String?, priority: Character?, title: [OrgInline], tags: [String])

    /// Paragraph — one or more contiguous non-blank lines with inline markup.
    case paragraph([OrgInline])

    /// Plain list (unordered or ordered) with items.
    case list(kind: OrgListKind, items: [OrgListItem])

    /// Source code block: `#+begin_src lang ... #+end_src`
    case codeBlock(language: String?, code: String)

    /// Block quote: `#+begin_quote ... #+end_quote`
    /// Contains recursively parsed blocks.
    case quote([Self])

    /// Keyword line: `#+KEY: value`
    case keyword(key: String, value: String)

    /// Horizontal rule: 5 or more consecutive dashes on a line.
    case horizontalRule

    /// Comment line: `# some text`
    case comment(String)

    /// Table with header row and data rows.
    case table(headers: [[OrgInline]], rows: [[[OrgInline]]])

    /// Drawer: `:NAME: ... :END:`
    /// Property drawers use name "PROPERTIES" and contain key-value pairs.
    case drawer(name: String, properties: [OrgDrawerProperty])

    /// Planning line directly under a heading:
    /// `SCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri> CLOSED: [2026-11-06 Fri 14:00]`
    case planning([OrgPlanningEntry])
}

/// The keyword a planning line entry starts with.
enum OrgPlanningKind: Equatable, Sendable {
    case scheduled
    case deadline
    case closed

    /// How a reading view names the entry.
    var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .deadline: "Deadline"
        case .closed: "Closed"
        }
    }
}

/// A timestamp: `<2026-11-11 Wed>` (active) or `[2026-11-06 Fri 14:00]` (inactive).
struct OrgTimestamp: Equatable, Sendable {
    let isActive: Bool
    /// What sits between the brackets, verbatim: date, weekday, time, repeater
    /// and warning period (`2026-11-12 Thu 09:00 +1w`).
    let text: String
}

/// One `KEYWORD: timestamp` pair on a planning line.
struct OrgPlanningEntry: Equatable, Sendable {
    let kind: OrgPlanningKind
    let timestamp: OrgTimestamp
}

/// Heading keyword sequences from `#+TODO:` lines, or the built-in defaults.
///
/// Org keeps one set per file, whatever line declares it, so the parser scans
/// for declarations before it classifies headings. A declaration replaces the
/// defaults, as in Org.
struct OrgTodoKeywords: Equatable, Sendable {
    let active: [String]
    let done: [String]

    static let standard = Self(
        active: ["TODO", "NEXT", "WAITING", "HOLD"],
        done: ["DONE", "CANCELLED"]
    )

    var all: [String] { active + done }

    func isDone(_ keyword: String) -> Bool { done.contains(keyword) }

    /// Keyword sequences in `#+TODO:`, `#+SEQ_TODO:` and `#+TYP_TODO:` blocks of
    /// `blocks`, or `.standard` when none declares any.
    static func declared(in blocks: [OrgBlock]) -> Self {
        var declared: Self?
        for case let .keyword(key, value) in blocks where isDeclarationKey(key) {
            if let sequence = Self(declaration: value) {
                declared = declared.map { Self(active: $0.active + sequence.active, done: $0.done + sequence.done) } ?? sequence
            }
        }
        return declared ?? .standard
    }

    /// `#+TODO:` keys, upper-cased as the parser stores them.
    static func isDeclarationKey(_ key: String) -> Bool {
        key == "TODO" || key == "SEQ_TODO" || key == "TYP_TODO"
    }

    /// Parse a declaration value: `TODO NEXT WAIT(w@) | DONE CANCELLED`. Without
    /// a `|` the last keyword is the done state. Fast-access and logging
    /// suffixes in parentheses are dropped.
    init?(declaration: String) {
        var active: [String] = []
        var done: [String] = []
        var seenBar = false
        for token in declaration.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if token == "|" {
                seenBar = true
                continue
            }
            let name = token.prefix(while: { $0 != "(" })
            guard !name.isEmpty else { continue }
            if seenBar { done.append(String(name)) } else { active.append(String(name)) }
        }
        if !seenBar, let last = active.popLast() { done = [last] }
        guard !active.isEmpty || !done.isEmpty else { return nil }
        self.init(active: active, done: done)
    }

    init(active: [String], done: [String]) {
        self.active = active
        self.done = done
    }
}

/// A single property in an org drawer.
struct OrgDrawerProperty: Equatable, Sendable {
    let key: String
    let value: String
}

/// Inline (object-level) elements within paragraphs and headings.
///
/// Covers org-syntax §4 (Objects):
/// - Text markup: bold, italic, underline, verbatim, code, strikethrough (§4.2)
/// - Links (§4.4)
/// - Plain text
enum OrgInline: Equatable, Sendable {
    /// Plain text with no markup.
    case text(String)

    /// Bold: `*text*` — can contain nested inlines.
    case bold([Self])

    /// Italic: `/text/` — can contain nested inlines.
    case italic([Self])

    /// Underline: `_text_` — can contain nested inlines.
    case underline([Self])

    /// Verbatim: `=text=` — raw string, no nesting.
    case verbatim(String)

    /// Inline code: `~code~` — raw string, no nesting.
    case code(String)

    /// Strikethrough: `+text+` — can contain nested inlines.
    case strikethrough([Self])

    /// Link: `[[url][description]]` or `[[url]]`
    case link(url: String, description: [Self]?)

    /// Timestamp object: `<2026-11-11 Wed>` or `[2026-11-06 Fri 14:00]`.
    case timestamp(OrgTimestamp)

    /// Statistics cookie: `[2/5]` or `[40%]`, stored without the brackets
    /// (`2/5`, `40%`; `/` and `%` when Org has not counted yet).
    case progress(String)
}

/// List kind — unordered (bullet) or ordered (numbered).
enum OrgListKind: Equatable, Sendable {
    case unordered
    case ordered
}

/// A single item in a plain list.
struct OrgListItem: Equatable, Sendable {
    /// The bullet/counter marker (e.g. "-", "+", "1.", "1)").
    let bullet: String

    /// Optional checkbox state.
    let checkbox: OrgCheckbox?

    /// Inline content of the item (first line).
    let content: [OrgInline]
}

/// Checkbox state for list items.
enum OrgCheckbox: Equatable, Sendable {
    case checked    // [X]
    case unchecked  // [ ]
    case partial    // [-]
}
