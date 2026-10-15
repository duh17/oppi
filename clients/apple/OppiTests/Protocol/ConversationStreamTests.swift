import Foundation
import Testing
@testable import Oppi

/// The durable conversation stream against the server's fixtures
/// (`cd server && npm run protocol:fixtures:update` regenerates both).
@Suite("Conversation stream replica")
struct ConversationStreamTests {
    /// `protocol/conversation-stream.json` server examples, in the order the server built them.
    private static let serverSequence = [
        "snapshot", "update_append", "update_landing", "update_running_tool", "update_output_window",
        "update_queue", "update_partial", "update_hidden", "update_resume", "snapshot_after_compaction",
        "update_input_card", "older",
    ]

    @Test func everyFixtureMessageDecodes() throws {
        let messages = try fixtureMessages()
        let serverKeys = messages.keys.filter { $0.hasPrefix("server.") }.map { String($0.dropFirst(7)) }
        #expect(Set(serverKeys) == Set(Self.serverSequence))
        for key in serverKeys {
            _ = try JSONDecoder().decode(ConversationStreamServerMessage.self, from: json(messages, "server.\(key)"))
        }
        let attach = try JSONDecoder().decode(ConversationStreamAttach.self, from: json(messages, "client.attach_resume"))
        #expect(attach == ConversationStreamAttach(conversationId: 3, afterEntryId: 11, requestId: "req-attach-2"))
        let bySession = try JSONDecoder().decode(ConversationStreamAttach.self, from: json(messages, "client.attach_by_session"))
        #expect(bySession.sessionId == "test-session-1")
        let older = try JSONDecoder().decode(ConversationStreamOlderRequest.self, from: json(messages, "client.older"))
        #expect(older == ConversationStreamOlderRequest(beforeEntryId: 11, limit: 100, requestId: "req-older-1"))
        // What the client sends round-trips to the same wire object.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? NSDictionary
        #expect(encoded == (messages["client.older"] as? NSDictionary))
    }

