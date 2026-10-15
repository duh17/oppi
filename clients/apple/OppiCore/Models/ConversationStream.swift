import Foundation

// Durable conversation stream (`capabilities.conversationStream` v1): a replica of one
// conversation's `{ entries, docs }` on the focused session socket. Wire reference:
// `dev/architecture-server/durable-conversation-stream.md`; canonical frames in
// `protocol/conversation-stream.json`. `ConversationReplica` applies the server frames.

/// Presentation of one tool call, rendered by the server's mobile renderer registry.
struct ConversationToolCallView: Codable, Equatable, Sendable {
    var callSegments: [StyledSegment]?
    var display: ToolDisplay?
    var inputPresentation: ToolInputPresentation?
    var outputPresentation: ToolOutputPresentation?
}

/// Presentation of one tool result, rendered by the server's mobile renderer registry.
struct ConversationToolResultView: Codable, Equatable, Sendable {
    var resultSegments: [StyledSegment]?
    var outputPresentation: ToolOutputPresentation?
    var outputAvailability: ToolOutputAvailability?
    /// Display name read from the result's details; replaces the call's.
    var display: ToolDisplay?
}

/// A transcript card, sanitized by the server like trace history.
struct ConversationEntryCard: Codable, Equatable, Sendable {
    struct Output: Codable, Equatable, Sendable {
        var kind: String
        var offset: Int
        var length: Int
        var command: String?
        var truncated: Bool?
    }

    var kind: String
    var title: String
    var subtitle: String?
    var status: String?
    var body: String?
    var fields: [TraceEventPresentationField]?
    var accent: String?
    var output: Output?
    /// Epoch milliseconds.
    var at: Double
}

/// One committed Durable entry with its server-rendered presentation. Clients upsert by
/// `id`. A hidden entry carries only `id`, `kind`, and `hidden`.
struct ConversationEntryView: Codable, Equatable, Sendable {
    var id: Int
    var kind: String
    /// Pi model messages as sent; absent on input cards.
    var model: [JSONValue]?
    /// Assistant entries: presentation by tool call id.
    var toolCalls: [String: ConversationToolCallView]?
    /// Tool-result entries: presentation of the result.
    var toolResult: ConversationToolResultView?
    /// Shown as this card instead of its content.
    var card: ConversationEntryCard?
    /// The card replaces an extension-generated input.
    var inputCard: Bool?
    /// Never shown.
    var hidden: Bool?
}

/// One path segment of a document op: an object key or an array index.
enum ConversationDocPathKey: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let index = try? container.decode(Int.self) {
            self = .index(index)
        } else {
            self = .key(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .key(let key): try container.encode(key)
        case .index(let index): try container.encode(index)
        }
    }
}

