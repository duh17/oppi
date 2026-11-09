import Foundation

/// A heading a reader can scroll to, named the way a link or a caller knows it.
///
/// An ordinal is the heading's 1-based place among the document's top-level
/// headings (`OrgFolding`): it survives a save that moves the lines below it.
/// A line, a title, an ID and a slug are what a link carries.
enum ReaderHeadingAnchor: Hashable, Sendable {
    case ordinal(Int)
    /// The heading whose section holds this 1-based source line.
    case line(Int)
    /// A heading's exact text, as `[[*Heading]]` names it.
    case title(String)
    /// An Org `:ID:` property.
    case id(String)
    /// An Org `:CUSTOM_ID:` property.
    case customID(String)
    /// A Markdown `#anchor`: the GitHub slug of a heading's text.
    case slug(String)

    /// The scheme of a link to a heading in the document the reader shows. The
    /// renderer links only URLs with a scheme, so a bare `#fragment` would not be one.
    static let linkScheme = "oppi-heading"

    var linkDestination: String { "\(Self.linkScheme):#\(fragment)" }

    /// What a person would call the heading this names, for a message.
    var displayName: String {
        switch self {
        case .title(let name), .id(let name), .customID(let name), .slug(let name): name
        case .ordinal(let number): "#\(number)"
        case .line(let number): "line \(number)"
        }
    }

    /// The anchor a link made by `linkDestination` names. A link's URL passes
    /// through an attributed string, and NSURL reports no `fragment` for a URL
    /// with nothing between `:` and `#` (Swift's `URL(string:)` does), so the
    /// text after the first `#` is read from the string.
    init?(linkURL url: URL) {
        guard url.scheme == Self.linkScheme,
              let hash = url.absoluteString.firstIndex(of: "#") else { return nil }
        self.init(fragment: String(url.absoluteString[url.absoluteString.index(after: hash)...]))
    }

    /// A Markdown `[label](#anchor)` made a link to the heading it names, in a
    /// reader that scrolls to headings. Nil for an empty anchor.
    static func markdownLink(_ children: [MarkdownInline], _ destination: String) -> [MarkdownInline]? {
        guard let anchor = Self(fragment: String(destination.dropFirst())) else { return nil }
        return [.link(children: children, destination: anchor.linkDestination)]
    }

    /// The text after `#` in a link destination. A slug is written bare, as
    /// Markdown writes it; the rest carry a `kind=` prefix and a percent-encoded value.
    var fragment: String {
        switch self {
        case .ordinal(let value): "ordinal=\(value)"
        case .line(let value): "line=\(value)"
        case .title(let value): "title=\(Self.encode(value))"
        case .id(let value): "id=\(Self.encode(value))"
        case .customID(let value): "custom=\(Self.encode(value))"
        case .slug(let value): Self.encode(value)
        }
    }

    /// The anchor a link's `#fragment` (without the `#`) names, or nil when it is empty.
    init?(fragment: String) {
        guard !fragment.isEmpty else { return nil }
        if let (kind, value) = Self.split(fragment) {
            switch kind {
            case "ordinal": if let number = Int(value), number > 0 { self = .ordinal(number); return }
            case "line": if let number = Int(value), number > 0 { self = .line(number); return }
            case "title": self = .title(Self.decode(value)); return
            case "id": self = .id(Self.decode(value)); return
            case "custom": self = .customID(Self.decode(value)); return
            default: break
            }
        }
        self = .slug(Self.decode(fragment))
    }

    private static let valueAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
    }

    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func split(_ fragment: String) -> (kind: String, value: String)? {
        guard let equals = fragment.firstIndex(of: "=") else { return nil }
        return (String(fragment[..<equals]), String(fragment[fragment.index(after: equals)...]))
    }
}

/// One heading of a document, for finding it and listing it.
struct ReaderHeading: Equatable, Sendable {
    let ordinal: Int
    /// The 1-based source line the heading starts on.
    let line: Int
    /// Stars (Org) or hashes (Markdown).
    let level: Int
    /// The heading's own text: no state, priority, cookie or tags.
    let title: String
    /// An Org TODO state, and whether the file counts it as done.
    var keyword: String?
    var isDone = false
    var id: String?
    var customID: String?
}

