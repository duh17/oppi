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

    @Test func liveRowsStayLiveUntilTheirAnswerLands() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        func thinkingIsDone(_ id: String) -> Bool? {
            reducer.items.lazy.compactMap { item -> Bool? in
                if case .thinking(id, _, _, let isDone) = item { isDone } else { nil }
            }.first
        }
        // Providers open a text block on whitespace while the thinking before it still
        // grows: the empty block makes no row and must not end the thinking.
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [
            "pi.live": Wire.live(content: [Wire.thinking("reading"), Wire.text("\n\n")]),
        ])))
        #expect(await harness.waitForRows(["1", "pi.live-0-think-0"]))
        #expect(thinkingIsDone("pi.live-0-think-0") == false)
        #expect(reducer.liveRowIDs == ["pi.live-0-think-0"])

        // Text follows: the thinking's spinner stops, but the live tail can still rewrite
        // it until the answer lands, so its row stays live.
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [
            .replace(Wire.live(content: [Wire.thinking("reading the test"), Wire.text("Fixed.")])),
        ]])))
        #expect(await harness.waitForRows(["1", "pi.live-0-think-0", "pi.live-0-text-1"]))
        #expect(thinkingIsDone("pi.live-0-think-0") == true)
        #expect(reducer.liveRowIDs == ["pi.live-0-think-0", "pi.live-0-text-1"])

        // The answer lands with the run ending: its rows keep their ids and nothing is live.
        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.assistant(2, [Wire.thinking("reading the test"), Wire.text("Fixed.")])],
            docs: ["pi.live": [.delete([.key("run")]), .delete([.key("generation")])]]
        )))
        #expect(await harness.waitForCommitted(["1", "2-think-0", "2-text-1"]))
        #expect(reducer.items.map(\.id) == ["1", "pi.live-0-think-0", "pi.live-0-text-1"])
        #expect(reducer.liveRowIDs.isEmpty)
        await harness.finish()
    }

    @Test func whitespaceOnlyThinkingNeverBecomesARow() async throws {
        // Local GLM models emit a "\n" thinking block before every tool call.
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [
            "pi.live": Wire.live(content: [Wire.thinking("\n"), Wire.toolCall("call-1", "bash", ["command": "ls"])]),
        ])))
        #expect(await harness.waitForRows(["1", "call-1"]))

        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.assistant(2, [Wire.thinking("\n"), Wire.toolCall("call-1", "bash", ["command": "ls"])])],
            docs: ["pi.live": [.delete([.key("generation")])]]
        )))
        // The trace keeps the block; only the timeline skips it.
        #expect(await harness.waitForCommitted(["1", "2-think-0", "call-1"]))
        #expect(reducer.items.map(\.id) == ["1", "call-1"])
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

    /// Classic-only rows that arrive while the scene is paused show once it resumes, after
    /// the resync from the replica, instead of being dropped with the paused frames.
    @Test func classicOnlyRowsWhilePausedShowAfterResume() async throws {
        let harness = Harness()
        let reducer = harness.manager.reducer
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [:])))
        #expect(await harness.waitForRows(["1"]))

        harness.manager.coalescer.pause()
        harness.yield(.notice(id: "rebind", message: "Resuming on Main checkout."))
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.assistant(2, [Wire.text("Done.")])])))
        await harness.sync()
        #expect(reducer.items.map(\.id) == ["1"])

        #expect(harness.manager.coalescer.resume())
        harness.manager.reloadTimelineAfterPresentationOverflow()
        #expect(reducer.items.map(\.id) == ["1", "2-text-0", "rebind"])
        await harness.finish()
    }

    /// The busy indicator, stop button, and queue read the replica: `pi.live.run` and the
    /// server's `pi.inbox` queue view, not the session status or `queue_state`. A sent
    /// follow-up shows at once and gives way to the replica's item without a duplicate; once
    /// the socket ends, the run state no longer counts.
    @Test func busyStateAndQueueComeFromTheReplica() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let queues = harness.connection.messageQueueStore
        let sessionId = harness.sessionId
        func queue() -> (steering: [String], followUp: [String]) {
            let state = queues.queue(for: sessionId)
            return (state.steering.map(\.message), state.followUp.map(\.message))
        }

        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [
            "pi.live": Wire.live(text: "Working"),
            "pi.inbox": Wire.queue(steering: [("31", "look here")]),
        ])))
        #expect(await waitForMainActorCondition { harness.manager.conversationStream?.isRunning == true })
        #expect(queue().steering == ["look here"])
        // The session row still says ready; the replica decides.
        #expect(harness.store.session(id: sessionId)?.status == .ready)

        // A `get_queue` answer does not replace the replica's queue.
        harness.yield(.queueState(queue: MessageQueueState(version: 99, steering: [], followUp: [])))
        await harness.sync()
        #expect(queue().steering == ["look here"])

        // A follow-up shows before the server has it, through frames that do not have it yet.
        queues.enqueueOptimisticItem(for: sessionId, kind: .followUp, message: "then this", attachments: nil, id: "turn-1")
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [.append([.key("generation"), .key("message"), .key("content"), .index(0), .key("text")], "…")]])))
        await harness.sync()
        #expect(queue().followUp == ["then this"])
        // Acknowledged: the next frame shows the input as the server has it, once.
        queues.optimisticItemDelivered("turn-1", kind: .followUp, message: "then this", for: sessionId)
        harness.frame(.update(.init(conversationId: 7, docs: [
            "pi.inbox": [.replace(Wire.queue(steering: [("31", "look here")], followUp: [("32", "then this")]))],
        ])))
        #expect(await waitForMainActorCondition { queues.queue(for: sessionId).followUp.map(\.id) == ["32"] })

        // The run ends and both inputs start.
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(2, "look here"), Wire.user(3, "then this")], docs: [
            "pi.live": [.replace([:])],
            "pi.inbox": [.replace(Wire.queue())],
        ])))
        #expect(await waitForMainActorCondition { harness.manager.conversationStream?.isRunning == false })
        #expect(queue().steering.isEmpty && queue().followUp.isEmpty)

        await harness.finish()
        #expect(harness.manager.conversationStream?.isRunning == nil)
        #expect(!queues.isConversationQueue(sessionId))
    }

    /// Opening a busy chat: the queue sync's `queue_state` fills the store before the replica
    /// takes over. The snapshot's `pi.inbox` replaces those items instead of showing each twice.
    @Test func replicaQueueReplacesTheQueueStateItShowedFirst() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let queues = harness.connection.messageQueueStore
        let sessionId = harness.sessionId
        let item = MessageQueueItem(id: "31", message: "look here", createdAt: 0)
        harness.yield(.queueState(queue: MessageQueueState(version: 3, steering: [item], followUp: [])))
        await harness.sync()
        #expect(queues.queue(for: sessionId).steering.map(\.id) == ["31"])

        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [
            "pi.live": Wire.live(text: "Working"),
            "pi.inbox": Wire.queue(steering: [("31", "look here")]),
        ])))
        #expect(await waitForMainActorCondition { queues.isConversationQueue(sessionId) })
        #expect(queues.queue(for: sessionId).steering.map(\.id) == ["31"])
        await harness.finish()
    }

    /// A socket replaced in place (no stream end, a second `connected`): the old run state does
    /// not drive the stop button; the resumed replica does once its first frame lands.
    @Test func runStateWaitsForTheResumedSocket() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "go")], docs: [
            "pi.live": Wire.live(text: "Working"),
        ])))
        #expect(await waitForMainActorCondition { harness.manager.conversationStream?.isRunning == true })

        harness.yield(.connected(session: harness.session))
        let resume = try await harness.attach(2)
        #expect(resume.afterEntryId == 1)
        #expect(harness.manager.conversationStream?.isRunning == nil)

        harness.frame(.update(.init(conversationId: 7, entries: [], docs: ["pi.live": [.replace([:])]])))
        #expect(await waitForMainActorCondition { harness.manager.conversationStream?.isRunning == false })
        await harness.finish()
    }

    /// A committed tool result that changes a setting applies it when it lands, as classic
    /// `tool_end` did; the same result in a snapshot is history and applies nothing.
    @Test func landedSettingResultAppliesAndHistoryDoesNot() async throws {
        let harness = Harness()
        defer { AppPreferences.Voice.setSessionReplyMode(nil, for: harness.sessionId) }
        await harness.connect()
        _ = try await harness.attach(1)
        func voiceResult(_ id: Int, mode: String) -> ConversationEntryView {
            var entry = Wire.toolResult(id, callId: "voice-\(id)", output: "ok")
            entry.model = [[
                "role": "toolResult", "toolCallId": .string("voice-\(id)"), "toolName": "voice_reply_mode",
                "content": [["type": "text", "text": "ok"]], "isError": false,
                "details": ["kind": "voice_reply_mode", "mode": .string(mode)],
            ]]
            entry.toolResult = .init(outputPresentation: .init(kind: "structured", settingEffect: "voiceReplyMode"))
            return entry
        }

        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [voiceResult(1, mode: "manual")], docs: [:])))
        await harness.sync()
        #expect(AppPreferences.Voice.sessionReplyMode(for: harness.sessionId) == nil)

        harness.frame(.update(.init(conversationId: 7, entries: [voiceResult(2, mode: "autoplay")])))
        await harness.sync()
        #expect(AppPreferences.Voice.sessionReplyMode(for: harness.sessionId) == .autoplay)
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

        // A user entry with other text (typed on another device, or in the terminal) does
        // not take this device's unsent prompt; the prompt's own entry does.
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(5, "from the terminal")])))
        #expect(await harness.waitForRows(["1", followUp, "2", "3", "4", "5"]))
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(6, "then summarize")])))
        #expect(await harness.waitForRows(["1", "2", "3", "4", "5", "6"]))
        await harness.finish()
    }

    /// Entries that only become visible are not new turns: an older page, or a rebuild after
    /// a memory warning, never takes a pending prompt, even one with the same text.
    @Test func olderHistoryNeverTakesAPendingPrompt() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: true, entries: [
            Wire.user(10, "newer"), Wire.assistant(11, [Wire.text("reply")]),
        ], docs: [:])))
        #expect(await harness.waitForRows(["10", "11-text-0"]))
        let pending = reducer.appendUserMessage("again")

        let load = Task { @MainActor in await harness.manager.loadOlderTracePage() }
        #expect(await waitForMainActorCondition { harness.olderRequests.count == 1 })
        let older = try #require(harness.olderRequests.first)
        harness.frame(.older(.init(conversationId: 7, entries: [Wire.user(8, "again")], hasOlder: false)))
        harness.yield(.commandResult(command: "older", requestId: older.requestId, success: true, data: nil, error: nil))
        #expect(await load.value)
        #expect(reducer.items.map(\.id) == ["8", "10", "11-text-0", pending])

        // A memory warning forgets the loaded trace; the next rebuild still keeps the prompt.
        _ = reducer.handleMemoryWarning()
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.assistant(11, [Wire.text("reply")])])))
        #expect(await waitForMainActorCondition { reducer.items.map(\.id) == ["8", "10", "11-text-0", pending] })

        // Its own entry lands and takes it.
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(12, "again")])))
        #expect(await harness.waitForRows(["8", "10", "11-text-0", "12"]))
        await harness.finish()
    }

    /// Only the answer that just landed takes the live rows: an older page loaded while an
    /// answer streams, or an earlier answer committed in the same frame, keeps its own ids.
    @Test func onlyTheNewestLandedAnswerTakesTheLiveRows() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        let reducer = harness.manager.reducer
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: true, entries: [Wire.user(10, "go")], docs: [
            "pi.live": Wire.live(content: [Wire.text("Hel")]),
        ])))
        #expect(await waitForMainActorCondition { reducer.items.count == 2 })
        let liveID = try #require(reducer.items.last?.id)

        let load = Task { @MainActor in await harness.manager.loadOlderTracePage() }
        #expect(await waitForMainActorCondition { harness.olderRequests.count == 1 })
        let older = try #require(harness.olderRequests.first)
        harness.frame(.older(.init(conversationId: 7, entries: [Wire.user(8, "old"), Wire.assistant(9, [Wire.text("old reply")])], hasOlder: false)))
        harness.yield(.commandResult(command: "older", requestId: older.requestId, success: true, data: nil, error: nil))
        #expect(await load.value)
        #expect(reducer.items.map(\.id) == ["8", "9-text-0", "10", liveID])

        // Two answers commit in one frame: the newer is the one that was live.
        harness.frame(.update(.init(
            conversationId: 7,
            entries: [Wire.assistant(11, [Wire.text("step")]), Wire.assistant(12, [Wire.text("Hello")])],
            docs: ["pi.live": [.delete([.key("run")]), .delete([.key("generation")])]]
        )))
        #expect(await waitForMainActorCondition { harness.assistantText(liveID) == "Hello" })
        #expect(reducer.items.map(\.id) == ["8", "9-text-0", "10", "11-text-0", liveID])
        #expect(reducer.timelineItemID(for: "9-text-0") == "9-text-0")
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
        #expect(await harness.manager.loadOlderHistory(through: "2-text-1"))

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

    /// A subagent tool row's details name a child conversation; its live tail streams on the
    /// parent's socket and shows under that row, apart from the parent's own replica.
    @Test func followsASubagentsLiveTailUnderItsToolRowAcrossAReconnect() async throws {
        let harness = Harness(liveTails: true)
        await harness.connect()
        let own = try await harness.attach(1)
        harness.yield(.commandResult(command: "attach", requestId: own.requestId, success: true, data: nil, error: nil))
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "Delegate"),
            Wire.assistant(2, [Wire.toolCall("call-s", "subagent", ["action": "spawn"])]),
            Wire.toolResult(3, callId: "call-s", output: "Started kid", details: Wire.child(9, "child-session")),
        ], docs: [:])))
        #expect(await harness.waitForRows(["1", "call-s"]))
        let tailAttach = try await harness.attach(2)
        #expect(tailAttach.conversationId == 9 && tailAttach.mode == .live && tailAttach.afterEntryId == nil)

        harness.frame(.snapshot(.init(conversationId: 9, head: 0, hasOlder: false, entries: [], docs: [
            "pi.live": Wire.live(content: [Wire.text("Reading files\nfound two")]),
        ])))
        #expect(await waitForMainActorCondition {
            harness.manager.childTails["call-s"]?.lines.map(\.text) == ["Reading files", "found two"]
        })
        #expect(harness.manager.childTails["call-s"]?.reference.sessionId == "child-session")
        harness.frame(.update(.init(conversationId: 9, docs: ["pi.live": [
            .append([.key("generation"), .key("message"), .key("content"), .index(0), .key("text")], "\nand a third"),
        ]])))
        #expect(await waitForMainActorCondition {
            harness.manager.childTails["call-s"]?.lines.last?.text == "and a third"
        })
        // The child's frames leave the parent's replica and rows alone.
        #expect(harness.manager.conversationStream?.replica.conversationId == 7)
        #expect(harness.manager.reducer.items.map(\.id) == ["1", "call-s"])

        // A reconnect resumes the parent and attaches the child again, which snapshots.
        harness.yield(.connected(session: harness.session))
        let resumed = try await harness.attach(3)
        #expect(resumed.conversationId == 7 && resumed.afterEntryId == 3)
        let again = try await harness.attach(4)
        #expect(again.conversationId == 9 && again.mode == .live)
        harness.frame(.snapshot(.init(conversationId: 9, head: 0, hasOlder: false, entries: [], docs: [
            "pi.live": Wire.live(content: [Wire.text("after the reconnect")]),
        ])))
        #expect(await waitForMainActorCondition {
            harness.manager.childTails["call-s"]?.lines.map(\.text) == ["after the reconnect"]
        })

        // Idle: nothing to show.
        harness.frame(.update(.init(conversationId: 9, docs: ["pi.live": [.delete([.key("run")]), .delete([.key("generation")])]])))
        #expect(await waitForMainActorCondition { harness.manager.childTails.isEmpty })
        await harness.finish()
    }

    /// A busy child's live tail, and its queue, never drive the session's own busy state or
    /// queue. An in-place reconnect resets only the session's run state; its followed children
    /// keep their tails and attach again.
    @Test func childTailsNeverDriveTheSessionsRunStateOrQueue() async throws {
        let harness = Harness(liveTails: true)
        await harness.connect()
        let own = try await harness.attach(1)
        harness.yield(.commandResult(command: "attach", requestId: own.requestId, success: true, data: nil, error: nil))
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "Delegate"),
            Wire.assistant(2, [Wire.toolCall("call-s", "subagent", ["action": "spawn"])]),
            Wire.toolResult(3, callId: "call-s", output: "Started kid", details: Wire.child(9, "child-session")),
        ], docs: ["pi.inbox": Wire.queue()])))
        #expect(await harness.waitForRows(["1", "call-s"]))
        let tailAttach = try await harness.attach(2)
        #expect(tailAttach.conversationId == 9 && tailAttach.mode == .live)

        harness.frame(.snapshot(.init(conversationId: 9, head: 0, hasOlder: false, entries: [], docs: [
            "pi.live": Wire.live(content: [Wire.text("child working")]),
            "pi.inbox": Wire.queue(followUp: [("41", "child follow-up")]),
        ])))
        #expect(await waitForMainActorCondition { harness.manager.childTails["call-s"] != nil })
        #expect(harness.manager.conversationStream?.isRunning == false)
        #expect(harness.connection.messageQueueStore.queue(for: harness.sessionId).followUp.isEmpty)

        harness.yield(.connected(session: harness.session))
        let resumed = try await harness.attach(3)
        #expect(resumed.conversationId == 7)
        let again = try await harness.attach(4)
        #expect(again.conversationId == 9 && again.mode == .live)
        #expect(harness.manager.conversationStream?.isRunning == nil)
        #expect(harness.manager.childTails["call-s"] != nil)
        await harness.finish()
    }

    @Test func followsTheNewestChildrenAndKeepsTheSessionWhenATailIsRefused() async throws {
        let harness = Harness(liveTails: true)
        await harness.connect()
        _ = try await harness.attach(1)
        let max = ChatSessionManager.maxChildTails
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: (1 ... max + 1).map { index in
            Wire.toolResult(index, callId: "call-\(index)", output: "ok", details: Wire.child(100 + index, "child-\(index)"))
        }, docs: [:])))
        #expect(await waitForMainActorCondition { harness.attaches.count == 1 + max })
        let followed = harness.attaches.dropFirst().compactMap(\.conversationId)
        #expect(Set(followed) == Set((2 ... max + 1).map { 100 + $0 }))

        // A newer child: the oldest followed one is detached.
        harness.frame(.update(.init(conversationId: 7, entries: [
            Wire.toolResult(20, callId: "call-20", output: "ok", details: Wire.child(120, "child-20")),
        ])))
        #expect(await waitForMainActorCondition { harness.detaches.map(\.conversationId) == [102] })
        #expect(harness.attaches.last?.conversationId == 120)

        // A refused tail is tried once more, then dropped; the session's own stream goes on.
        let refused = try #require(harness.attaches.last)
        harness.yield(.commandResult(command: "attach", requestId: refused.requestId, success: false, data: nil, error: "not in this session's thread"))
        let count = harness.attaches.count + 1
        let retry = try await harness.attach(count)
        #expect(retry.conversationId == 120)
        harness.yield(.commandResult(command: "attach", requestId: retry.requestId, success: false, data: nil, error: "not in this session's thread"))
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(21, "still here")])))
        #expect(await waitForMainActorCondition { harness.manager.reducer.items.last?.id == "21" })
        #expect(harness.manager.entryState == .streaming)
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { harness.attaches.count == count })
        await harness.finish()
    }

    @Test func aServerWithoutLiveTailsGetsNoChildAttach() async throws {
        let harness = Harness()
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "Delegate"),
            Wire.assistant(2, [Wire.toolCall("call-s", "subagent", ["action": "spawn"])]),
            Wire.toolResult(3, callId: "call-s", output: "ok", details: Wire.child(9, "child-session")),
        ], docs: [:])))
        #expect(await harness.waitForRows(["1", "call-s"]))
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { harness.attaches.count == 1 })
        await harness.finish()
    }

    /// A v1 server's `attach` replaces the socket's only stream: reconnecting to one (a server
    /// rolled back under a running app) must not re-attach the children followed before.
    @Test func aReconnectToAServerWithoutLiveTailsStopsFollowingChildren() async throws {
        let harness = Harness(liveTails: true)
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(Self.parentWithChild)
        _ = try await harness.attach(2)
        harness.frame(.snapshot(.init(conversationId: 9, head: 0, hasOlder: false, entries: [], docs: [
            "pi.live": Wire.live(text: "busy"),
        ])))
        #expect(await waitForMainActorCondition { harness.manager.childTails["call-s"] != nil })

        harness.connection.setSplitStreamCapabilitiesForTesting(conversationStream: true, conversationStreamVersion: 1)
        harness.yield(.connected(session: harness.session))
        let resumed = try await harness.attach(3)
        #expect(resumed.conversationId == 7 && resumed.mode == nil)
        #expect(await waitForMainActorCondition { harness.manager.childTails.isEmpty })
        // Neither now nor on the session's next frames.
        harness.frame(.update(.init(conversationId: 7, entries: [Wire.user(4, "still here")])))
        #expect(await harness.waitForRows(["1", "call-s", "4"]))
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) { harness.attaches.count == 3 })
        await harness.finish()
    }

    /// A detached child's snapshot can still be in flight when the session's own replica was
    /// reset and waits for its snapshot: it must not become the session's replica.
    @Test func aDetachedChildsLateSnapshotNeverReplacesTheSessionsReplica() async throws {
        let harness = Harness(liveTails: true)
        await harness.connect()
        _ = try await harness.attach(1)
        harness.frame(Self.parentWithChild)
        _ = try await harness.attach(2)
        // The child drops out (its tool row is gone after a snapshot), and the session's replica
        // resets after a frame it cannot apply.
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "Delegate")], docs: [:])))
        #expect(await waitForMainActorCondition { harness.detaches.map(\.conversationId) == [9] })
        harness.frame(.update(.init(conversationId: 7, docs: ["pi.live": [.append([.key("generation")], "x")]])))
        let fresh = try await harness.attach(3)
        #expect(fresh.afterEntryId == nil && fresh.mode == nil)

        harness.frame(.snapshot(.init(conversationId: 9, head: 0, hasOlder: false, entries: [Wire.user(50, "child")], docs: [:])))
        #expect(await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            !harness.manager.reducer.items.contains { $0.id == "50" }
                && harness.manager.conversationStream?.replica.conversationId == nil
        })
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: [Wire.user(1, "Delegate"), Wire.user(2, "again")], docs: [:])))
        #expect(await harness.waitForRows(["1", "2"]))
        #expect(harness.manager.conversationStream?.replica.conversationId == 7)
        #expect(harness.attaches.count == 3)
        await harness.finish()
    }

    private static let parentWithChild = ConversationStreamServerMessage.snapshot(.init(
        conversationId: 7, head: 0, hasOlder: false, entries: [
            Wire.user(1, "Delegate"),
            Wire.assistant(2, [Wire.toolCall("call-s", "subagent", ["action": "spawn"])]),
            Wire.toolResult(3, callId: "call-s", output: "ok", details: Wire.child(9, "child-session")),
        ], docs: [:]
    ))

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

