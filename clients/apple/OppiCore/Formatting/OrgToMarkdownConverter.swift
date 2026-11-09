import Foundation

// MARK: - Org → Markdown AST Converter

/// Converts parsed org mode blocks to the markdown AST used by the existing
/// rendering pipeline. This ensures org mode files render identically to
/// markdown: same fonts, colors, spacing, code blocks, and theme integration.
///
/// Org metadata travels as `MarkdownBadge` inline elements (see `OrgBadges`):
/// a heading's TODO state, priority and progress cookie lead it as one bar,
/// tags trail it, a done heading's title is struck through, and a planning
/// line becomes a bar of dates. Property drawers stay out of the reading
/// view, and timestamps in prose are italic. The goal is a reading view, not
/// round-trip fidelity.
enum OrgToMarkdownConverter {

    /// What the conversion needs to know about the whole document.
    private struct Context {
        let clock: OrgBadges.Clock
        let todoKeywords: OrgTodoKeywords
        /// Last path component of the file being rendered. Links to the file
        /// itself (`[[*Heading]]`, an `id:` it declares) resolve to it.
        let documentName: String?
        /// Heading titles a `[[*Heading]]` link can point at.
        let headingTitles: Set<String>
        /// `:ID:` values a `[[id:…]]` link can point at.
        let ids: Set<String>
        /// `:CUSTOM_ID:` values a `[[#custom-id]]` link can point at.
        let customIDs: Set<String>
        /// Whether a heading without a state carries an undrawn state control.
        let offersStateControl: Bool
        /// Whether a task item carries its markers: its Org source line, for a
        /// reader that can save the file, and `[-]`. False for `convert(_:)`,
        /// which takes blocks without their lines, and inside a quote, where
        /// cmark-gfm makes no task list of `> - [ ]`: a marker there would
        /// show as raw text beside the literal box.
        var marksTaskItems: Bool
        /// The ordinal (`OrgFolding`) of each heading a fold control leads, by
        /// source line, and the source lines of those folded. Empty for a
        /// reader that does not fold.
        var foldableHeadings: [Int: Int] = [:]
        var foldedHeadings: Set<Int> = []
        /// Collects each heading block written, in order, when a reader needs to
        /// know which Org heading each one of its Markdown headings is.
        var headingTrace: HeadingTrace?
    }

    /// The source line of each heading block a conversion wrote, in order: nil
    /// for a `#+TITLE`, which is a heading of no Org heading's.
    final class HeadingTrace {
        fileprivate(set) var lines: [Int?] = []
    }

    /// Convert org blocks to markdown blocks.
    ///
    /// `documentPath` is the path of the file the blocks came from, when known.
    /// Links to other files resolve against its directory in the reader, and
    /// links to the document itself need its name.
    static func convert(
        _ orgBlocks: [OrgBlock],
        documentPath: String? = nil,
        clock: OrgBadges.Clock = .current
    ) -> [MarkdownBlock] {
        convert(
            orgBlocks,
            lines: nil,
            context: makeContext(
                orgBlocks, documentPath: documentPath, clock: clock, offersStateControl: false, marksTaskItems: false
            )
        )
    }

    /// Convert the blocks of a document the reader edits: task items, states and
    /// dates carry the source line they came from (`ReaderTaskControl`).
    /// `offersStateControl` also gives a heading without a state an undrawn marker
    /// for adding one.
    static func convert(
        located: [LocatedOrgBlock],
        documentPath: String? = nil,
        clock: OrgBadges.Clock = .current,
        offersStateControl: Bool = false,
        foldingHeadings: FoldState? = nil,
        headingTrace: HeadingTrace? = nil
    ) -> [MarkdownBlock] {
        var context = makeContext(
            located.map(\.block),
            documentPath: documentPath,
            clock: clock,
            offersStateControl: offersStateControl,
            marksTaskItems: true
        )
        context.headingTrace = headingTrace
        var shown = located
        if let foldingHeadings {
            let sections = OrgFolding.sections(of: located)
            let ordinals = OrgFolding.ordinals(of: located)
            context.foldableHeadings = ordinals.filter { sections[$0.key] != nil }
            context.foldedHeadings = Set(ordinals.filter { foldingHeadings.folded.contains($0.value) }.keys)
            shown = OrgFolding.visibleIndices(of: located, sections: sections, folded: context.foldedHeadings)
                .map { located[$0] }
        }
        return convert(shown.map(\.block), lines: shown.map(\.line), context: context)
    }

