import Foundation
import Testing
@testable import Oppi

/// A durable session on a server with `capabilities.conversationStream`: the chat runtime
/// attaches on the focused socket and its timeline comes from the replica.
@Suite("Conversation stream session")
@MainActor
struct ConversationStreamSessionTests {
    @Test func firstAttachHasNoCursorAndReconnectResumesFromTheReplica() async throws {
        let harness = Harness()
        await harness.connect()
        let first = try await harness.attach(1)
        #expect(first.afterEntryId == nil && first.conversationId == nil)

        harness.yield(.commandResult(command: "attach", requestId: first.requestId, success: true, data: nil, error: nil))
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "List the files"), Wire.assistant(2, [Wire.text("Two files.")]),
        ], docs: [:])))
        #expect(await harness.waitForRows(["1", "2-text-0"]))

        // The socket drops and recovers: resume from the newest held entry.
        harness.yield(.connected(session: harness.session))
        let resumed = try await harness.attach(2)
        #expect(resumed.conversationId == 7 && resumed.afterEntryId == 2)

        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(3, "And now?")])))
        #expect(await harness.waitForRows(["1", "2-text-0", "3"]))
        await harness.finish()
    }

    @Test func classicSessionKeepsTheEventPath() async {
        let harness = Harness(engine: .classic)
        await harness.connect()
        harness.yield(.textDelta(delta: "streamed"))
        #expect(await waitForMainActorCondition {
            harness.manager.coalescer.flushNow()
            return harness.manager.reducer.items.contains { if case .assistantMessage = $0 { true } else { false } }
        })
        #expect(harness.manager.conversationStream == nil)
        #expect(harness.attaches.isEmpty)
        await harness.finish()
    }

    @Test func frameThatDoesNotApplyAttachesFreshAndWaitsForTheSnapshot() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "hi")], docs: [:])))
        #expect(await harness.waitForRows(["1"]))

        // An op on a document the replica does not hold.
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [.append([.key("generation")], "x")]])))
        let fresh = try await harness.attach(2)
        #expect(fresh.afterEntryId == nil && fresh.conversationId == nil)

        // Frames of the replaced subscription are dropped until the snapshot.
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(5, "stale")])))
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "hi"), Wire.user(2, "again"),
        ], docs: [:])))
        #expect(await harness.waitForRows(["1", "2"]))
        await harness.finish()
    }

    @Test func failedAttachRetriesFreshOnceThenFailsTheConnection() async throws {
        let harness = Harness()
        await harness.connect()
        let first = try await harness.attach(1)
        harness.yield(.commandResult(command: "attach", requestId: first.requestId, success: false, data: nil, error: "busy"))
        let retry = try await harness.attach(2)
        #expect(retry.afterEntryId == nil)
        harness.yield(.commandResult(command: "attach", requestId: retry.requestId, success: false, data: nil, error: "not durable"))

        #expect(await waitForMainActorCondition {
            harness.manager.reducer.items.contains {
                if case .error(_, let message) = $0 { message.contains("not durable") } else { false }
            }
        })
        #expect(await waitForMainActorCondition {
            if case .disconnected = harness.manager.entryState { true } else { false }
        })
        // Terminal: no reconnect loop attaching again.
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(600)) {
            harness.streams.streamsCreated == 1 && harness.attaches.count == 2
        })
        await harness.finish()
    }

    @Test func appendOnlyUpdateLoadsIncrementallyAndLiveFramesLeaveCommittedRowsAlone() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "a"), Wire.assistant(2, [Wire.text("b")]),
        ], docs: [:])))
        #expect(await harness.waitForRows(["1", "2-text-0"]))
        #expect(!reducer._lastLoadWasIncrementalForTesting)

        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(3, "c")])))
        #expect(await harness.waitForRows(["1", "2-text-0", "3"]))
        #expect(reducer._lastLoadWasIncrementalForTesting)

        // A live frame changes only the live row.
        let committedBefore = Array(reducer.items.prefix(3))
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [.replace(Wire.live(text: "Wor"))]])))
        #expect(await harness.waitForRows(["1", "2-text-0", "3", "pi.live-0-text-0"]))
        let versionBefore = reducer.renderVersion
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [
            .append([.key("generation"), .key("message"), .key("content"), .index(0), .key("text")], "king"),
        ]])))
        #expect(await waitForMainActorCondition { reducer.renderVersion > versionBefore })
        #expect(Array(reducer.items.prefix(3)) == committedBefore)
        #expect(harness.assistantText("pi.live-0-text-0") == "Working")
        #expect(reducer.streamingAssistantID == "pi.live-0-text-0")
        await harness.finish()
    }

    @Test func landingReplacesLiveRowsWithCommittedRowsOnce() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [
            "pi.live": Wire.live(content: [Wire.thinking("plan"), Wire.toolCall("call-1", "bash", ["command": "ls"])]),
        ])))
        #expect(await harness.waitForRows(["1", "pi.live-0-think-0", "call-1"]))
        #expect(harness.isDone("call-1") == false)

        // The answer lands; the run goes on to execute the call.
        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.assistant(2, [Wire.thinking("plan"), Wire.toolCall("call-1", "bash", ["command": "ls"])])],
            docs: ["pi.live": [.delete([.key("generation")])]]
        )))
        // The committed thinking keeps the live row's id.
        #expect(await harness.waitForCommitted(["1", "2-think-0", "call-1"]))
        #expect(reducer.items.map(\.id) == ["1", "pi.live-0-think-0", "call-1"])
        #expect(reducer.timelineItemID(for: "2-think-0") == "pi.live-0-think-0")

        // Running output goes onto the committed call row.
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [.set([.key("tools")], [
            ["callId": "call-1", "name": "bash", "status": "running", "output": "README.md\n"],
        ])]])))
        #expect(await waitForMainActorCondition { reducer.toolOutput(for: "call-1") == "README.md\n" })

        // The result lands with the slot done in the same frame: committed output, once.
        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.toolResult(3, callId: "call-1", output: "README.md\nsrc\n")],
            docs: ["pi.live": [.set([.key("tools"), .index(0), .key("status")], "done")]]
        )))
        #expect(await waitForMainActorCondition { harness.isDone("call-1") == true })
        #expect(reducer.toolOutput(for: "call-1") == "README.md\nsrc\n")
        // The result restates its call's presentation, so that frame rebuilt; the landed
        // thinking row keeps its id through it.
        #expect(reducer.items.map(\.id) == ["1", "pi.live-0-think-0", "call-1"])

        // The final answer streams, then lands with the run ending.
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [
            .set([.key("generation")], ["attempt": 1, "message": ["role": "assistant", "content": [Wire.text("Two files.")], "timestamp": 1_791_650_003_000]]),
        ]])))
        #expect(await harness.waitForRows(["1", "pi.live-0-think-0", "call-1", "pi.live-1-text-0"]))
        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.assistant(4, [Wire.text("Two files.")])],
            docs: ["pi.live": [.delete([.key("run")]), .delete([.key("generation")]), .delete([.key("tools")])]]
        )))
        #expect(await harness.waitForCommitted(["1", "2-think-0", "call-1", "result-3", "4-text-0"]))
        #expect(reducer.items.map(\.id) == ["1", "pi.live-0-think-0", "call-1", "pi.live-1-text-0"])
        #expect(reducer.streamingAssistantID == nil)
        #expect(harness.manager.reducer.items.filter {
            if case .assistantMessage(_, "Two files.", _) = $0 { true } else { false }
        }.count == 1)
        await harness.finish()
    }

    @Test func classicTimelineEventsAreIgnoredWhileTheirOtherEffectsApply() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [:])))
        #expect(await harness.waitForRows(["1"]))

        harness.yield(.agentStart)
        harness.yield(.textDelta(delta: "classic text"))
        harness.yield(.toolStart(tool: "bash", args: [:], toolCallId: "classic-call", callSegments: nil))
        harness.yield(.messageEnd(role: "user", content: "classic user"))
        var busy = harness.session
        busy.status = .busy
        harness.yield(.state(session: busy))

        #expect(await waitForMainActorCondition { harness.store.session(id: harness.sessionId)?.status == .busy })
        harness.manager.coalescer.flushNow()
        #expect(harness.manager.reducer.items.map(\.id) == ["1"])
        await harness.finish()
    }

    @Test func olderPagePrependsThroughTheReplica() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: true, entries: [
            Wire.user(10, "newer"), Wire.assistant(11, [Wire.text("reply")]),
        ], docs: [:])))
        #expect(await harness.waitForRows(["10", "11-text-0"]))
        #expect(harness.manager.hasOlderTracePage)

        let load = Task { @MainActor in await harness.manager.loadOlderTracePage() }
        #expect(await waitForMainActorCondition { harness.olderRequests.count == 1 })
        let older = try #require(harness.olderRequests.first)
        #expect(older.beforeEntryId == 10)
        harness.frame(.older(.init(conversationId: 7, entries: [Wire.user(8, "old"), Wire.assistant(9, [Wire.text("old reply")])], hasOlder: false)))
        harness.yield(.commandResult(command: "older", requestId: older.requestId, success: true, data: nil, error: nil))

        #expect(await load.value)
        #expect(harness.manager.reducer.items.map(\.id) == ["8", "9-text-0", "10", "11-text-0"])
        #expect(!harness.manager.hasOlderTracePage)
        await harness.finish()
    }

    /// Every frame one client received for a real Harness conversation
    /// (`protocol/conversation-stream-golden.json`), through the runtime: streamed answers
    /// show as live rows, every landing leaves no duplicate, and the end state is the trace.
    @Test func goldenServerStreamEndsAsTheServerTrace() async throws {
        struct Golden: Decodable {
            let frames: [ConversationStreamServerMessage]
            let trace: [TraceEvent]
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/conversation-stream-golden.json")
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer

        var sawLiveRow = false
        for (index, frame) in golden.frames.enumerated() {
            // A marker after each frame: once it applies, the frame has been handled.
            var marker = harness.session
            marker.name = "frame \(index)"
            harness.frame(frame)
            harness.yield(.state(session: marker))
            #expect(await waitForMainActorCondition { harness.store.session(id: harness.sessionId)?.name == marker.name })
            let ids = reducer.items.map(\.id)
            #expect(Set(ids).count == ids.count, "duplicate rows: \(ids)")
            sawLiveRow = sawLiveRow || ids.contains { $0.hasPrefix("pi.live-") }
        }

        #expect(sawLiveRow)
        #expect(reducer.traceEventsForCache() == golden.trace)
        let expected = TimelineReducer()
        expected.loadSession(golden.trace)
        // The same rows; a landed answer keeps the id of the live row it landed in.
        #expect(reducer.items == expected.items.map { $0.replacingID(reducer.timelineItemID(for: $0.id)) })
        #expect(reducer.items.map(\.id) != expected.items.map(\.id))
        #expect(reducer.streamingAssistantID == nil)
        await harness.finish()
    }

    /// Each socket gets its own fresh-attach retry: a retry left unanswered by a dropped
    /// socket must not turn the next socket's first failure into a fatal one.
    @Test func attachRetryBudgetResetsForEachSocket() async throws {
        let harness = Harness()
        await harness.connect()
        let first = try await harness.attach(1)
        harness.yield(.commandResult(command: "attach", requestId: first.requestId, success: false, data: nil, error: "busy"))
        _ = try await harness.attach(2)

        // The socket drops and recovers before the fresh retry is answered.
        harness.yield(.connected(session: harness.session))
        let resumed = try await harness.attach(3)
        harness.yield(.commandResult(command: "attach", requestId: resumed.requestId, success: false, data: nil, error: "busy"))

        let retry = try await harness.attach(4)
        #expect(retry.afterEntryId == nil)
        #expect(harness.manager.entryState == .streaming)
        #expect(!harness.manager.reducer.items.contains { if case .error = $0 { true } else { false } })
        await harness.finish()
    }

    /// Rows only classic frames carry (a worktree rebind notice, a non-fatal prompt error,
    /// a cache miss, a session that ended) still show while the replica owns the timeline.
    @Test func classicOnlyRowsStillShowForAnAttachedSession() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [:])))
        #expect(await harness.waitForRows(["1"]))

        // A notice restating a committed card (`entry:<id>`) is not one of them.
        harness.yield(.notice(id: "entry:1", message: "Job finished"))
        harness.yield(.notice(id: "rebind", message: "Resuming on Main checkout. The worktree is gone."))
        harness.yield(.error(message: "Could not answer the extension", code: nil, fatal: false))
        harness.yield(.cacheMiss(id: "miss", message: "Prompt cache missed"))
        harness.yield(.sessionEnded(reason: "store could not reattach"))

        let reducer = harness.manager.reducer
        #expect(await waitForMainActorCondition {
            harness.manager.coalescer.flushNow()
            return reducer.items.count == 5
        })
        #expect(reducer.items.contains { if case .notice("rebind", _) = $0 { true } else { false } })
        #expect(reducer.items.contains { if case .error(_, "Could not answer the extension") = $0 { true } else { false } })
        #expect(reducer.items.contains { if case .cacheMiss("miss", _) = $0 { true } else { false } })
        #expect(reducer.items.contains {
            if case .systemEvent(_, let message) = $0 { message.contains("store could not reattach") } else { false }
        })
        await harness.finish()
    }

    /// The server sends the worktree rebind notice on connect, before the snapshot that
    /// rebuilds the timeline. Classic-only rows survive rebuilds in place; a run failure's
    /// error row gives way to the failure card committed with the same text.
    @Test func classicOnlyRowsSurviveRebuildsAndFailureCardsReplaceErrors() async throws {
        let harness = Harness()
        let reducer = harness.manager.reducer
        await harness.connect()
        _ = try await harness.attach(1)
        let rebind = "worktree-rebind:\(harness.sessionId)"
        harness.yield(.notice(id: rebind, message: "Resuming on Main checkout. The worktree is gone."))
        #expect(await waitForMainActorCondition {
            harness.manager.coalescer.flushNow()
            return reducer.items.map(\.id) == [rebind]
        })

        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [:])))
        #expect(await harness.waitForRows(["1", rebind]))

        harness.yield(.error(message: "Model overloaded", code: nil, fatal: false))
        #expect(await waitForMainActorCondition {
            harness.manager.coalescer.flushNow()
            return reducer.items.count == 3
        })
        let errorID = try #require(reducer.items.last?.id)
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.assistant(2, [Wire.text("Partial.")])])))
        #expect(await harness.waitForRows(["1", rebind, errorID, "2-text-0"]))

        // A snapshot restating an entry rebuilds; the rows stay after the rows they followed.
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "go"), Wire.assistant(2, [Wire.text("Partial, restated.")]),
        ], docs: [:])))
        #expect(await waitForMainActorCondition { harness.assistantText("2-text-0") == "Partial, restated." })
        #expect(!reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.map(\.id) == ["1", rebind, errorID, "2-text-0"])

        let failure = ConversationEntryView(
            id: 3, kind: "oppi.failure",
            card: .init(kind: "custom", title: "Run failed", body: "Model overloaded", accent: "error", at: Wire.at)
        )
        harness.frame(.update(.init(conversationId: 7, entries: [failure])))
        #expect(await harness.waitForRows(["1", rebind, "2-text-0", "3"]))
        await harness.finish()
    }

    /// Each committed user entry takes the oldest pending prompt, even when the server
    /// expanded it (`/skill:` prompts). Agent messages and input cards take none.
    @Test func committedUserEntriesTakePendingPromptsInOrder() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "first")], docs: [:])))
        #expect(await harness.waitForRows(["1"]))

        let skill = reducer.appendUserMessage("/skill:review check this")
        let followUp = reducer.appendUserMessage("then summarize")
        var agentMessage = Wire.user(2, "[from Review]\n\nhi")
        agentMessage.origin = MessageOrigin(kind: "session", sessionId: "child", name: "Review", intent: "report")
        agentMessage.textOffset = 14
        let inputCard = ConversationEntryView(
            id: 3, kind: "pi.user",
            card: .init(kind: "custom", title: "Job finished", at: Wire.at), inputCard: true
        )
        harness.frame(.update(.init(conversationId: 7, entries: [agentMessage, inputCard])))
        #expect(await harness.waitForRows(["1", skill, followUp, "2", "3"]))

        let expanded = "<skill name=\"review\" location=\"/home/me/.pi/skills/review/SKILL.md\">\nReview carefully.\n</skill>\n\ncheck this"
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(4, expanded)])))
        #expect(await harness.waitForRows(["1", followUp, "2", "3", "4"]))

        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(5, "then summarize, please")])))
        #expect(await harness.waitForRows(["1", "2", "3", "4", "5"]))
        await harness.finish()
    }

    /// The landing writes the committed answer into the live rows and keeps their ids, so
    /// the cells are not replaced. A later rebuild keeps those ids, once each.
    @Test func landingKeepsLiveRowIdentityAndRebuildsConverge() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [
            "pi.live": Wire.live(content: [Wire.thinking("plan"), Wire.text("Hel")]),
        ])))
        #expect(await waitForMainActorCondition { reducer.items.count == 3 })
        let liveIDs = reducer.items.suffix(2).map(\.id)

        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.assistant(2, [Wire.thinking("plan"), Wire.text("Hello")])],
            docs: ["pi.live": [.delete([.key("run")]), .delete([.key("generation")])]]
        )))
        #expect(await waitForMainActorCondition { harness.assistantText(liveIDs[1]) == "Hello" })
        #expect(reducer.items.map(\.id) == ["1"] + liveIDs)
        #expect(reducer.items.contains { if case .thinking(liveIDs[0], "plan", _, true) = $0 { true } else { false } })
        #expect(reducer.traceEventsForCache().map(\.id) == ["1", "2-think-0", "2-text-1"])
        #expect(await harness.manager.loadTracePageAround(entryId: "2-text-1"))

        // The next answer streams in rows of its own.
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [.replace(Wire.live(text: "Again"))]])))
        #expect(await waitForMainActorCondition { reducer.items.count == 4 })
        let secondLive = try #require(reducer.items.last?.id)
        #expect(!liveIDs.contains(secondLive))
        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.assistant(3, [Wire.text("Again")])],
            docs: ["pi.live": [.delete([.key("run")]), .delete([.key("generation")])]]
        )))
        #expect(await harness.waitForCommitted(["1", "2-think-0", "2-text-1", "3-text-0"]))
        #expect(reducer.items.map(\.id) == ["1"] + liveIDs + [secondLive])

        // The cache holds committed ids and loads to the same rows a rebuild gives.
        let cached = TimelineReducer()
        cached.loadSession(reducer.traceEventsForCache())
        #expect(cached.items.map(\.id) == ["1", "2-think-0", "2-text-1", "3-text-0"])

        // A snapshot that changes history rebuilds; the landed rows keep their ids, once each.
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: true, entries: [
            Wire.assistant(2, [Wire.thinking("plan"), Wire.text("Hello")]), Wire.assistant(3, [Wire.text("Again")]),
        ], docs: [:])))
        #expect(await harness.waitForCommitted(["2-think-0", "2-text-1", "3-text-0"]))
        #expect(reducer.items.map(\.id) == liveIDs + [secondLive])
        #expect(harness.assistantText(liveIDs[1]) == "Hello")
        #expect(harness.assistantText(secondLive) == "Again")
        await harness.finish()
    }

    @Test func committedPromptReplacesTheOptimisticRow() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "first")], docs: [:])))
        #expect(await harness.waitForRows(["1"]))

        let optimistic = reducer.appendUserMessage("second")
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(2, "second")])))
        #expect(await harness.waitForRows(["1", "2"]))
        #expect(!reducer.items.contains { $0.id == optimistic })
        #expect(reducer._lastLoadWasIncrementalForTesting)
        await harness.finish()
    }
}

