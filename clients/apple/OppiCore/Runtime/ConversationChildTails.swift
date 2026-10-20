import Foundation

/// A conversation a tool call's details name with `{ conversationId, sessionId }`, as the durable
/// `subagent` tool's details do for the child it spawned or messaged. The parent's timeline shows
/// that conversation's live tail under the call's row. It is read from the details' keys, never
/// from a tool name.
struct ConversationChildReference: Equatable, Sendable {
    var conversationId: Int
    var sessionId: String
    /// The newest tool call naming it: the row its tail goes under.
    var toolCallId: String

    init(conversationId: Int, sessionId: String, toolCallId: String) {
        self.conversationId = conversationId
        self.sessionId = sessionId
        self.toolCallId = toolCallId
    }

    init?(details: JSONValue?, toolCallId: String) {
        guard let object = details?.objectValue,
              let number = object["conversationId"]?.numberValue,
              number >= 0, number.rounded() == number, number <= Double(Int.max),
              let sessionId = object["sessionId"]?.stringValue, !sessionId.isEmpty
        else { return nil }
        self.init(conversationId: Int(number), sessionId: sessionId, toolCallId: toolCallId)
    }
}

/// The child conversations a replica's tool calls name, kept as frames apply: committed tool
/// results in entry order, then the calls of the running round in `pi.live`.
struct ConversationChildIndex: Equatable, Sendable {
    private var committed: [ConversationChildReference] = []
    private var live: [ConversationChildReference] = []

    mutating func reindex(_ entries: [ConversationEntryView]) {
        committed = []
        append(entries)
    }

    mutating func append(_ entries: some Sequence<ConversationEntryView>) {
        for entry in entries {
            guard let message = entry.model?.first?.objectValue,
                  message["role"]?.stringValue == "toolResult",
                  let callId = message["toolCallId"]?.stringValue,
                  let reference = ConversationChildReference(details: message["details"], toolCallId: callId)
            else { continue }
            committed.append(reference)
        }
    }

    mutating func updateLive(_ document: JSONValue?) {
        live = (document?.objectValue?["tools"]?.arrayValue ?? []).compactMap { slot in
            guard let slot = slot.objectValue, let callId = slot["callId"]?.stringValue else { return nil }
            return ConversationChildReference(details: slot["details"], toolCallId: callId)
        }
    }

    /// The newest `limit` children, oldest first, each with the newest call that names it.
    func children(limit: Int) -> [ConversationChildReference] {
        var seen = Set<Int>()
        var newest: [ConversationChildReference] = []
        for reference in (committed + live).reversed() where seen.insert(reference.conversationId).inserted {
            newest.append(reference)
            if newest.count == limit { break }
        }
        return newest.reversed()
    }
}

/// One child's live tail as the parent's timeline shows it, read-only, under the tool row of
/// `reference.toolCallId`.
struct ConversationChildTail: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Text the child is writing.
            case text
            case thinking
            /// A tool call of its running round.
            case tool
            /// The newest output of a running tool.
            case output
            /// Compaction or retry.
            case status
        }

        var kind: Kind
        var text: String
    }

    static let maxLines = 6
    private static let textLines = 3
    private static let outputLines = 2

    var reference: ConversationChildReference
    var lines: [Line]
    /// Lines the row keeps room for: the most it has shown while the child stays busy, so its
    /// height does not follow every frame.
    var reservedLines = 0

    /// Nil while the child is idle: there is nothing live to show.
    init?(reference: ConversationChildReference, tail: TimelineLiveTail) {
        guard tail.isRunning else { return nil }
        self.reference = reference
        lines = Self.lines(tail)
    }

    init(reference: ConversationChildReference, lines: [Line]) {
        self.reference = reference
        self.lines = lines
    }

    /// The end of what the child is doing: its newest text lines, the calls of its round with
    /// their newest output, then compaction and retry status. At most `maxLines`.
    static func lines(_ tail: TimelineLiveTail) -> [Line] {
        var lines: [Line] = []
        let outputs = Dictionary(tail.tools.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let streamedCalls = Set(tail.blocks.compactMap { block -> String? in
            if case .toolCall(let id, _, _, _) = block { id } else { nil }
        })
        // The running round of an answer already committed: the parent holds no row for it.
        for tool in tail.tools where !streamedCalls.contains(tool.id) {
            lines.append(Line(kind: .tool, text: firstLine(title(tool.view) ?? tool.name)))
            if tool.running {
                lines += lastLines(tool.output, Self.outputLines).map { Line(kind: .output, text: $0) }
            }
        }
        for (index, block) in tail.blocks.enumerated() {
            switch block {
            case .text(_, let text):
                lines += lastLines(text, Self.textLines).map { Line(kind: .text, text: $0) }
            case .thinking:
                // Only while it is the newest thing the child does.
                if index == tail.blocks.count - 1 { lines.append(Line(kind: .thinking, text: "Thinking\u{2026}")) }
            case .toolCall(let id, let name, _, let view):
                lines.append(Line(kind: .tool, text: firstLine(title(view) ?? name)))
                if let tool = outputs[id], tool.running {
                    lines += lastLines(tool.output, Self.outputLines).map { Line(kind: .output, text: $0) }
                }
            }
        }
        if tail.isCompacting { lines.append(Line(kind: .status, text: "Compacting\u{2026}")) }
        if let retry = tail.retry { lines.append(Line(kind: .status, text: "Retrying: \(firstLine(retry.error))")) }
        // Busy before its first token, or between rounds.
        if lines.isEmpty { lines.append(Line(kind: .status, text: "Working\u{2026}")) }
        return Array(lines.suffix(maxLines))
    }

    /// The call's rendered title, as its row would show it.
    private static func title(_ view: ConversationToolCallView?) -> String? {
        guard let text = view?.callSegments?.map(\.text).joined(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func lastLines(_ text: String, _ count: Int) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .map { String($0) }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}