    /// A reader that folds headings: which it has folded, by ordinal
    /// (`OrgFolding`). Every heading with a section under it then leads with a
    /// chevron, and a folded one ends in a mark.
    struct FoldState: Sendable {
        var folded: Set<Int>

        init(folded: Set<Int> = []) {
            self.folded = folded
        }
    }

    private static func makeContext(
        _ blocks: [OrgBlock],
        documentPath: String?,
        clock: OrgBadges.Clock,
        offersStateControl: Bool,
        marksTaskItems: Bool
    ) -> Context {
        var titles = Set<String>()
        var ids = Set<String>()
        var customIDs = Set<String>()
        for block in blocks {
            switch block {
            case .heading(_, _, _, let title, _):
                titles.insert(headingText(title))
            case .drawer(let name, let properties) where isPropertiesDrawer(name):
                for property in properties {
                    switch property.key.uppercased() {
                    case "ID": ids.insert(property.value)
                    case "CUSTOM_ID": customIDs.insert(property.value)
                    default: break
                    }
                }
            default:
                break
            }
        }
        let name = documentPath
            .map { ($0 as NSString).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
        return Context(
            clock: clock,
            todoKeywords: OrgTodoKeywords.declared(in: blocks),
            documentName: name,
            headingTitles: titles,
            ids: ids,
            customIDs: customIDs,
            offersStateControl: offersStateControl,
            marksTaskItems: marksTaskItems
        )
    }

    /// Heading text as a `[[*Heading]]` link names it: no statistics cookie.
    static func headingText(_ inlines: [OrgInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let string), .verbatim(let string), .code(let string): return string
            case .bold(let children), .italic(let children),
                 .underline(let children), .strikethrough(let children): return headingText(children)
            case .link(let url, let description): return description.map(headingText) ?? url
            case .timestamp(let timestamp): return timestamp.text
            case .progress: return ""
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespaces)
    }

    /// A title with its cookies lifted out: no space left at either end, and
    /// no double space where a cookie sat between words.
    private static func tidiedTitle(_ inlines: [OrgInline]) -> [OrgInline] {
        var tidied: [OrgInline] = []
        for inline in inlines {
            if case .text(let next) = inline, case .text(let previous) = tidied.last {
                tidied[tidied.count - 1] = .text(previous + next)
            } else {
                tidied.append(inline)
            }
        }
        return tidied.enumerated().compactMap { index, inline in
            guard case .text(var text) = inline else { return inline }
            while let range = text.range(of: "  ") { text.replaceSubrange(range, with: " ") }
            if index == 0 { text = String(text.drop(while: { $0 == " " })) }
            if index == tidied.count - 1 { text = String(text.reversed().drop(while: { $0 == " " }).reversed()) }
            return text.isEmpty ? nil : .text(text)
        }
    }

    private static func isPropertiesDrawer(_ name: String) -> Bool {
        name.uppercased() == "PROPERTIES"
    }

    /// `#+FILETAGS: :a:b:` (or `:a: :b:`, space-separated groups) split into
    /// individual tag names, the same shape heading tags parse to.
    private static func filetags(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .flatMap { $0.split(separator: ":") }
            .map(String.init)
    }

    /// One list item's own blocks: its term and content (or just its
    /// content), then any nested blocks — a sub-list, a continuation
    /// paragraph, or both — indented under it in the source.
    private static func listItemBlocks(_ item: OrgListItem, context: Context) -> [MarkdownBlock] {
        var inlines: [MarkdownInline]
        if let term = item.term {
            inlines = [.strong(convertInlines(term, context: context)), .text(": ")]
            inlines.append(contentsOf: convertInlines(item.content, context: context))
        } else {
            inlines = convertInlines(item.content, context: context)
        }
        var blocks: [MarkdownBlock] = [.paragraph(inlines)]
        if !item.children.isEmpty {
            blocks.append(contentsOf: convert(item.children, lines: nil, context: context))
        }
        return blocks
    }

    /// A title that starts with the `COMMENT` keyword (after any TODO state and
    /// priority, which the parser has already taken off): Org leaves the whole
    /// subtree out of exports.
    private static func isCommented(_ title: [OrgInline]) -> Bool {
        guard case .text(let text)? = title.first, text.hasPrefix("COMMENT") else { return false }
        guard let next = text.dropFirst("COMMENT".count).first else { return title.count == 1 }
        return next == " " || next == "\t"
    }