// MARK: - Harness

@MainActor
private final class Harness {
    let sessionId = "durable-\(UUID().uuidString)"
    let manager: ChatSessionManager
    let streams = ScriptedStreamFactory()
    let connection = ServerConnection()
    /// Shared store updates land in the connection's store.
    var store: SessionStore { connection.sessionStore }
    let session: Session
    private(set) var sent: [ClientMessage] = []
    private var connectTask: Task<Void, Never>?

    init(engine: SessionEngine = .durable) {
        manager = ChatSessionManager(sessionId: sessionId)
        var session = makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)
        session.engine = engine
        self.session = session
        manager._streamSessionForTesting = { [streams] _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }
        connection.setSplitStreamCapabilitiesForTesting(conversationStream: true)
        connection._sendMessageForTesting = { [weak self] message in self?.sent.append(message) }
        store.upsert(session)
    }

    var attaches: [ConversationStreamAttach] {
        sent.compactMap { if case .conversationAttach(let attach) = $0 { attach } else { nil } }
    }

    var olderRequests: [ConversationStreamOlderRequest] {
        sent.compactMap { if case .conversationOlder(let older) = $0 { older } else { nil } }
    }

    func connect() async {
        connectTask = Task { @MainActor [manager, connection, store] in
            await manager.connect(connection: connection, sessionStore: store)
        }
        _ = await streams.waitForCreated(1)
        yield(.connected(session: session))
        _ = await waitForMainActorCondition { self.manager.entryState == .streaming }
    }

    func attach(_ count: Int) async throws -> ConversationStreamAttach {
        #expect(await waitForMainActorCondition { self.attaches.count >= count })
        return try #require(attaches.count >= count ? attaches[count - 1] : nil)
    }

    func yield(_ message: ServerMessage) {
        streams.yield(index: 0, message: message)
    }

    func frame(_ frame: ConversationStreamServerMessage) {
        yield(.conversationStream(frame))
    }

    /// The committed events loaded: unlike row ids, these change at a landing.
    func waitForCommitted(_ ids: [String]) async -> Bool {
        await waitForMainActorCondition { self.manager.reducer.traceEventsForCache().map(\.id) == ids }
    }

    func waitForRows(_ ids: [String]) async -> Bool {
        await waitForMainActorCondition { self.manager.reducer.items.map(\.id) == ids }
    }

    func assistantText(_ id: String) -> String? {
        manager.reducer.items.lazy.compactMap { item -> String? in
            if case .assistantMessage(id, let text, _) = item { text } else { nil }
        }.first
    }

    func isDone(_ id: String) -> Bool? {
        manager.reducer.items.lazy.compactMap { item -> Bool? in
            if case .toolCall(id, _, _, _, _, _, let isDone) = item { isDone } else { nil }
        }.first
    }

    func finish() async {
        streams.finish(index: 0)
        await connectTask?.value
        manager.cleanup()
    }
}

