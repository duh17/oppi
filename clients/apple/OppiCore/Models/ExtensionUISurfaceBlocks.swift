import Foundation

/// A composable surface's `blocks` section: a tree of primitives the server composes and the host
/// draws. Every node names a `tone`, a `style`, and a spacing step and nothing else, so a design
/// can ship from the server without an app build. A node kind this build does not know decodes to
/// `.unsupported` with the words it arrived with, never a thrown error.

/// One tap a node offers: an action id from the surface's table, plus the values it sends.
struct ExtensionUISurfaceNodeAction: Sendable, Equatable, Codable {
    let id: String
    /// Collected values the tap carries; a `JSONValue` keeps the frame's scalars lossless.
    let values: [String: JSONValue]?
    let pending: ExtensionUISurfacePendingState?
}

/// The `id` and `accessibility` every node may carry.
struct ExtensionUISurfaceNodeBase: Sendable, Equatable, Codable {
    let id: String?
    let accessibility: ExtensionUIAccessibility?

    init(id: String?, accessibility: ExtensionUIAccessibility?) {
        self.id = id
        self.accessibility = accessibility
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        accessibility = try? c.decodeIfPresent(ExtensionUIAccessibility.self, forKey: .accessibility)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(accessibility, forKey: .accessibility)
    }

    private enum Keys: String, CodingKey {
        case id, accessibility
    }
}

struct ExtensionUISurfaceNodeKeyValuePair: Sendable, Equatable, Codable {
    let key: String
    let value: String
    let tone: String?
}

struct ExtensionUISurfaceNodeTableRow: Sendable, Equatable, Codable, Identifiable {
    /// Required when the row offers actions: a tap names the node and the row.
    let id: String?
    let cells: [ExtensionUISurfaceCell]
    let actions: [ExtensionUISurfaceNodeAction]?
}

struct ExtensionUISurfaceNodeChartSeries: Sendable, Equatable, Codable {
    let name: String?
    let values: [Double]
}

struct ExtensionUISurfaceMenuItem: Sendable, Equatable, Codable, Identifiable {
    let id: String?
    let title: String
    let role: String?
    let action: ExtensionUISurfaceNodeAction
}

/// A node of a blocks tree: one primitive, plus the tap it offers.
enum ExtensionUISurfaceNode: Sendable, Equatable, Codable {
    case row(ExtensionUISurfaceLayoutNode)
    case stack(ExtensionUISurfaceLayoutNode)
    case text(ExtensionUISurfaceTextNode)
    case markdown(ExtensionUISurfaceMarkdownNode)
    case badge(ExtensionUISurfaceBadgeNode)
    case icon(ExtensionUISurfaceIconNode)
    case progress(ExtensionUISurfaceProgressNode)
    case keyValue(ExtensionUISurfaceKeyValueNode)
    case table(ExtensionUISurfaceTableNode)
    case chart(ExtensionUISurfaceChartNode)
    case code(ExtensionUISurfaceCodeNode)
    case divider(ExtensionUISurfaceNodeBase)
    case spacer(ExtensionUISurfaceSpacerNode)
    case button(ExtensionUISurfaceButtonNode)
    case toggle(ExtensionUISurfaceToggleNode)
    case menu(ExtensionUISurfaceMenuNode)
    /// A node kind this build cannot draw: its id, the kind it arrived as, and its own words.
    case unsupported(ExtensionUISurfaceNodeUnsupported)

    /// The wire name of the kind, for identity and for a labeled placeholder.
    var kind: String {
        switch self {
        case .row: return "row"
        case .stack: return "stack"
        case .text: return "text"
        case .markdown: return "markdown"
        case .badge: return "badge"
        case .icon: return "icon"
        case .progress: return "progress"
        case .keyValue: return "keyValue"
        case .table: return "table"
        case .chart: return "chart"
        case .code: return "code"
        case .divider: return "divider"
        case .spacer: return "spacer"
        case .button: return "button"
        case .toggle: return "toggle"
        case .menu: return "menu"
        case .unsupported(let value): return value.type
        }
    }

    var base: ExtensionUISurfaceNodeBase? {
        switch self {
        case .row(let value), .stack(let value): return value.base
        case .text(let value): return value.base
        case .markdown(let value): return value.base
        case .badge(let value): return value.base
        case .icon(let value): return value.base
        case .progress(let value): return value.base
        case .keyValue(let value): return value.base
        case .table(let value): return value.base
        case .chart(let value): return value.base
        case .code(let value): return value.base
        case .divider(let base): return base
        case .spacer(let value): return value.base
        case .button(let value): return value.base
        case .toggle(let value): return value.base
        case .menu(let value): return value.base
        case .unsupported: return nil
        }
    }

    var id: String? {
        if case .unsupported(let value) = self { return value.id }
        return base?.id
    }

