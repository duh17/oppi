import Foundation

/// A composable extension surface, version 2 (`protocol/surfaces/`). The extension supplies data,
/// action ids, and the words for loading, empty, and failure; the host draws every region with
/// views it already ships. No colour, font, padding, or size crosses the wire.
struct ExtensionUISurface: Sendable, Equatable, Identifiable, Codable {
    let version: Int
    let id: String
    let title: String
    let placement: ExtensionUISurfacePlacement
    let lifecycle: String
    /// `oneShot` only: epoch milliseconds by which the surface settles.
    let timeoutAt: Double?
    let header: ExtensionUISurfaceHeader
    /// The strip's one-line summary; without one the client derives it from the header.
    let pill: ExtensionUISurfacePill?
    let sections: [ExtensionUISurfaceSection]
    let actions: [String: ExtensionUISurfaceActionDefinition]
    let fallback: ExtensionUISurfaceFallback
    /// Server-owned: advances on every published change, and stays above a dismissed surface's.
    let revision: Int
    let extensionScopeId: String?
    let extensionDisplayName: String?
    let publishedAt: Double?

    var isOneShot: Bool { lifecycle == "oneShot" }

    /// Action ids any card offers, in the order the surface lists them.
    var offeredActionIds: Set<String> {
        var ids = Set<String>()
        for section in sections {
            if let actions = section.actions { ids.formUnion(actions) }
            if case .dataTable(let table) = section {
                for row in table.rows {
                    if let actions = row.actions { ids.formUnion(actions) }
                }
            }
            if case .blocks(let blocks) = section {
                // Every node a tree draws may offer an action, so the region's own list is not
                // the whole of what it can send.
                ids.formUnion(blocks.body.actionIds)
            }
        }
        return ids
    }
}

struct ExtensionUISurfacePlacement: Sendable, Equatable, Codable {
    let kind: String
    let preferred: String?
}

struct ExtensionUISurfaceHeader: Sendable, Equatable, Codable {
    let title: String
    let subtitle: String?
}

struct ExtensionUISurfaceFallback: Sendable, Equatable, Codable {
    let text: String
}

struct ExtensionUISurfaceState: Sendable, Equatable, Codable {
    let kind: String
    let title: String?
    let message: String?

    var isContent: Bool { kind == "content" }
}

struct ExtensionUISurfaceActionDefinition: Sendable, Equatable, Codable {
    let title: String
    let role: String?
    let pending: ExtensionUISurfacePendingState?

    var isPrimary: Bool { role == "primary" }
    var isDestructive: Bool { role == "destructive" }
}

/// Optimistic state for the round trip only: what the pressed action shows while it waits. Every
/// action that carries a request id ends with an `extension_ui_settled` for it, so that frame is
/// where the wait ends, whatever the action had to draw.
struct ExtensionUISurfacePendingState: Sendable, Equatable, Codable {
    let title: String?
    let disabled: [String]?
}

/// An atom fills a slot a composite exposes; atoms never sit at a surface's top level.
enum ExtensionUISurfaceAtom: Sendable, Equatable, Codable {
    case text([ExtensionUITextSpan])
    case markdown(String)
    case progress(label: String?, value: Double?)
    case divider
    case spacer(String?)

    private enum CodingKeys: String, CodingKey {
        case type, spans, markdown, label, value, size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text((try? c.decode([ExtensionUITextSpan].self, forKey: .spans)) ?? [])
        case "markdown":
            self = .markdown((try? c.decode(String.self, forKey: .markdown)) ?? "")
        case "progress":
            self = .progress(
                label: try? c.decodeIfPresent(String.self, forKey: .label),
                value: try? c.decodeIfPresent(Double.self, forKey: .value)
            )
        case "divider":
            self = .divider
        case "spacer":
            self = .spacer(try? c.decodeIfPresent(String.self, forKey: .size))
        default:
            // An atom this build does not draw takes no space rather than failing the card.
            self = .spacer(nil)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let spans):
            try c.encode("text", forKey: .type)
            try c.encode(spans, forKey: .spans)
        case .markdown(let markdown):
            try c.encode("markdown", forKey: .type)
            try c.encode(markdown, forKey: .markdown)
        case .progress(let label, let value):
            try c.encode("progress", forKey: .type)
            try c.encodeIfPresent(label, forKey: .label)
            try c.encodeIfPresent(value, forKey: .value)
        case .divider:
            try c.encode("divider", forKey: .type)
        case .spacer(let size):
            try c.encode("spacer", forKey: .type)
            try c.encodeIfPresent(size, forKey: .size)
        }
    }
}