/// Main-thread work of following busy subagents: eight children each stream ten frames a second,
/// as the server's frame interval allows, for two seconds. Each publication of the tails
/// rebuilds the parent timeline's rows, so they must stay batched. Prints a `PERF` line.
@Suite("Subagent live tail cost")
@MainActor
struct ConversationChildTailPerfTests {
    @Test func eightStreamingChildrenPublishAtMostFourTimesASecond() async throws {
        let children = ChatSessionManager.maxChildTails
        let harness = Harness(liveTails: true)
        await harness.connect()
        _ = try await harness.attach(1)
        var entries: [ConversationEntryView] = []
        for index in 0..<children {
            let call = "call-\(index)"
            entries.append(Wire.assistant(index * 2 + 1, [Wire.toolCall(call, "subagent", ["action": "spawn"])]))
            entries.append(Wire.toolResult(index * 2 + 2, callId: call, output: "ok", details: Wire.child(100 + index, "child-\(index)")))
        }
        harness.frame(.snapshot(.init(conversationId: 7, head: 0, hasOlder: false, entries: entries, docs: [:])))
        #expect(await waitForMainActorCondition { harness.attaches.count == 1 + children })
        for index in 0..<children {
            harness.frame(.snapshot(.init(conversationId: 100 + index, head: 0, hasOlder: false, entries: [], docs: [
                "pi.live": Wire.live(text: "Starting"),
            ])))
        }
        #expect(await waitForMainActorCondition { harness.manager.childTails.count == children })

        let before = harness.manager._childTailPublicationsForTesting
        let rounds = 20
        let start = ContinuousClock.now
        for round in 1...rounds {
            for index in 0..<children {
                harness.frame(.update(.init(conversationId: 100 + index, docs: ["pi.live": [
                    .append([.key("generation"), .key("message"), .key("content"), .index(0), .key("text")], "\nline \(round)"),
                ]])))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await waitForMainActorCondition {
            harness.manager.childTails.values.allSatisfy { $0.lines.last?.text == "line \(rounds)" }
        })
        let elapsed = ContinuousClock.now - start
        let publications = harness.manager._childTailPublicationsForTesting - before
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(
            format: "PERF conversation-stream child tails: %d children, %d frames in %.2f s, %d publications (%.1f/s)",
            children, children * rounds, seconds, publications, Double(publications) / seconds
        ))
        // Unbatched, every one of the 160 frames would publish.
        #expect(publications >= 2)
        #expect(Double(publications) <= seconds * 4 + 2)
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

    init(engine: SessionEngine = .durable, liveTails: Bool = false) {
        manager = ChatSessionManager(sessionId: sessionId)
        var session = makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)
        session.engine = engine
        self.session = session
        manager._streamSessionForTesting = { [streams] _ in streams.makeStream() }
        manager._loadHistoryForTesting = { _, _ in nil }
        connection.setSplitStreamCapabilitiesForTesting(
            conversationStream: true,
            conversationStreamVersion: liveTails ? 2 : 1
        )
        connection._sendMessageForTesting = { [weak self] message in self?.sent.append(message) }
        store.upsert(session)
    }

