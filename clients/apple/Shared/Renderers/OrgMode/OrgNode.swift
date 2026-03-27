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
    case quote([OrgBlock])

    /// Keyword line: `#+KEY: value`
    case keyword(key: String, value: String)

    /// Horizontal rule: 5 or more consecutive dashes on a line.
    case horizontalRule

    /// Comment line: `# some text`
    case comment(String)

    /// Drawer: `:NAME: ... :END:`
    /// Property drawers use name "PROPERTIES" and contain key-value pairs.
    case drawer(name: String, properties: [OrgDrawerProperty])
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
    case bold([OrgInline])

    /// Italic: `/text/` — can contain nested inlines.
    case italic([OrgInline])

    /// Underline: `_text_` — can contain nested inlines.
    case underline([OrgInline])

    /// Verbatim: `=text=` — raw string, no nesting.
    case verbatim(String)

    /// Inline code: `~code~` — raw string, no nesting.
    case code(String)

    /// Strikethrough: `+text+` — can contain nested inlines.
    case strikethrough([OrgInline])

    /// Link: `[[url][description]]` or `[[url]]`
    case link(url: String, description: [OrgInline]?)
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
