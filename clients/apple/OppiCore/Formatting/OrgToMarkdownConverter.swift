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
        convert(orgBlocks, context: makeContext(orgBlocks, documentPath: documentPath, clock: clock))
    }

    private static func makeContext(_ blocks: [OrgBlock], documentPath: String?, clock: OrgBadges.Clock) -> Context {
        var titles = Set<String>()
        var ids = Set<String>()
        for block in blocks {
            switch block {
            case .heading(_, _, _, let title, _):
                titles.insert(headingText(title))
            case .drawer(let name, let properties) where isPropertiesDrawer(name):
                for property in properties where property.key.uppercased() == "ID" {
                    ids.insert(property.value)
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
            ids: ids
        )
    }

    /// Heading text as a `[[*Heading]]` link names it: no statistics cookie.
    private static func headingText(_ inlines: [OrgInline]) -> String {
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

    private static func convert(_ orgBlocks: [OrgBlock], context: Context) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        result.reserveCapacity(orgBlocks.count)
        // Whether the heading a planning line sits under is done: a finished
        // task's deadline never warns.
        var headingIsDone = false

        for block in orgBlocks {
            switch block {
            case .heading(let level, let keyword, let priority, let title, let tags):
                let isDone = keyword.map(context.todoKeywords.isDone) ?? false
                headingIsDone = isDone

                // State, priority and the title's progress cookies lead the
                // heading as one bar, written back to back so they join.
                var bar: [MarkdownBadge] = []
                if let keyword { bar.append(OrgBadges.state(keyword, isDone: isDone)) }
                if let priority { bar.append(OrgBadges.priority(String(priority))) }
                var titleRest: [OrgInline] = []
                for inline in title {
                    if case .progress(let cookie) = inline {
                        bar.append(OrgBadges.progress(cookie))
                    } else {
                        titleRest.append(inline)
                    }
                }
                var inlines: [MarkdownInline] = bar.map { .html($0.markup) }

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

                result.append(.heading(level: min(level, 6), inlines: inlines))

            case .paragraph(let orgInlines):
                result.append(.paragraph(convertInlines(orgInlines, context: context)))

            case .list(let kind, let items):
                switch kind {
                case .unordered:
                    // Check if any item has a checkbox → task list.
                    if items.contains(where: { $0.checkbox != nil }) {
                        let taskItems = items.map { item -> MarkdownBlock.TaskItem in
                            let checked = item.checkbox == .checked
                            let content: [MarkdownBlock] = [.paragraph(convertInlines(item.content, context: context))]
                            return MarkdownBlock.TaskItem(checked: checked, content: content)
                        }
                        result.append(.taskList(taskItems))
                    } else {
                        let mdItems = items.map { item -> [MarkdownBlock] in
                            [.paragraph(convertInlines(item.content, context: context))]
                        }
                        result.append(.unorderedList(mdItems))
                    }
                case .ordered:
                    let mdItems = items.map { item -> [MarkdownBlock] in
                        [.paragraph(convertInlines(item.content, context: context))]
                    }
                    result.append(.orderedList(start: 1, mdItems))
                }

            case .codeBlock(let language, let code):
                result.append(.codeBlock(language: language, code: code))

            case .quote(let children):
                let converted = convert(children, context: context)
                result.append(.blockQuote(converted))

            case .keyword(let key, let value):
                let upper = key.uppercased()
                if upper == "TITLE" {
                    // Render title as a level-1 heading.
                    result.append(.heading(level: 1, inlines: [.text(value)]))
                } else if upper == "STARTUP" || upper == "OPTIONS" || OrgTodoKeywords.isDeclarationKey(upper) {
                    // Skip directives that control rendering behavior.
                    break
                } else if upper == "AUTHOR" || upper == "DATE" || upper == "EMAIL" {
                    // Render metadata as dim paragraph.
                    result.append(.paragraph([.emphasis([.text("\(key): \(value)")])]))
                } else {
                    // Other keywords as inline code.
                    let text = "#+\(key): \(value)"
                    result.append(.paragraph([.code(text)]))
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
                // folds it, and the reader has no fold, so it stays out of the
                // reading view. Other drawers show their entries as code.
                if !isPropertiesDrawer(name), !properties.isEmpty {
                    let lines = properties.map { ":\($0.key): \($0.value)" }
                    let content = lines.joined(separator: "\n")
                    result.append(.codeBlock(language: name.lowercased(), code: content))
                }

            case .planning(let entries):
                let bar = entries.map {
                    OrgBadges.planning($0, headingIsDone: headingIsDone, clock: context.clock)
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
            return context.ids.contains(String(target.dropFirst(3))) ? context.documentName : nil
        }
        if target.hasPrefix("*") {
            let heading = String(target.dropFirst()).trimmingCharacters(in: .whitespaces)
            return context.headingTitles.contains(heading) ? context.documentName : nil
        }
        // `[[./x.org]]` is a file link without the prefix; `[[x.org]]` is a
        // fuzzy in-document search in Org.
        if target.hasPrefix("./") || target.hasPrefix("../") || target.hasPrefix("/") || target.hasPrefix("~/") {
            return filePath(fromFileLink: target)
        }
        return nil
    }

    private static func filePath(fromFileLink spec: String) -> String? {
        let path = spec.range(of: "::").map { String(spec[..<$0.lowerBound]) } ?? spec
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        // `//host/x` is a network path, not a file.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }
        return trimmed
    }
}
