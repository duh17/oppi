import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Load Session")
struct TimelineReducerLoadTests {

    // MARK: - Basic load

    @MainActor
    @Test func loadSessionUserAndAssistant() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 2)
        guard case .userMessage(_, let userText, _, _) = reducer.items[0] else {
            Issue.record("Expected userMessage")
            return
        }
        #expect(userText == "Hello")

        guard case .assistantMessage(_, let assistantText, _) = reducer.items[1] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(assistantText == "Hi there!")
    }

    @MainActor
    @Test func loadSessionToolCallAndResult() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "bash", args: ["command": .string("ls -la")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: "file1.txt\nfile2.txt",
                       toolCallId: "tc1", toolName: "bash", isError: false, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
        guard case .toolCall(_, let tool, _, let preview, let bytes, let isError, let isDone) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(tool == "bash")
        #expect(preview.contains("file1.txt"))
        #expect(bytes > 0)
        #expect(!isError)
        #expect(isDone)
        #expect(reducer.toolOutputStore.fullOutput(for: "tc1") == "file1.txt\nfile2.txt")
    }

    @MainActor
    @Test func loadSessionThinking() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "t1", type: .thinking, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil,
                       thinking: "Let me think about this carefully"),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
        guard case .thinking(_, let preview, let hasMore, let isDone) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(preview.contains("Let me think"))
        #expect(!hasMore)
        #expect(isDone)
    }

    @MainActor
    @Test func loadSessionLongThinkingKeepsFullPreview() {
        let reducer = TimelineReducer()
        let longThinking = String(repeating: "x", count: 600)
        let events = [
            TraceEvent(id: "t1", type: .thinking, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil,
                       thinking: longThinking),
        ]
        reducer.loadSession(events)

        guard case .thinking(_, let preview, let hasMore, _) = reducer.items[0] else {
            Issue.record("Expected thinking")
            return
        }
        #expect(hasMore)
        #expect(preview == longThinking)
    }

    @MainActor
    @Test func loadSessionSystemAndCompaction() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "s1", type: .system, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Session started", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "c1", type: .compaction, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 2)
        guard case .systemEvent(_, let msg1) = reducer.items[0] else {
            Issue.record("Expected systemEvent for system type")
            return
        }
        #expect(msg1 == "Session started")

        guard case .systemEvent(_, let msg2) = reducer.items[1] else {
            Issue.record("Expected systemEvent for compaction type")
            return
        }
        #expect(msg2 == "Context compacted")
    }

    @MainActor
    @Test func loadSessionCompactionPrefersTraceSummaryText() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "c1", type: .compaction, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Context compacted (12,345 tokens): ## Goal\n1. Keep calm",
                       tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
        guard case .systemEvent(_, let message) = reducer.items[0] else {
            Issue.record("Expected systemEvent for compaction type")
            return
        }
        #expect(message == "Context compacted (12,345 tokens): ## Goal\n1. Keep calm")
    }

    @MainActor
    @Test func loadSessionToolResultErrorFlag() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "bash", args: [:],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:01.000Z",
                       text: nil, tool: nil, args: nil, output: "error: command failed",
                       toolCallId: "tc1", toolName: "bash", isError: true, thinking: nil),
        ]
        reducer.loadSession(events)

        guard case .toolCall(_, _, _, _, _, let isError, _) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isError)
    }

    @MainActor
    @Test func loadSessionToolArgsStored() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:00.000Z",
                       text: nil, tool: "read", args: ["path": .string("/etc/hosts")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(events)

        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["path"] == .string("/etc/hosts"))
    }

    // MARK: - Incremental load

    @MainActor
    @Test func loadSessionUnchangedTraceUsesIncrementalNoOp() {
        let reducer = TimelineReducer()
        let events = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting)
        let baselineVersion = reducer.renderVersion
        let baselineItems = reducer.items

        reducer.loadSession(events)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.renderVersion == baselineVersion)
        #expect(reducer.items == baselineItems)
    }

    @MainActor
    @Test func loadSessionAppendedTraceUsesIncrementalAppend() {
        let reducer = TimelineReducer()
        let base = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(base)
        let baselineVersion = reducer.renderVersion

        let extended = base + [
            TraceEvent(id: "e3", type: .assistant, timestamp: "2025-01-01T00:00:02.000Z",
                       text: "Incremental tail", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(extended)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.renderVersion == baselineVersion + 1)
        #expect(reducer.items.count == 3)
        guard case .assistantMessage(_, let tailText, _) = reducer.items[2] else {
            Issue.record("Expected incremental assistant tail")
            return
        }
        #expect(tailText == "Incremental tail")
    }

    @MainActor
    @Test func loadSessionForcesFullRebuildAfterOutOfBandMutation() {
        let reducer = TimelineReducer()
        let base = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(base)
        reducer.appendSystemEvent("Local marker")

        let extended = base + [
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Server canonical", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]

        reducer.loadSession(extended)

        #expect(!reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 2)
        guard case .userMessage = reducer.items[0] else {
            Issue.record("Expected canonical user message at index 0")
            return
        }
        guard case .assistantMessage(_, let text, _) = reducer.items[1] else {
            Issue.record("Expected canonical assistant message at index 1")
            return
        }
        #expect(text == "Server canonical")
    }

    // MARK: - Incremental mode breakers

    @MainActor
    @Test func processBatchBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .textDelta(sessionId: "s1", delta: "live"),
            .agentEnd(sessionId: "s1"),
        ])

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "processBatch should break incremental mode")
    }

    @MainActor
    @Test func processSingleEventBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.process(.error(sessionId: "s1", message: "oops"))

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "process() should break incremental mode")
    }

    @MainActor
    @Test func appendUserMessageBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.appendUserMessage("optimistic send")

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "appendUserMessage should break incremental mode")
    }

    @MainActor
    @Test func removeItemBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        let id = reducer.appendUserMessage("will retract")
        reducer.removeItem(id: id)

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "removeItem should break incremental mode")
    }

    @MainActor
    @Test func appendAudioClipBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.appendAudioClip(title: "test", fileURL: URL(filePath: "/tmp/test.wav"))

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "appendAudioClip should break incremental mode")
    }

    @MainActor
    @Test func resolvePermissionBreaksIncrementalMode() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.resolvePermission(id: "p1", outcome: .allowed, tool: "bash", summary: "ls")

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "resolvePermission should break incremental mode")
    }

    // MARK: - Incremental edge cases

    @MainActor
    @Test func resetClearsIncrementalTrackingState() {
        let reducer = TimelineReducer()
        let events = makeBaseTrace()
        reducer.loadSession(events)

        reducer.loadSession(events)
        #expect(reducer._lastLoadWasIncrementalForTesting)

        reducer.reset()

        reducer.loadSession(events)
        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "reset should clear incremental tracking state")
    }

    @MainActor
    @Test func tracePrefixDivergenceForcesFullRebuild() {
        let reducer = TimelineReducer()
        let original = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(original)

        let rewritten = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2-rewritten", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Compacted response", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(rewritten)

        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "Divergent prefix should force full rebuild")
        #expect(reducer.items.count == 2)
        guard case .assistantMessage(_, let text, _) = reducer.items[1] else {
            Issue.record("Expected rewritten assistant message")
            return
        }
        #expect(text == "Compacted response")
    }

    @MainActor
    @Test func shorterTraceForcesFullRebuild() {
        let reducer = TimelineReducer()
        let full = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(full)
        #expect(reducer.items.count == 2)

        let shorter = [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(shorter)

        #expect(!reducer._lastLoadWasIncrementalForTesting,
            "Shorter trace should force full rebuild")
        #expect(reducer.items.count == 1)
    }

    @MainActor
    @Test func incrementalAppendWithToolCallAndResult() {
        let reducer = TimelineReducer()
        let base = makeBaseTrace()
        reducer.loadSession(base)
        let baselineVersion = reducer.renderVersion

        let extended = base + [
            TraceEvent(id: "tc1", type: .toolCall, timestamp: "2025-01-01T00:00:02.000Z",
                       text: nil, tool: "bash", args: ["command": .string("echo hi")],
                       output: nil, toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "tr1", type: .toolResult, timestamp: "2025-01-01T00:00:03.000Z",
                       text: nil, tool: nil, args: nil, output: "hi",
                       toolCallId: "tc1", toolName: "bash", isError: false, thinking: nil),
        ]
        reducer.loadSession(extended)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.renderVersion == baselineVersion + 1)
        #expect(reducer.items.count == 3)

        guard case .toolCall(_, let tool, _, let preview, _, _, _) = reducer.items[2] else {
            Issue.record("Expected incremental tool call at index 2")
            return
        }
        #expect(tool == "bash")
        #expect(preview.contains("hi"))
        #expect(reducer.toolOutputStore.fullOutput(for: "tc1") == "hi")
        #expect(reducer.toolArgsStore.args(for: "tc1")?["command"] == .string("echo hi"))
    }

    @MainActor
    @Test func incrementalAppendWithThinkingEvent() {
        let reducer = TimelineReducer()
        let base = makeBaseTrace()
        reducer.loadSession(base)

        let longThinking = String(repeating: "z", count: 600)
        let extended = base + [
            TraceEvent(id: "th1", type: .thinking, timestamp: "2025-01-01T00:00:02.000Z",
                       text: nil, tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: longThinking),
        ]
        reducer.loadSession(extended)

        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 3)
        guard case .thinking(_, let preview, let hasMore, let isDone) = reducer.items[2] else {
            Issue.record("Expected incremental thinking at index 2")
            return
        }
        #expect(hasMore)
        #expect(isDone)
        #expect(preview == longThinking)
    }

    @MainActor
    @Test func consecutiveIncrementalAppendsAccumulate() {
        let reducer = TimelineReducer()
        let base = makeBaseTrace()
        reducer.loadSession(base)

        let ext1 = base + [
            TraceEvent(id: "e3", type: .assistant, timestamp: "2025-01-01T00:00:02.000Z",
                       text: "Third", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(ext1)
        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 3)

        let ext2 = ext1 + [
            TraceEvent(id: "e4", type: .assistant, timestamp: "2025-01-01T00:00:03.000Z",
                       text: "Fourth", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
        reducer.loadSession(ext2)
        #expect(reducer._lastLoadWasIncrementalForTesting)
        #expect(reducer.items.count == 4)

        guard case .assistantMessage(_, let text, _) = reducer.items[3] else {
            Issue.record("Expected fourth assistant message")
            return
        }
        #expect(text == "Fourth")
    }

    // MARK: - Helpers

    private func makeBaseTrace() -> [TraceEvent] {
        [
            TraceEvent(id: "e1", type: .user, timestamp: "2025-01-01T00:00:00.000Z",
                       text: "Hello", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
            TraceEvent(id: "e2", type: .assistant, timestamp: "2025-01-01T00:00:01.000Z",
                       text: "Hi there!", tool: nil, args: nil, output: nil,
                       toolCallId: nil, toolName: nil, isError: nil, thinking: nil),
        ]
    }
}
