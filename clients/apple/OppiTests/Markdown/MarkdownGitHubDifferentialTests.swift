import Foundation
import Testing
@testable import Oppi

/// Oppi's inline-HTML subset against GitHub's own renderer.
///
/// Each `github-html-*.md` fixture (`Fixtures/markdown-github`) sits next to the
/// HTML GitHub's Markdown API made of it (`POST /markdown`, `mode=gfm`, the
/// mode of issues and comments, where a source line break is a line break as
/// it is in Oppi). Both sides reduce to the same tokens: blocks, text with
/// HTML's whitespace collapsing, line breaks, and the subset's elements with a
/// link's `href`. Tags GitHub's sanitizer keeps but Oppi does not support are
/// absent from the fixtures; the golden corpus pins how Oppi shows those.
///
/// Refresh GitHub's side on purpose, then review the diff:
/// `clients/apple/scripts/markdown-github-fixtures.sh`.
@Suite("Markdown inline HTML vs GitHub")
struct MarkdownGitHubDifferentialTests {
    /// Elements Oppi draws on purpose that GitHub's sanitizer removes, by
    /// fixture: `<u>` underlines in Oppi; GitHub shows its text alone.
    private static let oppiOnlyElements: [String: Set<String>] = [
        "github-html-14-underline": ["u"],
    ]

    static func fixtures() -> [String] {
        (TestFixtures.bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.hasPrefix("github-html-") }
            .sorted()
    }

    @Test func everyFixtureIsListed() {
        #expect(Self.fixtures().count == 14)
    }

    @Test(arguments: fixtures())
    func oppiMatchesGitHub(_ name: String) throws {
        let source = try String(contentsOf: TestFixtures.url("\(name).md"), encoding: .utf8)
        let github = try String(contentsOf: TestFixtures.url("\(name).html"), encoding: .utf8)
        let dropped = Self.oppiOnlyElements[name] ?? []
        let oppi = Canonical.blocks(parseCommonMark(source)).map { block in
            Canonical.normalized(block.filter { token in
                switch token {
                case .open(let element, _), .close(let element): !dropped.contains(element)
                default: true
                }
            })
        }.filter { !$0.isEmpty }
        let expected = Canonical.blocks(html: github)
        #expect(oppi.map(Canonical.describe) == expected.map(Canonical.describe))
    }
}

/// The shape both renderers agree on: a block is a list of tokens.
private enum Canonical {
    enum Token: Equatable {
        case text(String)
        case lineBreak
        /// A subset element by its canonical name (`b`, `i`, `s`, `u`, `sub`,
        /// `sup`, `kbd`, `mark`, `code`, `a`), with a link's `href`.
        case open(String, href: String?)
        case close(String)
        /// A heading level or a rule, so block kinds compare too.
        case marker(String)
    }

    typealias Block = [Token]

    static func describe(_ block: Block) -> String {
        block.map { token in
            switch token {
            case .text(let text): text
            case .lineBreak: "<br>"
            case .open(let name, let href): href.map { "<\(name) href=\"\($0)\">" } ?? "<\(name)>"
            case .close(let name): "</\(name)>"
            case .marker(let name): "[\(name)] "
            }
        }.joined()
    }