/// The headings of a document, in order, and what a heading anchor resolves to.
struct ReaderOutline: Equatable, Sendable {
    let headings: [ReaderHeading]
    /// The ordinal of each heading's parent, if it has one.
    private let parents: [Int: Int]

    init(headings: [ReaderHeading]) {
        self.headings = headings
        var parents: [Int: Int] = [:]
        var open: [ReaderHeading] = []
        for heading in headings {
            while let last = open.last, last.level >= heading.level { open.removeLast() }
            if let parent = open.last { parents[heading.ordinal] = parent.ordinal }
            open.append(heading)
        }
        self.parents = parents
    }

    func heading(ordinal: Int) -> ReaderHeading? {
        headings.indices.contains(ordinal - 1) ? headings[ordinal - 1] : nil
    }

    /// The headings above `ordinal`, outermost first: the sections that must be
    /// open for it to show.
    func ancestors(of ordinal: Int) -> [Int] {
        var chain: [Int] = []
        var current = ordinal
        while let parent = parents[current] {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    func resolve(_ anchor: ReaderHeadingAnchor) -> ReaderHeading? {
        switch anchor {
        case .ordinal(let ordinal):
            return heading(ordinal: ordinal)
        case .line(let line):
            return headings.last { $0.line <= line }
        case .title(let title):
            let wanted = title.trimmingCharacters(in: .whitespaces)
            return headings.first { $0.title == wanted }
        case .id(let id):
            return headings.first { $0.id == id }
        case .customID(let id):
            return headings.first { $0.customID == id }
        case .slug(let slug):
            // A custom ID is an anchor too, as Org's `[[#id]]` and HTML export make it.
            return headings.first { $0.customID == slug } ?? slugs[slug].flatMap { heading(ordinal: $0) }
        }
    }

    /// Heading ordinals by GitHub slug: the text lower-cased, punctuation
    /// dropped, spaces as hyphens, and `-1`, `-2` on repeats.
    private var slugs: [String: Int] {
        var result: [String: Int] = [:]
        var seen: [String: Int] = [:]
        for heading in headings {
            let base = Self.slug(heading.title)
            let count = seen[base, default: 0]
            seen[base] = count + 1
            let slug = count == 0 ? base : "\(base)-\(count)"
            if result[slug] == nil { result[slug] = heading.ordinal }
        }
        return result
    }

    static func slug(_ title: String) -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        return slug
    }

    // MARK: Building

    /// The headings of an Org document. Ordinals match `OrgFolding.ordinals`.
    static func org(_ located: [LocatedOrgBlock]) -> Self {
        let keywords = OrgTodoKeywords.declared(in: located.map(\.block))
        var headings: [ReaderHeading] = []
        for entry in located {
            switch entry.block {
            case .heading(let level, let keyword, _, let title, _):
                headings.append(ReaderHeading(
                    ordinal: headings.count + 1,
                    line: entry.line,
                    level: level,
                    title: OrgToMarkdownConverter.headingText(title),
                    keyword: keyword,
                    isDone: keyword.map(keywords.isDone) ?? false
                ))
            case .drawer(let name, let properties) where name.uppercased() == "PROPERTIES":
                guard !headings.isEmpty else { continue }
                for property in properties {
                    switch property.key.uppercased() {
                    case "ID": headings[headings.count - 1].id = property.value
                    case "CUSTOM_ID": headings[headings.count - 1].customID = property.value
                    default: break
                    }
                }
            default:
                break
            }
        }
        return Self(headings: headings)
    }

    /// The top-level headings of a Markdown document.
    static func markdown(_ located: [LocatedMarkdownBlock]) -> Self {
        var headings: [ReaderHeading] = []
        for entry in located {
            guard case .heading(let level, let inlines) = entry.block else { continue }
            headings.append(ReaderHeading(
                ordinal: headings.count + 1,
                line: entry.lineRange?.lowerBound ?? 0,
                level: level,
                title: plainText(inlines).trimmingCharacters(in: .whitespaces)
            ))
        }
        return Self(headings: headings)
    }

    private static func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let string), .code(let string): string
            case .emphasis(let children), .strong(let children), .strikethrough(let children),
                 .link(let children, _): plainText(children)
            case .image(let alt, _): alt
            case .softBreak, .hardBreak: " "
            default: ""
            }
        }.joined()
    }
}