/// Conversation stream entries and `pi.live` documents.
enum Wire {
    static let at: Double = 1_791_650_000_000

    static func user(_ id: Int, _ text: String) -> ConversationEntryView {
        ConversationEntryView(id: id, kind: "pi.user", model: [
            ["role": "user", "content": .string(text), "timestamp": .number(at + Double(id) * 1000)],
        ])
    }

    static func assistant(_ id: Int, _ content: [JSONValue]) -> ConversationEntryView {
        ConversationEntryView(id: id, kind: "pi.assistant", model: [
            ["role": "assistant", "content": .array(content), "stopReason": "stop", "timestamp": .number(at + Double(id) * 1000)],
        ])
    }

    static func toolResult(_ id: Int, callId: String, output: String) -> ConversationEntryView {
        ConversationEntryView(
            id: id,
            kind: "pi.tool-result",
            model: [[
                "role": "toolResult", "toolCallId": .string(callId), "toolName": "bash",
                "content": [["type": "text", "text": .string(output)]], "isError": false,
                "timestamp": .number(at + Double(id) * 1000),
            ]],
            toolResult: .init(outputPresentation: .init(kind: "terminal"))
        )
    }

    static func text(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
    static func thinking(_ text: String) -> JSONValue { ["type": "thinking", "thinking": .string(text)] }
    static func toolCall(_ id: String, _ name: String, _ args: [String: JSONValue]) -> JSONValue {
        ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": .object(args)]
    }

    /// `pi.live` for a running answer.
    static func live(text: String) -> JSONValue { live(content: [Self.text(text)]) }

    static func live(content: [JSONValue]) -> JSONValue {
        [
            "run": ["taskId": 14, "inputs": [1]],
            "generation": ["attempt": 1, "message": ["role": "assistant", "content": .array(content), "timestamp": .number(at)]],
        ]
    }
}
