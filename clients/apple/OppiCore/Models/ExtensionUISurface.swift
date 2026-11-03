import Foundation

/// A composable extension surface, version 2 (`protocol/surfaces/`). The extension supplies data,
/// action ids, and the words for loading, empty, and failure; the host draws every region with
/// views it already ships. No colour, font, padding, or size crosses the wire.
struct ExtensionUISurface: Sendable, Equatable, Identifiable, Decodable {
    let version: Int
    let id: String
    let title: String
    let placement: ExtensionUISurfacePlacement
    let lifecycle: String
    /// `oneShot` only: epoch milliseconds by which the surface settles.
    let timeoutAt: Double?
    let header: ExtensionUISurfaceHeader
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
        }
        return ids
    }
}

struct ExtensionUISurfacePlacement: Sendable, Equatable, Decodable {
    let kind: String
    let preferred: String?
}

struct ExtensionUISurfaceHeader: Sendable, Equatable, Decodable {
    let title: String
    let subtitle: String?
}

struct ExtensionUISurfaceFallback: Sendable, Equatable, Decodable {
    let text: String
}

struct ExtensionUISurfaceState: Sendable, Equatable, Decodable {
    let kind: String
    let title: String?
    let message: String?

    var isContent: Bool { kind == "content" }
}

struct ExtensionUISurfaceActionDefinition: Sendable, Equatable, Decodable {
    let title: String
    let role: String?
    let pending: ExtensionUISurfacePendingState?

    var isPrimary: Bool { role == "primary" }
    var isDestructive: Bool { role == "destructive" }
}

/// Optimistic state for the round trip only: what the pressed action shows while it waits.
struct ExtensionUISurfacePendingState: Sendable, Equatable, Decodable {
    let title: String?
    let disabled: [String]?
}

/// An atom fills a slot a composite exposes; atoms never sit at a surface's top level.
enum ExtensionUISurfaceAtom: Sendable, Equatable, Decodable {
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
}

struct ExtensionUISurfaceStep: Sendable, Equatable, Decodable, Identifiable {
    let id: String
    let title: String
    let state: String
    let detail: String?
    let extra: [ExtensionUISurfaceAtom]?
}

struct ExtensionUISurfaceChecklistItem: Sendable, Equatable, Decodable, Identifiable {
    let id: String
    let title: String
    let state: String
    let detail: String?
}

struct ExtensionUISurfaceColumn: Sendable, Equatable, Decodable, Identifiable {
    let id: String
    let title: String
    let kind: String?

    var isNumeric: Bool { kind == "number" }
}

/// A table cell as the wire allows it: text, a number, or nothing.
enum ExtensionUISurfaceCell: Sendable, Equatable, Decodable {
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

struct ExtensionUISurfaceRow: Sendable, Equatable, Decodable, Identifiable {
    let id: String
    let cells: [String: ExtensionUISurfaceCell]
    let actions: [String]?

    func cell(_ columnId: String) -> ExtensionUISurfaceCell {
        cells[columnId] ?? .empty
    }
}

struct ExtensionUISurfaceSort: Sendable, Equatable, Decodable {
    let columnId: String
    let descending: Bool?
}

/// The composites this slice draws. A composite it does not draw decodes to `unsupported` with
/// its fallback text, never a thrown error.
enum ExtensionUISurfaceSection: Sendable, Equatable, Decodable, Identifiable {
    case statusCard(ExtensionUISurfaceStatusCard)
    case checklist(ExtensionUISurfaceChecklist)
    case dataTable(ExtensionUISurfaceDataTable)
    case actionBar(ExtensionUISurfaceActionBar)
    case unsupported(ExtensionUISurfaceUnsupportedComposite)

    var id: String {
        switch self {
        case .statusCard(let value): return value.base.id
        case .checklist(let value): return value.base.id
        case .dataTable(let value): return value.base.id
        case .actionBar(let value): return value.base.id
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
        case .unsupported: return nil
        }
    }

    var actions: [String]? { base?.actions }

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
        default:
            break
        }
        // Known or unknown: a card this build cannot read keeps its words and its id, so the host
        // shows a labeled placeholder instead of dropping the section or throwing the frame.
        self = .unsupported(
            try ExtensionUISurfaceUnsupportedComposite(from: decoder, composite: composite)
        )
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

struct ExtensionUISurfaceStatusCard: Sendable, Equatable, Decodable {
    let base: ExtensionUISurfaceCompositeBase
    let phase: String
    let steps: [ExtensionUISurfaceStep]?

    private enum CodingKeys: String, CodingKey {
        case id, header, state, actions, fallback, tone, phase, steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try ExtensionUISurfaceCompositeBase(from: decoder)
        phase = (try? c.decode(String.self, forKey: .phase)) ?? "inactive"
        steps = try? c.decodeIfPresent([ExtensionUISurfaceStep].self, forKey: .steps)
    }
}

struct ExtensionUISurfaceChecklist: Sendable, Equatable, Decodable {
    let base: ExtensionUISurfaceCompositeBase
    let items: [ExtensionUISurfaceChecklistItem]

    private enum CodingKeys: String, CodingKey {
        case id, header, state, actions, fallback, tone, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try ExtensionUISurfaceCompositeBase(from: decoder)
        // `items` is what this card is: a card whose items this build cannot read shows its
        // fallback text instead of an empty checklist.
        items = try c.decode([ExtensionUISurfaceChecklistItem].self, forKey: .items)
    }
}

struct ExtensionUISurfaceDataTable: Sendable, Equatable, Decodable {
    let base: ExtensionUISurfaceCompositeBase
    let columns: [ExtensionUISurfaceColumn]
    let rows: [ExtensionUISurfaceRow]
    let sort: ExtensionUISurfaceSort?
    let selectedRowId: String?

    private enum CodingKeys: String, CodingKey {
        case id, header, state, actions, fallback, tone, columns, rows, sort, selectedRowId
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
}

struct ExtensionUISurfaceActionBar: Sendable, Equatable, Decodable {
    let base: ExtensionUISurfaceCompositeBase

    init(from decoder: Decoder) throws {
        base = try ExtensionUISurfaceCompositeBase(from: decoder)
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
        case id, fallback
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
