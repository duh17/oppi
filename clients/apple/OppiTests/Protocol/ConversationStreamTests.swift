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
    /// The live tail of conversation 5, a subagent of 3, on the same socket.
    private static let liveSequence = ["live_snapshot", "live_update"]

    @Test func everyFixtureMessageDecodes() throws {
        let messages = try fixtureMessages()
        let serverKeys = messages.keys.filter { $0.hasPrefix("server.") }.map { String($0.dropFirst(7)) }
        #expect(Set(serverKeys) == Set(Self.serverSequence + Self.liveSequence))
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
        let live = ConversationStreamAttach(conversationId: 5, mode: .live, requestId: "req-attach-3")
        let detach = ConversationStreamDetach(conversationId: 5, requestId: "req-detach-1")
        for (key, message) in [("client.attach_live", ClientMessage.conversationAttach(live)), ("client.detach", .conversationDetach(detach))] {
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? NSDictionary
            #expect(wire == (messages[key] as? NSDictionary), "\(key)")
        }
    }

    /// A live tail replica holds only `pi.live` and `pi.inbox`, and no entries.
    @MainActor @Test func liveTailFramesApplyToTheirOwnReplica() throws {
        let messages = try fixtureMessages()
        let driver = ConversationStreamDriver(liveConversationId: 5)
        _ = driver.attachRequest(fresh: false)
        for key in Self.liveSequence {
            let frame = try JSONDecoder().decode(ConversationStreamServerMessage.self, from: json(messages, "server.\(key)"))
            #expect(frame.conversationId == 5)
            #expect(driver.receiveLive(frame) == .applied, "\(key)")
        }
        #expect(driver.replica.entries.isEmpty)
        #expect(Set(driver.replica.docs.keys) == ["pi.live", "pi.inbox"])
        let tool = try #require(driver.liveTail.tools.first)
        #expect(driver.liveTail.isRunning && tool.running && tool.output == "tick 1\ntick 2\n")
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
        #expect(doc("pi.inbox", "steering") == [["id": "32", "message": "second", "createdAt": 1_791_650_004_000]])
        #expect(doc("pi.inbox", "followUp", 0, "id") == "33")
        #expect(doc("pi.inbox", "followUp", 0, "attachments", 0, "name") == "notes.txt")
        #expect(doc("pi.inbox", "followUp", 1) == ["id": "31", "message": "first, edited", "createdAt": 1_791_650_003_000])
        #expect(doc("pi.inbox", "followUp")?.arrayValue?.count == 2)

        try apply("update_partial")
        #expect(replica.entries.map(\.id) == [8, 9, 10, 11, 13])
        try apply("update_hidden")
        #expect(replica.entries.last == ConversationEntryView(id: 13, kind: "pi.assistant", hidden: true))

        try apply("update_resume")  // r per document, null removes one; 12 goes before 13
        #expect(replica.entries.map(\.id) == [8, 9, 10, 11, 12, 13])
        #expect(replica.docs["pi.inbox"] == ["steering": [], "followUp": []])
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

    /// A user entry's stored image block projects to `media`, not to inline bytes, and an
    /// image the server could not store stays a data URI in the text.
    @Test func userEntryProjectionSplitsStoredImagesFromInlineFallback() throws {
        let content: JSONValue = .array([
            .object(["type": .string("text"), "text": .string("look at this")]),
            .object([
                "type": .string("image"),
                "mimeType": .string("image/png"),
                "attachment": .object([
                    "kind": .string("image"),
                    "id": .string("att_user_abc"),
                    "mimeType": .string("image/png"),
                    "sessionId": .string("session-owner"),
                    "fileName": .string("user-image.png"),
                    "sizeBytes": .number(68),
                    "width": .number(1206),
                    "height": .number(2622),
                ]),
            ]),
            .object([
                "type": .string("image"),
                "data": .string("QUJD"),
                "mimeType": .string("image/jpeg"),
            ]),
        ])
        let entry = ConversationEntryView(
            id: 7,
            kind: "pi.user",
            model: [.object(["role": .string("user"), "content": content, "timestamp": .number(1_791_650_000_000)])]
        )

        let events = ConversationTraceProjector.traceEvents(from: [entry])
        let event = try #require(events.first)
        #expect(event.type == .user)
        #expect(event.text == "look at this\ndata:image/jpeg;base64,QUJD")
        let media = try #require(event.media)
        // One stored reference, then a placeholder for the image left inline in the text.
        #expect(media.count == 2)
        #expect(media[0].id == "att_user_abc")
        #expect(media[0].kind == "image")
        #expect(media[0].mimeType == "image/png")
        #expect(media[0].width == 1206)
        #expect(media[0].height == 2622)
        #expect(media[0].sessionId == "session-owner")
        #expect(media[1].id == nil)
        #expect(media[1].inline == true)
    }

    /// A message that mixes a stored image with one the server left inline keeps content order:
    /// the inline block is a placeholder in `media`, paired with its data URI by the reducer.
    @MainActor
    @Test func userEntryKeepsImageOrderAcrossAStoredAndInlineMix() throws {
        let content: JSONValue = .array([
            .object(["type": .string("text"), "text": .string("caption")]),
            .object([
                "type": .string("image"),
                "data": .string("QUJD"),
                "mimeType": .string("image/jpeg"),
            ]),
            .object([
                "type": .string("image"),
                "mimeType": .string("image/png"),
                "attachment": .object([
                    "kind": .string("image"),
                    "id": .string("att_user_second"),
                    "mimeType": .string("image/png"),
                ]),
            ]),
        ])
        let entry = ConversationEntryView(
            id: 7,
            kind: "pi.user",
            model: [.object(["role": .string("user"), "content": content, "timestamp": .number(1_791_650_000_000)])]
        )

        let event = try #require(ConversationTraceProjector.traceEvents(from: [entry]).first)
        #expect(event.text == "caption\ndata:image/jpeg;base64,QUJD")
        let media = try #require(event.media)
        #expect(media.count == 2)
        #expect(media[0].inline == true)
        #expect(media[0].id == nil)
        #expect(media[0].mimeType == "image/jpeg")
        #expect(media[1].id == "att_user_second")
        #expect(media[1].inline == nil)

        // The reducer shows the inline image first, then the stored one.
        let reducer = TimelineReducer()
        reducer.loadSession([event])
        guard case .userMessage(_, let text, let images, _) = reducer.items[0] else {
            Issue.record("Expected a user message row")
            return
        }
        #expect(text == "caption")
        #expect(images.count == 2)
        #expect(images[0].storedAttachmentID == nil)
        #expect(images[0].data == "QUJD")
        #expect(images[1].storedAttachmentID == "att_user_second")
    }

    @Test func userEntryWithOnlyAStoredImageStillProjectsARow() throws {
        let content: JSONValue = .array([
            .object([
                "type": .string("image"),
                "mimeType": .string("image/png"),
                "attachment": .object([
                    "kind": .string("image"),
                    "id": .string("att_user_abc"),
                    "mimeType": .string("image/png"),
                ]),
            ]),
        ])
        let entry = ConversationEntryView(
            id: 7,
            kind: "pi.user",
            model: [.object(["role": .string("user"), "content": content, "timestamp": .number(1_791_650_000_000)])]
        )

        let event = try #require(ConversationTraceProjector.traceEvents(from: [entry]).first)
        #expect(event.type == .user)
        #expect(event.text?.isEmpty == true)
        #expect(event.media?.map(\.id) == ["att_user_abc"])
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
        // A user photo is a stored attachment reference, not inline bytes.
        #expect(golden.trace.contains {
            $0.type == .user && $0.media?.contains { $0.kind == "image" } == true
        })
        #expect(golden.trace.contains { $0.type == .user && $0.text?.contains("data:image/") == true } == false)
        let sentEntries = golden.frames.flatMap { frame -> [ConversationEntryView] in
            switch frame {
            case .snapshot(let snapshot): return snapshot.entries
            case .update(let update): return update.entries ?? []
            case .older(let page): return page.entries
            }
        }
        #expect(sentEntries.contains { entry in
            let content = entry.model?.first?.objectValue?["content"]?.arrayValue
            return content?.contains { block in
                block.objectValue?["type"]?.stringValue == "image"
                    && block.objectValue?["attachment"]?.objectValue?["id"]?.stringValue != nil
                    && block.objectValue?["data"] == nil
            } == true
        })
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