    /// `lines` holds each block's source line, when the reader can edit it.
    private static func convert(_ orgBlocks: [OrgBlock], lines: [Int]?, context: Context) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        result.reserveCapacity(orgBlocks.count)
        // Whether the heading a planning line sits under is done: a finished
        // task's deadline never warns.
        var headingIsDone = false
        var headingLine: Int?
        // The level of the `COMMENT` heading whose subtree is being left out:
        // everything up to the next heading of the same or a higher level.
        var commentLevel: Int?

        for (index, block) in orgBlocks.enumerated() {
            let line = lines?[index]
            if case .heading(let level, _, _, let title, _) = block {
                if let open = commentLevel, level <= open { commentLevel = nil }
                if commentLevel == nil, isCommented(title) { commentLevel = level }
            }
            if commentLevel != nil { continue }
            switch block {
            case .heading(let level, let keyword, let priority, let title, let tags):
                let isDone = keyword.map(context.todoKeywords.isDone) ?? false
                headingIsDone = isDone
                headingLine = line

                // State, priority and the title's progress cookies lead the
                // heading as one bar, written back to back so they join.
                var bar: [MarkdownBadge] = []
                var marker: MarkdownBadge?
                if let keyword {
                    bar.append(OrgBadges.state(keyword, isDone: isDone, line: line))
                } else if context.offersStateControl, let line {
                    marker = OrgBadges.addState(line: line)
                }
                if let priority { bar.append(OrgBadges.priority(String(priority))) }
                var titleRest: [OrgInline] = []
                for inline in title {
                    if case .progress(let cookie) = inline {
                        bar.append(OrgBadges.progress(cookie))
                    } else {
                        titleRest.append(inline)
                    }
                }
                // The marker leads the heading apart from the bar, so it never joins it.
                var leading: [MarkdownBadge] = []
                let foldOrdinal = line.flatMap { context.foldableHeadings[$0] }
                if let line, let foldOrdinal {
                    leading.append(OrgBadges.fold(ordinal: foldOrdinal, isExpanded: !context.foldedHeadings.contains(line)))
                }
                var inlines: [MarkdownInline] = (leading + (marker.map { [$0] } ?? []) + bar).map { .html($0.markup) }

                // Title content, struck through when the heading is done.
                let titleInlines = convertInlines(tidiedTitle(titleRest), context: context)
                if !bar.isEmpty, !titleInlines.isEmpty { inlines.append(.text(" ")) }
                if isDone, !titleInlines.isEmpty {
                    inlines.append(.strikethrough(titleInlines))
                } else {
                    inlines.append(contentsOf: titleInlines)
                }

                // Tags trail the title, one capsule each.
                for tag in tags {
                    inlines.append(.text(" "))
                    inlines.append(.html(OrgBadges.tag(tag).markup))
                }
                if let line, foldOrdinal != nil, context.foldedHeadings.contains(line) {
                    inlines.append(.text(" "))
                    inlines.append(.html(OrgBadges.foldedMark.markup))
                }

                result.append(.heading(level: min(level, 6), inlines: inlines))
                context.headingTrace?.lines.append(line)

            case .paragraph(let orgInlines):
                result.append(.paragraph(convertInlines(orgInlines, context: context)))

            case .list(let kind, let items):
                // Any item with a checkbox makes a task list, numbered or not:
                // the reader draws no numbers on a task list, but dropping the
                // boxes would lose each item's state and its toggle.
                if items.contains(where: { $0.checkbox != nil }) {
                    let taskItems = items.map { item -> MarkdownBlock.TaskItem in
                        let checked = item.checkbox == .checked
                        let isPartial = item.checkbox == .partial
                        var blocks = listItemBlocks(item, context: context)
                        if context.marksTaskItems, case .paragraph(var inlines) = blocks[0] {
                            // The item's line travels as a marker at the start of
                            // its first paragraph: the Markdown this becomes is
                            // parsed again, and its own line numbers are not the
                            // Org file's. A plain item in a list that has tasks is
                            // marked line 0: it has no box, and the Markdown's own
                            // line must not stand in for the Org's.
                            let markerLine = item.checkbox == nil ? 0 : (item.line ?? 0)
                            inlines.insert(.html(MarkdownSourceLineMarker.markup(line: markerLine)), at: 0)
                            if isPartial {
                                inlines.insert(.html(MarkdownPartialTaskMarker.markup), at: 0)
                            }
                            blocks[0] = .paragraph(inlines)
                        }
                        return MarkdownBlock.TaskItem(checked: checked, content: blocks, isPartial: isPartial)
                    }
                    result.append(.taskList(taskItems))
                } else {
                    let mdItems = items.map { item in listItemBlocks(item, context: context) }
                    result.append(kind == .ordered ? .orderedList(start: 1, mdItems) : .unorderedList(mdItems))
                }

            case .verse(let verseLines):
                var inlines: [MarkdownInline] = []
                for (index, lineInlines) in verseLines.enumerated() {
                    if index > 0 { inlines.append(.hardBreak) }
                    inlines.append(contentsOf: convertInlines(lineInlines, context: context))
                }
                result.append(.paragraph(inlines))

            case .codeBlock(let language, let code):
                result.append(.codeBlock(language: language, code: code))

            case .quote(let children):
                var quoted = context
                quoted.marksTaskItems = false
                quoted.headingTrace = nil
                result.append(.blockQuote(convert(children, lines: nil, context: quoted)))

            case .keyword(let key, let value):
                let upper = key.uppercased()
                if upper == "TITLE" {
                    // Render title as a level-1 heading.
                    result.append(.heading(level: 1, inlines: [.text(value)]))
                    context.headingTrace?.lines.append(nil)
                } else if upper == "STARTUP" || upper == "OPTIONS" || OrgTodoKeywords.isDeclarationKey(upper) {
                    // Skip directives that control rendering behavior.
                    break
                } else if upper == "AUTHOR" || upper == "DATE" || upper == "EMAIL" {
                    // Render metadata as dim paragraph.
                    result.append(.paragraph([.emphasis([.text("\(key): \(value)")])]))
                } else if upper == "FILETAGS" {
                    // The same capsule a heading's own tags draw.
                    let tags = Self.filetags(value)
                    guard !tags.isEmpty else { break }
                    var inlines: [MarkdownInline] = []
                    for (index, tag) in tags.enumerated() {
                        if index > 0 { inlines.append(.text(" ")) }
                        inlines.append(.html(OrgBadges.tag(tag).markup))
                    }
                    result.append(.paragraph(inlines))
                } else if !value.isEmpty {
                    // Every other keyword a reading view has no use for (`#+NAME`,
                    // `#+CAPTION`, `#+LINK`, `#+PROPERTY`, `#+SETUPFILE`, `#+ATTR_*`,
                    // and anything else Org defines): shown subtly, the same way as
                    // `AUTHOR`/`DATE`, rather than as a loud code chip.
                    result.append(.paragraph([.emphasis([.text("#+\(key): \(value)")])]))
                }

            case .horizontalRule:
                result.append(.thematicBreak)

            case .table(let headers, let rows):
                // Convert to markdown table with MarkdownInline cells.
                let mdHeaders = headers.map { convertInlines($0, context: context) }
                let mdRows = rows.map { row in row.map { convertInlines($0, context: context) } }
                result.append(.table(headers: mdHeaders, rows: mdRows))

            case .drawer(let name, let properties):
                // A property drawer is bookkeeping (`:ID:` for links): Org
                // folds it, and the reader folds only headings, so it stays
                // out of the reading view. Other drawers show their entries as code.
                if !isPropertiesDrawer(name), !properties.isEmpty {
                    let lines = properties.map { ":\($0.key): \($0.value)" }
                    let content = lines.joined(separator: "\n")
                    result.append(.codeBlock(language: name.lowercased(), code: content))
                }

            case .planning(let entries):
                let bar = entries.map {
                    OrgBadges.planning($0, headingIsDone: headingIsDone, clock: context.clock, headingLine: headingLine)
                }
                result.append(.paragraph(bar.map { .html($0.markup) }))

            case .comment:
                // Skip comments in rendered output.
                break
            }
        }

