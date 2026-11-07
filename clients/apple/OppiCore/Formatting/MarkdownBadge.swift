import Foundation

/// A compact status badge that travels through Markdown as an Oppi inline
/// element: `<oppi-badge tone="accent" text="NEXT" label="Next"/>`.
///
/// A converter that knows more than Markdown can say (Org's TODO states,
/// priorities, progress cookies, planning dates, tags) writes these as raw
/// inline HTML, which CommonMark keeps intact as one node. The Markdown
/// reader draws them; any surface that does not knows to show `text`.
///
/// `segment` badges written back to back form one bar of connected segments.
/// A `capsule` stands alone.
struct MarkdownBadge: Equatable, Sendable {
    enum Tone: String, Sendable {
        /// Open work.
        case accent
        /// Waiting or on hold.
        case warning
        /// Finished.
        case success
        /// Dropped: present, but out of play.
        case muted
        /// Needs attention now, such as an overdue deadline.
        case danger
        /// Supporting facts on a quiet fill: priority, progress, dates.
        case neutral
        /// Secondary labels such as tags.
        case quiet
    }

    enum Shape: String, Sendable {
        case segment
        case capsule
    }

    /// What the badge shows.
    let text: String
    /// What VoiceOver says, in words.
    let label: String
    let tone: Tone
    let shape: Shape
    /// SF Symbol drawn before the text.
    let symbol: String?

    init(text: String, label: String, tone: Tone, shape: Shape = .segment, symbol: String? = nil) {
        self.text = text
        self.label = label
        self.tone = tone
        self.shape = shape
        self.symbol = symbol
    }

    private static let openTag = "<oppi-badge"

    /// The inline HTML that carries the badge through Markdown.
    var markup: String {
        var attributes = [
            ("tone", tone.rawValue),
            ("shape", shape.rawValue),
            ("text", text),
            ("label", label),
        ]
        if let symbol { attributes.append(("symbol", symbol)) }
        let body = attributes.map { "\($0.0)=\"\(Self.escape($0.1))\"" }.joined(separator: " ")
        return "\(Self.openTag) \(body)/>"
    }

    /// The badge `markup` describes, or nil for any other HTML.
    init?(markup: String) {
        let trimmed = markup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.openTag), trimmed.hasSuffix("/>") else { return nil }
        let body = trimmed.dropFirst(Self.openTag.count).dropLast(2)
        guard let first = body.first, first == " " || first == "\t" else { return nil }
        guard let attributes = Self.attributes(in: body),
              let text = attributes["text"],
              let tone = attributes["tone"].flatMap(Tone.init(rawValue:)) else { return nil }
        self.init(
            text: text,
            label: attributes["label"] ?? text,
            tone: tone,
            shape: attributes["shape"].flatMap(Shape.init(rawValue:)) ?? .segment,
            symbol: attributes["symbol"]
        )
    }

    /// The badges of an HTML block that holds nothing else. CommonMark reads a
    /// line that starts with one complete tag as an HTML block, so a line of
    /// badges alone arrives this way rather than as a paragraph.
    static func badges(inHTMLBlock html: String) -> [Self]? {
        var badges: [Self] = []
        var rest = html.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        while !rest.isEmpty {
            guard let end = rest.range(of: "/>"),
                  let badge = Self(markup: String(rest[..<end.upperBound])) else { return nil }
            badges.append(badge)
            rest = rest[end.upperBound...].drop(while: { $0.isWhitespace })
        }
        return badges.isEmpty ? nil : badges
    }

    // MARK: - Attributes

    /// `name="value"` pairs; nil when the body is anything else.
    private static func attributes(in body: Substring) -> [String: String]? {
        var result: [String: String] = [:]
        var rest = body.drop(while: { $0.isWhitespace })
        while !rest.isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { return nil }
            let name = String(rest[..<equals])
            let afterEquals = rest[rest.index(after: equals)...]
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "-" }),
                  afterEquals.first == "\"" else { return nil }
            let valueStart = afterEquals.index(after: afterEquals.startIndex)
            guard let close = afterEquals[valueStart...].firstIndex(of: "\"") else { return nil }
            result[name] = unescape(afterEquals[valueStart..<close])
            rest = afterEquals[afterEquals.index(after: close)...].drop(while: { $0.isWhitespace })
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "\"": escaped += "&quot;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\n", "\r": escaped += " "
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private static func unescape(_ value: Substring) -> String {
        guard value.contains("&") else { return String(value) }
        return value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