/// One Chord delta op (`@earendil-works/chord/delta`), applied in order to one document.
enum ConversationDocOp: Codable, Equatable, Sendable {
    /// `["r", value]`: replace the whole document.
    case replace(JSONValue)
    /// `["s", path, value]`: set.
    case set([ConversationDocPathKey], JSONValue)
    /// `["d", path]`: delete an object key or array element.
    case delete([ConversationDocPathKey])
    /// `["a", path, text]`: append to a string.
    case append([ConversationDocPathKey], String)
    /// `["t", path, n]`: drop the first `n` UTF-16 code units of a string.
    case truncate([ConversationDocPathKey], Int)
    /// `["p", path, index, deleteCount, items]`: splice an array.
    case splice([ConversationDocPathKey], index: Int, deleteCount: Int, items: [JSONValue])
    /// `["m", path, permutation]`: reorder an array, `new[i] = old[permutation[i]]`.
    case move([ConversationDocPathKey], [Int])

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let tag = try container.decode(String.self)
        switch tag {
        case "r":
            self = .replace(try container.decode(JSONValue.self))
        case "s":
            self = .set(try container.decode([ConversationDocPathKey].self), try container.decode(JSONValue.self))
        case "d":
            self = .delete(try container.decode([ConversationDocPathKey].self))
        case "a":
            self = .append(try container.decode([ConversationDocPathKey].self), try container.decode(String.self))
        case "t":
            self = .truncate(try container.decode([ConversationDocPathKey].self), try container.decode(Int.self))
        case "p":
            let path = try container.decode([ConversationDocPathKey].self)
            self = .splice(
                path,
                index: try container.decode(Int.self),
                deleteCount: try container.decode(Int.self),
                items: try container.decode([JSONValue].self)
            )
        case "m":
            self = .move(try container.decode([ConversationDocPathKey].self), try container.decode([Int].self))
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown document op \(tag)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .replace(let value):
            try container.encode("r")
            try container.encode(value)
        case .set(let path, let value):
            try container.encode("s")
            try container.encode(path)
            try container.encode(value)
        case .delete(let path):
            try container.encode("d")
            try container.encode(path)
        case .append(let path, let text):
            try container.encode("a")
            try container.encode(path)
            try container.encode(text)
        case .truncate(let path, let count):
            try container.encode("t")
            try container.encode(path)
            try container.encode(count)
        case .splice(let path, let index, let deleteCount, let items):
            try container.encode("p")
            try container.encode(path)
            try container.encode(index)
            try container.encode(deleteCount)
            try container.encode(items)
        case .move(let path, let permutation):
            try container.encode("m")
            try container.encode(path)
            try container.encode(permutation)
        }
    }
}

/// Replaces the replica: sent on attach, for an unusable cursor, and when the head moves.
struct ConversationStreamSnapshot: Codable, Equatable, Sendable {
    var conversationId: Int
    /// Id of the head entry (reset or compaction) that starts `entries`, or 0.
    var head: Int
    /// Older entries exist before the first entry sent.
    var hasOlder: Bool
    /// Shown active entries in display order: the head entry first, when there is one.
    var entries: [ConversationEntryView]
    /// Client-visible documents by kind.
    var docs: [String: JSONValue]
}

/// One coalesced batch of whole commits.
struct ConversationStreamUpdate: Codable, Equatable, Sendable {
    var conversationId: Int
    /// Entries to upsert by id, in order.
    var entries: [ConversationEntryView]?
    /// Ops per document kind; `nil` means the document is gone.
    var docs: [String: [ConversationDocOp]?]?
}

/// Answer to `ConversationStreamOlderRequest`: entries before the requested id, oldest first.
struct ConversationStreamOlderPage: Codable, Equatable, Sendable {
    var conversationId: Int
    var entries: [ConversationEntryView]
    /// Still older entries exist.
    var hasOlder: Bool
}

/// Server → client frames of the conversation stream.
enum ConversationStreamServerMessage: Decodable, Equatable, Sendable {
    case snapshot(ConversationStreamSnapshot)
    case update(ConversationStreamUpdate)
    case older(ConversationStreamOlderPage)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        switch type {
        case "snapshot": self = .snapshot(try ConversationStreamSnapshot(from: decoder))
        case "update": self = .update(try ConversationStreamUpdate(from: decoder))
        case "older": self = .older(try ConversationStreamOlderPage(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a conversation stream frame: \(type)"
            ))
        }
    }
}

/// Client → server: start (or restart) the stream on a focused session socket.
struct ConversationStreamAttach: Codable, Equatable, Sendable {
    var type = "attach"
    var conversationId: Int?
    var sessionId: String?
    /// Newest entry id the client holds (`ConversationReplica.resumeCursor`).
    var afterEntryId: Int?
    var requestId: String?
}

/// Client → server: page entries older than the replica holds, after `attach`.
struct ConversationStreamOlderRequest: Codable, Equatable, Sendable {
    var type = "older"
    /// The smallest entry id the client holds (`ConversationReplica.oldestEntryId`).
    var beforeEntryId: Int
    var limit: Int?
    var requestId: String?
}