    @Test func fixtureFramesApplyInOrder() throws {
        let messages = try fixtureMessages()
        var replica = ConversationReplica()
        func apply(_ key: String) throws {
            try replica.apply(JSONDecoder().decode(ConversationStreamServerMessage.self, from: json(messages, "server.\(key)")))
        }
        func doc(_ kind: String, _ path: JSONPath...) -> JSONValue? {
            path.reduce(replica.docs[kind]) { value, key in
                switch key {
                case .key(let name): value?.objectValue?[name]
                case .index(let index): value?.arrayValue.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                }
            }
        }

        try apply("snapshot")
        #expect(replica.entries.map(\.id) == [8, 9, 10])
        #expect(replica.head == 0 && replica.hasOlder == false)
        #expect(replica.resumeCursor == 10 && replica.oldestEntryId == 8)
        #expect(doc("pi.live", "generation", "message", "content", 0, "text") == "There are")

        try apply("update_append")  // a
        #expect(doc("pi.live", "generation", "message", "content", 0, "text") == "There are two entries.")

        try apply("update_landing")  // d on object keys, s on a nested key
        #expect(replica.entries.map(\.id) == [8, 9, 10, 11])
        #expect(replica.docs["pi.live"] == .object([:]))
        #expect(doc("pi.usage", "models", "anthropic/claude-sonnet-4-5", "output") == 82)

        try apply("update_running_tool")  // s creating keys
        #expect(doc("pi.live", "tools", 0, "output") == "README.md\n")
        #expect(doc("pi.live", "toolCalls", "call-1", "outputPresentation", "kind") == "terminal")

        try apply("update_output_window")  // t then a
        #expect(doc("pi.live", "tools", 0, "output") == "src\n")

        try apply("update_queue")  // p, m, d on an array index, s inside an array
        #expect(doc("pi.inbox", "items") == [
            ["id": 32, "mode": "steer", "content": "second"],
            ["id": 31, "mode": "followUp", "content": "first, edited"],
        ])

        try apply("update_partial")
        #expect(replica.entries.map(\.id) == [8, 9, 10, 11, 13])
        try apply("update_hidden")
        #expect(replica.entries.last == ConversationEntryView(id: 13, kind: "pi.assistant", hidden: true))

        try apply("update_resume")  // r per document, null removes one; 12 goes before 13
        #expect(replica.entries.map(\.id) == [8, 9, 10, 11, 12, 13])
        #expect(replica.docs["pi.inbox"] == ["items": []])
        #expect(replica.docs["oppi.extension-ui"] == nil)
        #expect(Set(replica.docs.keys) == ["pi.live", "pi.inbox", "pi.agent", "pi.usage"])

        try apply("snapshot_after_compaction")
        #expect(replica.entries.map(\.id) == [20, 11, 12])
        #expect(replica.head == 20 && replica.hasOlder)
        #expect(replica.resumeCursor == 20 && replica.oldestEntryId == 11)

        try apply("update_input_card")
        #expect(replica.entries.map(\.id) == [20, 11, 12, 21])

        try apply("older")
        #expect(replica.entries.map(\.id) == [8, 9, 10, 20, 11, 12, 21])
        #expect(replica.hasOlder == false && replica.oldestEntryId == 8)

        // The committed rows, in the full trace's order: the compaction after what it kept.
        let trace = ConversationTraceProjector.traceEvents(from: replica.entries)
        #expect(trace.map(\.id) == ["8", "call-1", "result-10", "11-text-0", "12", "20", "21"])
        #expect(trace.map(\.type) == [.user, .toolCall, .toolResult, .assistant, .system, .compaction, .system])
        #expect(trace[1].callSegments?.map(\.text) == ["$ ", "ls"])
        #expect(trace[1].outputPresentation?.kind == "terminal")
        #expect(trace[2].output == "README.md\nsrc\n")
        #expect(trace[5].text == "Context compacted: Listed files")
        #expect(trace[4].presentation?.output == nil)
        #expect(trace[6].presentation?.output == .init(kind: "terminal", entryId: "21", command: "npm test", truncated: nil))
        #expect(trace[6].text == "Background job 3\n\nnpm test\nResult: Exit 0")
        #expect(trace[6].timestamp == "2026-10-10T16:33:26.000Z")
    }

    @Test func framesForAnotherConversationAndMissingPathsThrow() throws {
        var replica = ConversationReplica()
        try replica.apply(.snapshot(.init(conversationId: 3, head: 0, hasOlder: false, entries: [], docs: ["d": ["a": "x"]])))
        #expect(throws: ConversationReplica.ApplyError.conversationMismatch(expected: 3, received: 4)) {
            try replica.apply(.update(.init(conversationId: 4)))
        }
        #expect(throws: ConversationReplica.ApplyError.unresolvablePath([.key("b")])) {
            try replica.apply(.update(.init(conversationId: 3, docs: ["d": [.append([.key("b")], "y")]])))
        }
        #expect(throws: ConversationReplica.ApplyError.unresolvablePath([.key("a")])) {
            try replica.apply(.update(.init(conversationId: 3, docs: ["missing": [.set([.key("a")], 1)]])))
        }
    }

    /// `protocol/conversation-stream-golden.json`: every frame one client received for a real
    /// Harness conversation, and that conversation's mobile trace. Replaying the frames and
    /// projecting the replica must give exactly the trace the timeline loads today.
    @Test func goldenFramesProjectToTheServerTrace() throws {
        struct Golden: Decodable {
            let frames: [ConversationStreamServerMessage]
            let trace: [TraceEvent]
        }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: Self.protocolURL("conversation-stream-golden.json")))
        var replica = ConversationReplica()
        for frame in golden.frames { try replica.apply(frame) }
        #expect(replica.hasOlder == false)

        // The fixture must cover what it claims to: guard against a vacuous regeneration.
        let types = Set(golden.trace.map(\.type))
        #expect(types == [.user, .assistant, .thinking, .toolCall, .toolResult, .system, .compaction])
        #expect(golden.trace.contains { $0.type == .toolResult && $0.isError == true })
        #expect(golden.trace.contains { $0.type == .user && $0.text?.contains("data:image/png;base64,") == true })
        #expect(golden.trace.contains { $0.presentation?.output != nil })
        #expect(golden.trace.contains { $0.type == .toolCall && $0.callSegments != nil && $0.outputPresentation?.kind == "terminal" })
        #expect(golden.frames.contains { if case .older(let page) = $0 { !page.entries.isEmpty } else { false } })
        #expect(golden.frames.contains { if case .snapshot(let snapshot) = $0 { snapshot.head != 0 } else { false } })

        let projected = ConversationTraceProjector.traceEvents(from: replica.entries)
        #expect(projected.map(\.id) == golden.trace.map(\.id))
        for (event, expected) in zip(projected, golden.trace) {
            #expect(event == expected, "\(expected.id)")
        }
    }

    // MARK: - Fixtures

    private enum JSONPath: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
        case key(String)
        case index(Int)
        init(stringLiteral value: String) { self = .key(value) }
        init(integerLiteral value: Int) { self = .index(value) }
    }

    private static func protocolURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Protocol/
            .deletingLastPathComponent()  // OppiTests/
            .deletingLastPathComponent()  // apple/
            .deletingLastPathComponent()  // clients/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol/\(name)")
    }

    private func fixtureMessages() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.protocolURL("conversation-stream.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["messages"] as? [String: Any])
    }

    private func json(_ messages: [String: Any], _ key: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: try #require(messages[key]))
    }
}