struct ExtensionUISurfaceStep: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let title: String
    let state: String
    let detail: String?
    let extra: [ExtensionUISurfaceAtom]?
}

struct ExtensionUISurfaceChecklistItem: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let title: String
    let state: String
    let detail: String?
}

struct ExtensionUISurfaceColumn: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let title: String
    let kind: String?

    var isNumeric: Bool { kind == "number" }
}

/// A table cell as the wire allows it: text, a number, or nothing.
enum ExtensionUISurfaceCell: Sendable, Equatable, Codable {
    case text(String)
    case number(Double)
    case empty

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .empty
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        self = .text((try? container.decode(String.self)) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .empty: try container.encodeNil()
        }
    }

    var displayText: String {
        switch self {
        case .empty: return ""
        case .text(let value): return value
        case .number(let value):
            if value.rounded() == value, value.magnitude < 1e15 {
                return String(Int(value))
            }
            return String(value)
        }
    }
}

struct ExtensionUISurfaceRow: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let cells: [String: ExtensionUISurfaceCell]
    let actions: [String]?

    func cell(_ columnId: String) -> ExtensionUISurfaceCell {
        cells[columnId] ?? .empty
    }
}

struct ExtensionUISurfaceSort: Sendable, Equatable, Codable {
    let columnId: String
    let descending: Bool?
}

/// The composites this slice draws. A composite it does not draw decodes to `unsupported` with
/// its fallback text, never a thrown error.
enum ExtensionUISurfaceSection: Sendable, Equatable, Codable, Identifiable {
    case statusCard(ExtensionUISurfaceStatusCard)
    case checklist(ExtensionUISurfaceChecklist)
    case dataTable(ExtensionUISurfaceDataTable)
    case actionBar(ExtensionUISurfaceActionBar)
    /// A tree of primitives, the one composite whose internal design the server composes.
    case blocks(ExtensionUISurfaceBlocks)
    case unsupported(ExtensionUISurfaceUnsupportedComposite)

    var id: String {
        switch self {
        case .statusCard(let value): return value.base.id
        case .checklist(let value): return value.base.id
        case .dataTable(let value): return value.base.id
        case .actionBar(let value): return value.base.id
        case .blocks(let value): return value.id
        case .unsupported(let value): return value.id
        }
    }

    /// The shared header, state, actions, fallback, and tone every composite carries.
    var base: ExtensionUISurfaceCompositeBase? {
        switch self {
        case .statusCard(let value): return value.base
        case .checklist(let value): return value.base
        case .dataTable(let value): return value.base
        case .actionBar(let value): return value.base
        // A tree's header is optional, so it keeps its own fields rather than the shared base.
        case .blocks, .unsupported: return nil
        }
    }

    var actions: [String]? {
        switch self {
        case .blocks(let value): return value.actions
        default: return base?.actions
        }
    }

    private enum CodingKeys: String, CodingKey {
        case composite, id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let composite = (try? c.decode(String.self, forKey: .composite)) ?? ""
        switch composite {
        case "statusCard":
            if let value = try? ExtensionUISurfaceStatusCard(from: decoder) {
                self = .statusCard(value)
                return
            }
        case "checklist":
            if let value = try? ExtensionUISurfaceChecklist(from: decoder) {
                self = .checklist(value)
                return
            }
        case "dataTable":
            if let value = try? ExtensionUISurfaceDataTable(from: decoder) {
                self = .dataTable(value)
                return
            }
        case "actionBar":
            if let value = try? ExtensionUISurfaceActionBar(from: decoder) {
                self = .actionBar(value)
                return
            }
        case "blocks":
            if let value = try? ExtensionUISurfaceBlocks(from: decoder) {
                self = .blocks(value)
                return
            }
        default:
            break
        }
        // Known or unknown: a card this build cannot read keeps its words and its id, so the host
        // shows a labeled placeholder instead of dropping the section or throwing the frame.
        self = .unsupported(
            try ExtensionUISurfaceUnsupportedComposite(from: decoder, composite: composite)
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .statusCard(let value): try value.encode(to: encoder)
        case .checklist(let value): try value.encode(to: encoder)
        case .dataTable(let value): try value.encode(to: encoder)
        case .actionBar(let value): try value.encode(to: encoder)
        case .blocks(let value): try value.encode(to: encoder)
        case .unsupported(let value): try value.encode(to: encoder)
        }
    }
}