    /// HTML's whitespace: runs collapse to one space, none at a block's edges
    /// or beside a line break; adjacent text joins.
    static func normalized(_ block: Block) -> Block {
        var merged: Block = []
        for token in block {
            if case .text(let text) = token, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + text)
            } else {
                merged.append(token)
            }
        }
        var result: Block = merged.map { token in
            guard case .text(let text) = token else { return token }
            return .text(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
        }
        for index in result.indices {
            guard case .text(var text) = result[index] else { continue }
            let previous = index > 0 ? result[index - 1] : nil
            let next = index + 1 < result.count ? result[index + 1] : nil
            if previous == nil || previous == .lineBreak || previous.map(isMarker) == true {
                text = String(text.drop(while: { $0 == " " }))
            }
            if next == nil || next == .lineBreak {
                while text.hasSuffix(" ") { text.removeLast() }
            }
            result[index] = .text(text)
        }
        return result.filter { $0 != .text("") }
    }

    // MARK: Oppi's tree

    static func blocks(_ markdown: [MarkdownBlock]) -> [Block] {
        markdown.flatMap { block -> [Block] in
            switch block {
            case .paragraph(let inlines):
                return [tokens(inlines)]
            case .heading(let level, let inlines):
                return [[.marker("h\(level)")] + tokens(inlines)]
            case .unorderedList(let items), .orderedList(_, let items):
                return items.flatMap(blocks)
            case .taskList(let items):
                return items.flatMap { blocks($0.content) }
            case .blockQuote(let children):
                return blocks(children)
            case .table(let headers, let rows, _):
                return (headers + rows.flatMap { $0 }).map(tokens)
            case .thematicBreak:
                return [[.marker("hr")]]
            case .htmlBlock(let html):
                return [[.text(html)]]
            case .codeBlock(_, let code):
                return [[.open("pre", href: nil), .text(code), .close("pre")]]
            case .math(let math, _):
                return [[.text(math.source)]]
            }
        }
    }

    private static func tokens(_ inlines: [MarkdownInline]) -> Block {
        inlines.flatMap { inline -> Block in
            func element(_ name: String, _ children: [MarkdownInline], href: String? = nil) -> Block {
                [.open(name, href: href)] + tokens(children) + [.close(name)]
            }
            switch inline {
            case .text(let text): return [.text(text)]
            case .strong(let children): return element("b", children)
            case .emphasis(let children): return element("i", children)
            case .strikethrough(let children): return element("s", children)
            case .styled(let style, let children):
                return element(style == .underline ? "u" : style.tag, children)
            case .code(let code): return [.open("code", href: nil), .text(code), .close("code")]
            case .link(let children, let destination): return element("a", children, href: destination)
            // A source line break is a line break in Oppi and in GitHub's
            // comment mode alike.
            case .softBreak, .hardBreak: return [.lineBreak]
            case .html(let raw): return [.text(raw)]
            case .image(let alt, _, _): return [.text(alt)]
            case .math(let math): return [.text(math.source)]
            case .videoEmbed, .audioEmbed, .usdzEmbed: return []
            }
        }
    }

    // MARK: GitHub's HTML

    private static let inlineNames: [String: String] = [
        "b": "b", "strong": "b", "i": "i", "em": "i", "s": "s", "del": "s", "strike": "s",
        "u": "u", "ins": "u", "sub": "sub", "sup": "sup", "kbd": "kbd", "mark": "mark", "code": "code",
    ]

    private static let blockNames: Set<String> = [
        "p", "li", "td", "th", "ul", "ol", "table", "thead", "tbody", "tr", "div", "blockquote",
        "markdown-accessiblity-table", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
    ]

    static func blocks(html: String) -> [Block] {
        var blocks: [Block] = []
        var current: Block = []
        /// Whether each open `<a>` was kept (it had an `href`).
        var anchors: [Bool] = []
        func endBlock() {
            let block = normalized(current)
            if !block.isEmpty, !(block.count == 1 && block.first.map(isMarker) == true) {
                blocks.append(block)
            }
            current = []
        }
        var rest = html[...]
        while let open = rest.firstIndex(of: "<") {
            current.append(.text(decode(rest[..<open])))
            if rest[open...].hasPrefix("<!--"), let end = rest[open...].range(of: "-->") {
                rest = rest[end.upperBound...]
                continue
            }
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let tag = rest[rest.index(after: open) ..< close]
            rest = rest[rest.index(after: close)...]
            let isClose = tag.hasPrefix("/")
            let name = String((isClose ? tag.dropFirst() : tag).prefix { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
            if blockNames.contains(name) {
                endBlock()
                if !isClose, name == "hr" { blocks.append([.marker("hr")]) }
                if !isClose, name.count == 2, name.hasPrefix("h"), let level = name.last, level.isNumber {
                    current = [.marker(name)]
                }
            } else if name == "br" {
                current.append(.lineBreak)
            } else if name == "a" {
                if isClose {
                    if anchors.popLast() == true { current.append(.close("a")) }
                } else if let href = attribute("href", in: tag) {
                    anchors.append(true)
                    current.append(.open("a", href: href))
                } else {
                    anchors.append(false)
                }
            } else if let canonical = inlineNames[name] {
                current.append(isClose ? .close(canonical) : .open(canonical, href: nil))
            }
        }
        current.append(.text(decode(rest)))
        endBlock()
        return blocks
    }

    private static func isMarker(_ token: Token) -> Bool {
        if case .marker = token { true } else { false }
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let start = tag.range(of: " \(name)=\"") else { return nil }
        let value = tag[start.upperBound...].prefix { $0 != "\"" }
        return decode(value)
    }

    private static func decode(_ text: Substring) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