    /// A layout node's children; every other node has none.
    var children: [ExtensionUISurfaceNode] {
        switch self {
        case .row(let value), .stack(let value): return value.children
        default: return []
        }
    }

    /// A region's tap, for the primitives that are tap targets as a whole.
    var action: ExtensionUISurfaceNodeAction? {
        switch self {
        case .row(let value), .stack(let value): return value.action
        case .text(let value): return value.action
        case .badge(let value): return value.action
        default: return nil
        }
    }

    /// Every action id this node and its children offer, in the order they are drawn.
    var actionIds: [String] {
        switch self {
        case .row(let value), .stack(let value):
            return value.children.flatMap(\.actionIds) + (value.action.map { [$0.id] } ?? [])
        case .text(let value):
            return value.action.map { [$0.id] } ?? []
        case .badge(let value):
            return value.action.map { [$0.id] } ?? []
        case .table(let value):
            return value.rows.flatMap { $0.actions?.map(\.id) ?? [] }
        case .button(let value):
            return value.action.map { [$0.id] } ?? []
        case .toggle(let value):
            return value.action.map { [$0.id] } ?? []
        case .menu(let value):
            return value.items.map(\.action.id)
        default:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NodeCodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        let base = (try? ExtensionUISurfaceNodeBase(from: decoder))
            ?? ExtensionUISurfaceNodeBase(id: nil, accessibility: nil)
        let action: ExtensionUISurfaceNodeAction? =
            try? c.decodeIfPresent(ExtensionUISurfaceNodeAction.self, forKey: .action)
        switch type {
        case "row", "stack":
            let layout = ExtensionUISurfaceLayoutNode(
                base: base,
                children: (try? c.decode([ExtensionUISurfaceNode].self, forKey: .children)) ?? [],
                spacing: try? c.decodeIfPresent(String.self, forKey: .spacing),
                align: try? c.decodeIfPresent(String.self, forKey: .align),
                action: action
            )
            self = type == "row" ? .row(layout) : .stack(layout)
        case "text":
            self = .text(
                ExtensionUISurfaceTextNode(
                    base: base,
                    text: (try? c.decode(String.self, forKey: .text)) ?? "",
                    style: try? c.decodeIfPresent(String.self, forKey: .style),
                    tone: try? c.decodeIfPresent(String.self, forKey: .tone),
                    action: action
                )
            )
        case "markdown":
            self = .markdown(
                ExtensionUISurfaceMarkdownNode(
                    base: base,
                    markdown: (try? c.decode(String.self, forKey: .markdown)) ?? ""
                )
            )
        case "badge":
            self = .badge(
                ExtensionUISurfaceBadgeNode(
                    base: base,
                    text: (try? c.decode(String.self, forKey: .text)) ?? "",
                    tone: try? c.decodeIfPresent(String.self, forKey: .tone),
                    action: action
                )
            )
        case "icon":
            self = .icon(
                ExtensionUISurfaceIconNode(
                    base: base,
                    name: (try? c.decode(String.self, forKey: .name)) ?? "",
                    tone: try? c.decodeIfPresent(String.self, forKey: .tone)
                )
            )
        case "progress":
            self = .progress(
                ExtensionUISurfaceProgressNode(
                    base: base,
                    label: try? c.decodeIfPresent(String.self, forKey: .label),
                    value: try? c.decodeIfPresent(Double.self, forKey: .value),
                    kind: try? c.decodeIfPresent(String.self, forKey: .kind)
                )
            )
        case "keyValue":
            self = .keyValue(
                ExtensionUISurfaceKeyValueNode(
                    base: base,
                    pairs: (try? c.decode(
                        [ExtensionUISurfaceNodeKeyValuePair].self,
                        forKey: .pairs
                    )) ?? []
                )
            )
        case "table":
            self = .table(
                ExtensionUISurfaceTableNode(
                    base: base,
                    columns: (try? c.decode([String].self, forKey: .columns)) ?? [],
                    rows: (try? c.decode(
                        [ExtensionUISurfaceNodeTableRow].self,
                        forKey: .rows
                    )) ?? [],
                    truncated: try? c.decodeIfPresent(Bool.self, forKey: .truncated)
                )
            )
        case "chart":
            self = .chart(
                ExtensionUISurfaceChartNode(
                    base: base,
                    kind: (try? c.decode(String.self, forKey: .kind)) ?? "bar",
                    title: try? c.decodeIfPresent(String.self, forKey: .title),
                    labels: (try? c.decode([String].self, forKey: .labels)) ?? [],
                    series: (try? c.decode(
                        [ExtensionUISurfaceNodeChartSeries].self,
                        forKey: .series
                    )) ?? [],
                    truncated: try? c.decodeIfPresent(Bool.self, forKey: .truncated)
                )
            )
        case "code":
            self = .code(
                ExtensionUISurfaceCodeNode(
                    base: base,
                    language: try? c.decodeIfPresent(String.self, forKey: .language),
                    text: (try? c.decode(String.self, forKey: .text)) ?? ""
                )
            )
        case "divider":
            self = .divider(base)
        case "spacer":
            self = .spacer(
                ExtensionUISurfaceSpacerNode(
                    base: base,
                    size: try? c.decodeIfPresent(String.self, forKey: .size)
                )
            )
        case "button":
            self = .button(
                ExtensionUISurfaceButtonNode(
                    base: base,
                    title: (try? c.decode(String.self, forKey: .title)) ?? "",
                    role: try? c.decodeIfPresent(String.self, forKey: .role),
                    icon: try? c.decodeIfPresent(String.self, forKey: .icon),
                    action: action
                )
            )
        case "toggle":
            self = .toggle(
                ExtensionUISurfaceToggleNode(
                    base: base,
                    title: (try? c.decode(String.self, forKey: .title)) ?? "",
                    value: (try? c.decode(Bool.self, forKey: .value)) ?? false,
                    action: action
                )
            )
        case "menu":
            self = .menu(
                ExtensionUISurfaceMenuNode(
                    base: base,
                    title: try? c.decodeIfPresent(String.self, forKey: .title),
                    icon: try? c.decodeIfPresent(String.self, forKey: .icon),
                    items: (try? c.decode([ExtensionUISurfaceMenuItem].self, forKey: .items)) ?? []
                )
            )
        default:
            // A kind this build does not draw keeps its words, so the host shows a labeled line
            // where the node would have been instead of dropping the section or the frame.
            self = .unsupported(try ExtensionUISurfaceNodeUnsupported(from: decoder, type: type))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: NodeCodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .row(let value), .stack(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.children, forKey: .children)
            try c.encodeIfPresent(value.spacing, forKey: .spacing)
            try c.encodeIfPresent(value.align, forKey: .align)
            try c.encodeIfPresent(value.action, forKey: .action)
        case .text(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.text, forKey: .text)
            try c.encodeIfPresent(value.style, forKey: .style)
            try c.encodeIfPresent(value.tone, forKey: .tone)
            try c.encodeIfPresent(value.action, forKey: .action)
        case .markdown(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.markdown, forKey: .markdown)
        case .badge(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.text, forKey: .text)
            try c.encodeIfPresent(value.tone, forKey: .tone)
            try c.encodeIfPresent(value.action, forKey: .action)
        case .icon(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.name, forKey: .name)
            try c.encodeIfPresent(value.tone, forKey: .tone)
        case .progress(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encodeIfPresent(value.label, forKey: .label)
            try c.encodeIfPresent(value.value, forKey: .value)
            try c.encodeIfPresent(value.kind, forKey: .kind)
        case .keyValue(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.pairs, forKey: .pairs)
        case .table(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.columns, forKey: .columns)
            try c.encode(value.rows, forKey: .rows)
            try c.encodeIfPresent(value.truncated, forKey: .truncated)
        case .chart(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.kind, forKey: .kind)
            try c.encodeIfPresent(value.title, forKey: .title)
            try c.encode(value.labels, forKey: .labels)
            try c.encode(value.series, forKey: .series)
            try c.encodeIfPresent(value.truncated, forKey: .truncated)
        case .code(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encodeIfPresent(value.language, forKey: .language)
            try c.encode(value.text, forKey: .text)
        case .divider(let base):
            try encodeNodeBase(base, into: &c)
        case .spacer(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encodeIfPresent(value.size, forKey: .size)
        case .button(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.title, forKey: .title)
            try c.encodeIfPresent(value.role, forKey: .role)
            try c.encodeIfPresent(value.icon, forKey: .icon)
            try c.encodeIfPresent(value.action, forKey: .action)
        case .toggle(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encode(value.title, forKey: .title)
            try c.encode(value.value, forKey: .value)
            try c.encodeIfPresent(value.action, forKey: .action)
        case .menu(let value):
            try encodeNodeBase(value.base, into: &c)
            try c.encodeIfPresent(value.title, forKey: .title)
            try c.encodeIfPresent(value.icon, forKey: .icon)
            try c.encode(value.items, forKey: .items)
        case .unsupported(let value):
            try value.encodePlaceholder(into: &c)
        }
    }
}

/// The key namespace every node encodes into.
enum NodeCodingKeys: String, CodingKey {
    case type, id, accessibility, children, spacing, align, action
    case text, style, tone, markdown, name, label, value, kind
    case pairs
    case columns, rows, truncated, title, series, labels
    case language
    case size, role, icon, items
}

private func encodeNodeBase(
    _ base: ExtensionUISurfaceNodeBase,
    into c: inout KeyedEncodingContainer<NodeCodingKeys>
) throws {
    try c.encodeIfPresent(base.id, forKey: .id)
    try c.encodeIfPresent(base.accessibility, forKey: .accessibility)
}

struct ExtensionUISurfaceLayoutNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let children: [ExtensionUISurfaceNode]
    let spacing: String?
    let align: String?
    let action: ExtensionUISurfaceNodeAction?
}

struct ExtensionUISurfaceTextNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let text: String
    let style: String?
    let tone: String?
    let action: ExtensionUISurfaceNodeAction?
}

struct ExtensionUISurfaceMarkdownNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let markdown: String
}

struct ExtensionUISurfaceBadgeNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let text: String
    let tone: String?
    let action: ExtensionUISurfaceNodeAction?
}

struct ExtensionUISurfaceIconNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let name: String
    let tone: String?
}

struct ExtensionUISurfaceProgressNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let label: String?
    /// 0–1; nil means indeterminate.
    let value: Double?
    let kind: String?

    var isRing: Bool { kind == "ring" }
}

struct ExtensionUISurfaceKeyValueNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let pairs: [ExtensionUISurfaceNodeKeyValuePair]
}

struct ExtensionUISurfaceTableNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let columns: [String]
    let rows: [ExtensionUISurfaceNodeTableRow]
    let truncated: Bool?
}

struct ExtensionUISurfaceChartNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let kind: String
    let title: String?
    let labels: [String]
    let series: [ExtensionUISurfaceNodeChartSeries]
    let truncated: Bool?
}

struct ExtensionUISurfaceCodeNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let language: String?
    let text: String
}

struct ExtensionUISurfaceSpacerNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let size: String?
}

struct ExtensionUISurfaceButtonNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let title: String
    let role: String?
    let icon: String?
    let action: ExtensionUISurfaceNodeAction?

    var isPrimary: Bool { role == "primary" }
    var isDestructive: Bool { role == "destructive" }
}

struct ExtensionUISurfaceToggleNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let title: String
    let value: Bool
    let action: ExtensionUISurfaceNodeAction?
}

struct ExtensionUISurfaceMenuNode: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceNodeBase
    let title: String?
    let icon: String?
    let items: [ExtensionUISurfaceMenuItem]
}

