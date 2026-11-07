import Foundation

// MARK: - Org → Markdown AST Converter

/// Converts parsed org mode blocks to the markdown AST used by the existing
/// rendering pipeline. This ensures org mode files render identically to
/// markdown: same fonts, colors, spacing, code blocks, and theme integration.
///
/// The conversion is lossy: the Markdown renderer has no keyword badge, dim
/// metadata or fold, so org-specific features are expressed with the styles it
/// does have. TODO keywords are bold (done states italic, with a struck-through
/// title), priority, tags and progress cookies are code spans, planning lines
/// and timestamps are italic, and property drawers are left out of the reading
/// view. The goal is visual parity with markdown, not round-trip fidelity.
enum OrgToMarkdownConverter {

    /// What the conversion needs to know about the whole document.
    private struct Context {
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
    static func convert(_ orgBlocks: [OrgBlock], documentPath: String? = nil) -> [MarkdownBlock] {
        convert(orgBlocks, context: makeContext(orgBlocks, documentPath: documentPath))
    }

    private static func makeContext(_ blocks: [OrgBlock], documentPath: String?) -> Context {
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

    private static func isPropertiesDrawer(_ name: String) -> Bool {
        name.uppercased() == "PROPERTIES"
    }

    private static func convert(_ orgBlocks: [OrgBlock], context: Context) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        result.reserveCapacity(orgBlocks.count)

        for block in orgBlocks {
            switch block {
            case .heading(let level, let keyword, let priority, let title, let tags):
                var inlines = [MarkdownInline]()
                let isDone = keyword.map(context.todoKeywords.isDone) ?? false

                // Keyword: bold while open, italic once done.
                if let keyword {
                    inlines.append(isDone ? .emphasis([.text(keyword)]) : .strong([.text(keyword)]))
                    inlines.append(.text(" "))
                }

                // Priority cookie.
                if let priority {
                    inlines.append(.code("[#\(priority)]"))
                    inlines.append(.text(" "))
                }

                // Title content, struck through when the heading is done.
                let titleInlines = convertInlines(title, context: context)
                if isDone, !titleInlines.isEmpty {
                    inlines.append(.strikethrough(titleInlines))
                } else {
                    inlines.append(contentsOf: titleInlines)
                }

                // Tags as dim suffix.
                if !tags.isEmpty {
                    // Two code spans with nothing between them serialize into one.
                    if case .code = inlines.last { inlines.append(.text(" ")) }
                    let tagStr = "  :" + tags.joined(separator: ":") + ":"
                    inlines.append(.code(tagStr))
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
                let text = entries
                    .map { "\($0.kind.label) \($0.timestamp.text)" }
                    .joined(separator: "  ·  ")
                result.append(.paragraph([.emphasis([.text(text)])]))

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
            return [.code("[\(cookie)]")]
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
