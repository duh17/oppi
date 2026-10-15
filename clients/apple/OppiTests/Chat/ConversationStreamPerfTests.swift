import Foundation
import Testing
@testable import Oppi

/// Main-thread cost of one conversation stream frame against a long conversation: decode,
/// replica apply, projection, and reducer, for a live text append and for an entry landing.
/// Prints `PERF conversation-stream ...` lines; the assertions check the paths taken.
@Suite("Conversation stream frame cost")
@MainActor
struct ConversationStreamPerfTests {
    private static let turns = 400  // 4 entries each: 1,600 entries

    @Test func liveAppendAndLandingFramesOnALongConversation() throws {
        let reducer = TimelineReducer()
        let driver = ConversationStreamDriver()
        var entries: [ConversationEntryView] = []
        for turn in 0..<Self.turns {
            let base = turn * 4 + 1
            let callId = "call-\(turn)"
            entries.append(Wire.user(base, "Turn \(turn): " + String(repeating: "please look at this file ", count: 6)))
            var call = Wire.assistant(base + 1, [
                Wire.thinking(String(repeating: "Considering the request. ", count: 12)),
                Wire.text("Running the command."),
                Wire.toolCall(callId, "bash", ["command": .string("cat file-\(turn).txt")]),
            ])
            call.toolCalls = [callId: .init(outputPresentation: .init(kind: "terminal"))]
            entries.append(call)
            entries.append(Wire.toolResult(base + 2, callId: callId, output: String(repeating: "line of output\n", count: 60)))
            entries.append(Wire.assistant(base + 3, [Wire.text(String(repeating: "The file says something useful. ", count: 20))]))
        }
        let snapshot = ConversationStreamSnapshot(conversationId: 1, head: 0, hasOlder: false, entries: entries, docs: [
            "pi.live": Wire.live(text: "Start"),
        ])
        #expect(driver.receive(.snapshot(snapshot), into: reducer, presentationPaused: false) == .applied)
        let committedRows = reducer.items.count - 1

        // (a) Live text append: one `a` op on the streaming answer.
        let appendText = try Self.frameJSON(type: "update", ConversationStreamUpdate(conversationId: 1, docs: ["pi.live": [
            .append([.key("generation"), .key("message"), .key("content"), .index(0), .key("text")], " and more words"),
        ]]))
        var liveDecode: [Double] = []
        var liveApply: [Double] = []
        for _ in 0..<300 {
            let (frame, decodeMs) = try Self.measure { try Self.decode(appendText) }
            let (_, applyMs) = Self.measure { driver.receive(frame, into: reducer, presentationPaused: false) }
            liveDecode.append(decodeMs)
            liveApply.append(applyMs)
        }
        #expect(reducer.items.count == committedRows + 1)

        // (b) Entry landing: the answer commits and leaves `pi.live`, then the next streams.
        var nextId = Self.turns * 4 + 1
        var landingDecode: [Double] = []
        var landingApply: [Double] = []
        var incremental = 0
        for _ in 0..<200 {
            let landing = try Self.frameJSON(type: "update", ConversationStreamUpdate(
                conversationId: 1,
                entries: [Wire.assistant(nextId, [Wire.text(String(repeating: "A landed answer. ", count: 20))])],
                docs: ["pi.live": [.delete([.key("generation")])]]
            ))
            let (frame, decodeMs) = try Self.measure { try Self.decode(landing) }
            let (_, applyMs) = Self.measure { driver.receive(frame, into: reducer, presentationPaused: false) }
            landingDecode.append(decodeMs)
            landingApply.append(applyMs)
            if reducer._lastLoadWasIncrementalForTesting { incremental += 1 }
            nextId += 1
            let restart = ConversationStreamUpdate(conversationId: 1, docs: ["pi.live": [
                .set([.key("generation")], ["attempt": 1, "message": ["role": "assistant", "content": [Wire.text("Next")], "timestamp": 1]]),
            ]])
            _ = driver.receive(.update(restart), into: reducer, presentationPaused: false)
        }
        #expect(incremental == 200)
        #expect(reducer.items.count == committedRows + 200 + 1)
        #expect(reducer.traceEventsForCache() == ConversationTraceProjector.traceEvents(from: driver.replica.entries))

        Self.report("live text append decode", liveDecode)
        Self.report("live text append apply", liveApply)
        Self.report("entry landing decode", landingDecode)
        Self.report("entry landing apply", landingApply)
    }

    private static func frameJSON(type: String, _ body: some Encodable) throws -> String {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        object["type"] = type
        return try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private static func decode(_ text: String) throws -> ConversationStreamServerMessage {
        guard case .conversationStream(let frame) = try StreamMessage.decode(from: text).message else {
            throw CocoaError(.coderReadCorrupt)
        }
        return frame
    }

    private static func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try body()
        let elapsed = ContinuousClock.now - start
        return (value, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
    }

    private static func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print(String(
            format: "PERF conversation-stream %@ (%d frames, %d entries): median %.3f ms, p95 %.3f ms, max %.3f ms",
            name, samples.count, Self.turns * 4, median, p95, sorted.last ?? 0
        ))
    }
}