/// A node kind this build does not draw: its id, the kind it arrived as, and its own words.
struct ExtensionUISurfaceNodeUnsupported: Sendable, Equatable {
    let id: String?
    let type: String
    /// Whatever the node said about itself, so the host can show a labeled line in its place.
    let text: String

    init(id: String?, type: String, text: String) {
        self.id = id
        self.type = type
        self.text = text
    }

    init(from decoder: Decoder, type: String) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        self.type = type
        text =
            (try? c.decodeIfPresent(String.self, forKey: .text))
            ?? (try? c.decodeIfPresent(String.self, forKey: .title))
            ?? (try? c.decodeIfPresent(String.self, forKey: .markdown))
            ?? ""
    }

    /// The keys this placeholder reads and writes: the kind, the identity, and the words.
    private enum Keys: String, CodingKey {
        case type, id, text, title, markdown
    }
}

extension ExtensionUISurfaceNodeUnsupported: Encodable {
    /// A node this build cannot draw keeps the name it arrived under, so the frame still decodes
    /// to the same placeholder after a patch round trip.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PlaceholderKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(text, forKey: .text)
    }

    func encodePlaceholder(into c: inout KeyedEncodingContainer<NodeCodingKeys>) throws {
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(text, forKey: .text)
    }

    private enum PlaceholderKeys: String, CodingKey {
        case type, id, text
    }
}

// MARK: - Pill

/// The strip's own one-line summary. Without one the host derives the pill from the header.
struct ExtensionUISurfacePill: Sendable, Equatable, Codable {
    /// A row of inline facts: icon, text, badge, and progress. Never a control.
    let content: ExtensionUISurfaceNode
    let tap: ExtensionUISurfacePillTap

    var children: [ExtensionUISurfaceNode] { content.children }
}

enum ExtensionUISurfacePillTap: Sendable, Equatable, Codable {
    /// Open the panel, the same tap the header-derived pill has.
    case drawer
    case action(ExtensionUISurfaceNodeAction)

    init(from decoder: Decoder) throws {
        if let drawer = try? decoder.singleValueContainer().decode(String.self), drawer == "drawer" {
            self = .drawer
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        guard let action = try? c.decode(ExtensionUISurfaceNodeAction.self, forKey: .action) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "A pill tap is \"drawer\" or an action")
            )
        }
        self = .action(action)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .drawer:
            var c = encoder.singleValueContainer()
            try c.encode("drawer")
        case .action(let action):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(action, forKey: .action)
        }
    }

    private enum Keys: String, CodingKey {
        case action
    }
}