struct ExtensionUISurfaceCompositeBase: Sendable, Equatable, Decodable {
    let id: String
    let header: ExtensionUISurfaceHeader
    let state: ExtensionUISurfaceState
    let actions: [String]?
    let fallback: ExtensionUISurfaceFallback
    let tone: String?
}

struct ExtensionUISurfaceStatusCard: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceCompositeBase
    let phase: String
    let steps: [ExtensionUISurfaceStep]?

    private enum CodingKeys: String, CodingKey {
        case composite, id, header, state, actions, fallback, tone, phase, steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try ExtensionUISurfaceCompositeBase(from: decoder)
        phase = (try? c.decode(String.self, forKey: .phase)) ?? "inactive"
        steps = try? c.decodeIfPresent([ExtensionUISurfaceStep].self, forKey: .steps)
    }

    /// Every composite carries the shared header, state, actions, fallback, and tone at its own
    /// top level, so encoding writes them flat rather than nested under `base`.
    private func encodeBase(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encode(base.id, forKey: .id)
        try c.encode(base.header, forKey: .header)
        try c.encode(base.state, forKey: .state)
        try c.encodeIfPresent(base.actions, forKey: .actions)
        try c.encode(base.fallback, forKey: .fallback)
        try c.encodeIfPresent(base.tone, forKey: .tone)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("statusCard", forKey: .composite)
        try encodeBase(into: &c)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(steps, forKey: .steps)
    }
}

struct ExtensionUISurfaceChecklist: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceCompositeBase
    let items: [ExtensionUISurfaceChecklistItem]

    private enum CodingKeys: String, CodingKey {
        case composite, id, header, state, actions, fallback, tone, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try ExtensionUISurfaceCompositeBase(from: decoder)
        // `items` is what this card is: a card whose items this build cannot read shows its
        // fallback text instead of an empty checklist.
        items = try c.decode([ExtensionUISurfaceChecklistItem].self, forKey: .items)
    }

    /// Every composite carries the shared header, state, actions, fallback, and tone at its own
    /// top level, so encoding writes them flat rather than nested under `base`.
    private func encodeBase(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encode(base.id, forKey: .id)
        try c.encode(base.header, forKey: .header)
        try c.encode(base.state, forKey: .state)
        try c.encodeIfPresent(base.actions, forKey: .actions)
        try c.encode(base.fallback, forKey: .fallback)
        try c.encodeIfPresent(base.tone, forKey: .tone)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("checklist", forKey: .composite)
        try encodeBase(into: &c)
        try c.encode(items, forKey: .items)
    }
}

struct ExtensionUISurfaceDataTable: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceCompositeBase
    let columns: [ExtensionUISurfaceColumn]
    let rows: [ExtensionUISurfaceRow]
    let sort: ExtensionUISurfaceSort?
    let selectedRowId: String?

    private enum CodingKeys: String, CodingKey {
        case composite, id, header, state, actions, fallback, tone, columns, rows, sort, selectedRowId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try ExtensionUISurfaceCompositeBase(from: decoder)
        // Columns and rows are the table: a table this build cannot read shows its fallback
        // text rather than an empty grid.
        columns = try c.decode([ExtensionUISurfaceColumn].self, forKey: .columns)
        rows = try c.decode([ExtensionUISurfaceRow].self, forKey: .rows)
        sort = try? c.decodeIfPresent(ExtensionUISurfaceSort.self, forKey: .sort)
        selectedRowId = try? c.decodeIfPresent(String.self, forKey: .selectedRowId)
    }

    /// Every composite carries the shared header, state, actions, fallback, and tone at its own
    /// top level, so encoding writes them flat rather than nested under `base`.
    private func encodeBase(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encode(base.id, forKey: .id)
        try c.encode(base.header, forKey: .header)
        try c.encode(base.state, forKey: .state)
        try c.encodeIfPresent(base.actions, forKey: .actions)
        try c.encode(base.fallback, forKey: .fallback)
        try c.encodeIfPresent(base.tone, forKey: .tone)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("dataTable", forKey: .composite)
        try encodeBase(into: &c)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encodeIfPresent(sort, forKey: .sort)
        try c.encodeIfPresent(selectedRowId, forKey: .selectedRowId)
    }
}

struct ExtensionUISurfaceActionBar: Sendable, Equatable, Codable {
    let base: ExtensionUISurfaceCompositeBase

    private enum CodingKeys: String, CodingKey {
        case composite, id, header, state, actions, fallback, tone
    }

