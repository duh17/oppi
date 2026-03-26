import Foundation

// MARK: - Org → Markdown AST Converter

/// Converts parsed org mode blocks to the markdown AST used by the existing
/// rendering pipeline. This ensures org mode files render identically to
/// markdown: same fonts, colors, spacing, code blocks, and theme integration.
///
/// The conversion is lossy — org-specific features like TODO keywords, priority
/// cookies, and tags are folded into text. The goal is visual parity with
/// markdown, not round-trip fidelity.
enum OrgToMarkdownConverter {

    /// Convert org blocks to markdown blocks.
    static func convert(_ orgBlocks: [OrgBlock]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        result.reserveCapacity(orgBlocks.count)

        for block in orgBlocks {
            switch block {
            case .heading(let level, let keyword, let priority, let title, let tags):
                var inlines = [MarkdownInline]()

                // Prefix keyword (TODO/DONE) as bold text.
                if let keyword {
                    inlines.append(.strong([.text(keyword)]))
                    inlines.append(.text(" "))
                }

                // Priority cookie.
                if let priority {
                    inlines.append(.code("[#\(priority)]"))
                    inlines.append(.text(" "))
                }

                // Title content.
                inlines.append(contentsOf: convertInlines(title))

                // Tags as dim suffix.
                if !tags.isEmpty {
                    let tagStr = "  :" + tags.joined(separator: ":") + ":"
                    inlines.append(.code(tagStr))
                }

                result.append(.heading(level: min(level, 6), inlines: inlines))

            case .paragraph(let orgInlines):
                result.append(.paragraph(convertInlines(orgInlines)))

            case .list(let kind, let items):
                switch kind {
                case .unordered:
                    // Check if any item has a checkbox → task list.
                    if items.contains(where: { $0.checkbox != nil }) {
                        let taskItems = items.map { item -> MarkdownBlock.TaskItem in
                            let checked = item.checkbox == .checked
                            let content: [MarkdownBlock] = [.paragraph(convertInlines(item.content))]
                            return MarkdownBlock.TaskItem(checked: checked, content: content)
                        }
                        result.append(.taskList(taskItems))
                    } else {
                        let mdItems = items.map { item -> [MarkdownBlock] in
                            [.paragraph(convertInlines(item.content))]
                        }
                        result.append(.unorderedList(mdItems))
                    }
                case .ordered:
                    let mdItems = items.map { item -> [MarkdownBlock] in
                        [.paragraph(convertInlines(item.content))]
                    }
                    result.append(.orderedList(start: 1, mdItems))
                }

            case .codeBlock(let language, let code):
                result.append(.codeBlock(language: language, code: code))

            case .quote(let children):
                let converted = convert(children)
                result.append(.blockQuote(converted))

            case .keyword(let key, let value):
                // Render keywords as dim text.
                let text = "#+\(key): \(value)"
                result.append(.paragraph([.code(text)]))

            case .horizontalRule:
                result.append(.thematicBreak)

            case .comment:
                // Skip comments in rendered output.
                break
            }
        }

        return result
    }

    // MARK: - Inline conversion

    private static func convertInlines(_ orgInlines: [OrgInline]) -> [MarkdownInline] {
        orgInlines.map(convertInline)
    }

    private static func convertInline(_ orgInline: OrgInline) -> MarkdownInline {
        switch orgInline {
        case .text(let string):
            return .text(string)
        case .bold(let children):
            return .strong(convertInlines(children))
        case .italic(let children):
            return .emphasis(convertInlines(children))
        case .underline(let children):
            // Markdown has no underline — render as emphasis.
            return .emphasis(convertInlines(children))
        case .verbatim(let string):
            return .code(string)
        case .code(let string):
            return .code(string)
        case .strikethrough(let children):
            return .strikethrough(convertInlines(children))
        case .link(let url, let description):
            if let description {
                return .link(children: convertInlines(description), destination: url)
            } else {
                return .link(children: [.text(url)], destination: url)
            }
        }
    }
}