    var attaches: [ConversationStreamAttach] {
        sent.compactMap { if case .conversationAttach(let attach) = $0 { attach } else { nil } }
    }

    var detaches: [ConversationStreamDetach] {
        sent.compactMap { if case .conversationDetach(let detach) = $0 { detach } else { nil } }
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

    /// Wait until every message yielded so far is handled: a marker state lands after them.
    func sync() async {
        var marker = session
        marker.name = "sync \(UUID().uuidString)"
        yield(.state(session: marker))
        _ = await waitForMainActorCondition { self.store.session(id: self.sessionId)?.name == marker.name }
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

    static func toolResult(_ id: Int, callId: String, output: String, details: JSONValue? = nil) -> ConversationEntryView {
        var message: [String: JSONValue] = [
            "role": "toolResult", "toolCallId": .string(callId), "toolName": "bash",
            "content": [["type": "text", "text": .string(output)]], "isError": false,
            "timestamp": .number(at + Double(id) * 1000),
        ]
        if let details { message["details"] = details }
        return ConversationEntryView(
            id: id,
            kind: "pi.tool-result",
            model: [.object(message)],
            toolResult: .init(outputPresentation: .init(kind: "terminal"))
        )
    }

    /// Tool details that name a child conversation, as `subagent`'s do.
    static func child(_ conversationId: Int, _ sessionId: String) -> JSONValue {
        ["name": "kid", "conversationId": .number(Double(conversationId)), "sessionId": .string(sessionId)]
    }

    static func text(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }
    static func thinking(_ text: String) -> JSONValue { ["type": "thinking", "thinking": .string(text)] }
    static func toolCall(_ id: String, _ name: String, _ args: [String: JSONValue]) -> JSONValue {
        ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": .object(args)]
    }

    /// The server's `pi.inbox` view: queue items by id and message.
    static func queue(steering: [(String, String)] = [], followUp: [(String, String)] = []) -> JSONValue {
        func items(_ list: [(String, String)]) -> JSONValue {
            .array(list.map { ["id": .string($0.0), "message": .string($0.1), "createdAt": 0] })
        }
        return ["steering": items(steering), "followUp": items(followUp)]
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