    init(from decoder: Decoder) throws {
        base = try ExtensionUISurfaceCompositeBase(from: decoder)
    }

    /// Every composite carries the shared header, state, actions, fallback, and tone at its own
    /// top level, so encoding writes them flat rather than nested under `base`.
    private func encodeBase(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encode(base.id, forKey: .id)
        try c.encode(base.header, forKey: .header)
        try c.encode(base.state, forKey: .state)
        try c.encodeIfPresent(base.actions, forKey: .actions)
        try c.encode(base.fallback, forKey: .fallback)
        try c.encodeIfPresent(base.tone, forKey: .tone)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("actionBar", forKey: .composite)
        try encodeBase(into: &c)
    }
}

/// A tree of primitives. Its header is optional: a region may be nothing but its body.
struct ExtensionUISurfaceBlocks: Sendable, Equatable, Codable {
    let id: String
    let header: ExtensionUISurfaceHeader?
    let state: ExtensionUISurfaceState
    /// Action ids the region offers below its body, in drawing order.
    let actions: [String]?
    let fallback: ExtensionUISurfaceFallback
    let tone: String?
    let body: ExtensionUISurfaceNode

    private enum CodingKeys: String, CodingKey {
        case composite, id, header, state, actions, fallback, tone, body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        header = try? c.decodeIfPresent(ExtensionUISurfaceHeader.self, forKey: .header)
        state = (try? c.decode(ExtensionUISurfaceState.self, forKey: .state))
            ?? ExtensionUISurfaceState(kind: "content", title: nil, message: nil)
        actions = try? c.decodeIfPresent([String].self, forKey: .actions)
        fallback = (try? c.decode(ExtensionUISurfaceFallback.self, forKey: .fallback))
            ?? ExtensionUISurfaceFallback(text: "")
        tone = try? c.decodeIfPresent(String.self, forKey: .tone)
        // The body is the region: a tree this build cannot read shows its fallback text.
        body = try c.decode(ExtensionUISurfaceNode.self, forKey: .body)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("blocks", forKey: .composite)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(actions, forKey: .actions)
        try c.encode(fallback, forKey: .fallback)
        try c.encodeIfPresent(tone, forKey: .tone)
        try c.encode(body, forKey: .body)
    }
}

/// A section this build cannot draw: the host shows its `fallback.text` in a labeled placeholder.
struct ExtensionUISurfaceUnsupportedComposite: Sendable, Equatable {
    let id: String
    let composite: String
    let fallback: ExtensionUISurfaceFallback

    init(from decoder: Decoder, composite: String) throws {
        let c = try decoder.container(keyedBy: ExtensionUISurfaceUnsupportedKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? composite
        self.composite = composite
        fallback = (try? c.decode(ExtensionUISurfaceFallback.self, forKey: .fallback))
            ?? ExtensionUISurfaceFallback(text: "")
    }

    private enum ExtensionUISurfaceUnsupportedKeys: String, CodingKey {
        case composite, id, fallback
    }
}

extension ExtensionUISurfaceUnsupportedComposite: Encodable {
    /// A section this build cannot draw keeps the name it arrived under, so the frame still
    /// decodes to the same placeholder after a patch round trip.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ExtensionUISurfaceUnsupportedKeys.self)
        try c.encode(composite, forKey: .composite)
        try c.encode(id, forKey: .id)
        try c.encode(fallback, forKey: .fallback)
    }
}

// MARK: - Patch

/// Server → client: a change to a surface the client already holds, keyed by surface id.
struct ExtensionUISurfacePatch: Sendable, Equatable, Decodable {
    let surfaceId: String
    let revision: Int
    /// Dotted paths into the surface, merged by the client; `null` removes a field.
    let patch: [String: JSONValue]?
    /// The surface is gone: dismissed, settled, or replaced by nothing.
    let removed: Bool
    let sessionId: String?

    private enum CodingKeys: String, CodingKey {
        case surfaceId, revision, patch, removed, sessionId
    }

    init(
        surfaceId: String,
        revision: Int,
        patch: [String: JSONValue]? = nil,
        removed: Bool = false,
        sessionId: String? = nil
    ) {
        self.surfaceId = surfaceId
        self.revision = revision
        self.patch = patch
        self.removed = removed
        self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surfaceId = try c.decode(String.self, forKey: .surfaceId)
        revision = try c.decode(Int.self, forKey: .revision)
        patch = try c.decodeIfPresent([String: JSONValue].self, forKey: .patch)
        // A change carries no `removed`; only a surface that is gone says so.
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
    }
}