        return result
    }

    // MARK: - Inline conversion

    private static func convertInlines(_ orgInlines: [OrgInline], context: Context) -> [MarkdownInline] {
        orgInlines.flatMap { convertInline($0, context: context) }
    }

    private static func convertInline(_ orgInline: OrgInline, context: Context) -> [MarkdownInline] {
        switch orgInline {
        case .text(let string):
            return [.text(string)]
        case .bold(let children):
            return [.strong(convertInlines(children, context: context))]
        case .italic(let children):
            return [.emphasis(convertInlines(children, context: context))]
        case .underline(let children):
            // Markdown has no underline — render as emphasis.
            return [.emphasis(convertInlines(children, context: context))]
        case .verbatim(let string):
            return [.code(string)]
        case .code(let string):
            return [.code(string)]
        case .strikethrough(let children):
            return [.strikethrough(convertInlines(children, context: context))]
        case .timestamp(let timestamp):
            return [.emphasis([.text(timestamp.text)])]
        case .progress(let cookie):
            return [.html(OrgBadges.progress(cookie).markup)]
        case .link(let url, let description):
            let label = description.map { convertInlines($0, context: context) } ?? [.text(url)]
            guard let destination = linkDestination(url, context: context) else {
                // Nothing in the reader can open it: show the label, not a dead link.
                return label
            }
            return [.link(children: label, destination: destination)]
        }
    }

    /// The destination the reader's link handlers take for an Org link, or nil
    /// when none can open it.
    ///
    /// Files go out as plain relative paths: the reader joins them to the
    /// document's directory and routes them to the file viewer like a Markdown
    /// `[label](path)`. A `::search` option (heading, line, regex) is dropped,
    /// as Markdown drops a `#heading` fragment: the file opens at the top.
    /// A heading a link names (`*Heading`, `#custom-id`, `id:`) travels as a
    /// `ReaderHeadingAnchor` fragment, which the reader scrolls to: alone for
    /// this document, after the path for another file.
    private static func linkDestination(_ url: String, context: Context) -> String? {
        let target = url.trimmingCharacters(in: .whitespaces)
        let lower = target.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("oppi:") {
            return target
        }
        if lower.hasPrefix("file:") {
            return filePath(fromFileLink: String(target.dropFirst(5)))
        }
        if lower.hasPrefix("id:") {
            // The reader has no index from `:ID:` to file, so only an ID this
            // document declares resolves.
            let id = String(target.dropFirst(3))
            return context.ids.contains(id) ? inDocument(.id(id), context) : nil
        }
        if target.hasPrefix("*") {
            let heading = String(target.dropFirst()).trimmingCharacters(in: .whitespaces)
            return context.headingTitles.contains(heading) ? inDocument(.title(heading), context) : nil
        }
        if target.hasPrefix("#") {
            let id = String(target.dropFirst()).trimmingCharacters(in: .whitespaces)
            return context.customIDs.contains(id) ? inDocument(.customID(id), context) : nil
        }
        // `[[./x.org]]` is a file link without the prefix; `[[x.org]]` is a
        // fuzzy in-document search in Org.
        if target.hasPrefix("./") || target.hasPrefix("../") || target.hasPrefix("/") || target.hasPrefix("~/") {
            return filePath(fromFileLink: target)
        }
        return nil
    }

    /// A link to this document: the reader scrolls to the heading in place
    /// (`oppi-heading:#title=…`, `ReaderHeadingAnchor.linkDestination`). Nil
    /// without the document's name, as before, so a render that cannot open
    /// files shows the label alone.
    private static func inDocument(_ anchor: ReaderHeadingAnchor, _ context: Context) -> String? {
        context.documentName == nil ? nil : anchor.linkDestination
    }

    /// The file of a `file:` link, with the heading its `::*Heading` or
    /// `::#custom-id` search option names. Other options (a line number, a
    /// regex) are dropped: the file opens at the top.
    private static func filePath(fromFileLink spec: String) -> String? {
        let separator = spec.range(of: "::")
        let path = separator.map { String(spec[..<$0.lowerBound]) } ?? spec
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        // `//host/x` is a network path, not a file.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }
        guard let separator else { return trimmed }
        let option = String(spec[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        let anchor: ReaderHeadingAnchor?
        if option.hasPrefix("*") {
            let title = String(option.dropFirst()).trimmingCharacters(in: .whitespaces)
            anchor = title.isEmpty ? nil : .title(title)
        } else if option.hasPrefix("#"), option.count > 1 {
            anchor = .customID(String(option.dropFirst()))
        } else {
            anchor = nil
        }
        return anchor.map { trimmed + "#" + $0.fragment } ?? trimmed
    }
}
