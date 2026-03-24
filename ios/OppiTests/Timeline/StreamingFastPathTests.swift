import Foundation
import Testing
import UIKit
@testable import Oppi

/// Tests that the streaming fast path in Controller.apply() correctly
/// reconfigures ALL changed items during streaming — not just the
/// streaming assistant cell.
///
/// Bug: The fast path only reconfigured [streamingAssistantID], causing
/// in-flight tool rows and active thinking rows to freeze visually
/// even though their ChatItem content was updated by the reducer.
@Suite("StreamingFastPath")
@MainActor
struct StreamingFastPathTests {

    private let timestamp = Date(timeIntervalSince1970: 0)

    // MARK: - Helpers

    @MainActor
    private final class Harness {
        let window: UIWindow
        let collectionView: AnchoredCollectionView
        let coordinator: ChatTimelineCollectionHost.Controller
        let reducer: TimelineReducer
        let toolOutputStore: ToolOutputStore
        let toolArgsStore: ToolArgsStore
        let toolSegmentStore: ToolSegmentStore
        let connection: ServerConnection
        let scrollController: ChatScrollController
        let audioPlayer: AudioPlayerService

        init() {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
            else {
                fatalError("Missing UIWindowScene")
            }

            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)

            collectionView = AnchoredCollectionView(
                frame: window.bounds,
                collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
            )
            window.addSubview(collectionView)
            window.makeKeyAndVisible()

            coordinator = ChatTimelineCollectionHost.Controller()
            coordinator.configureDataSource(collectionView: collectionView)
            collectionView.delegate = coordinator

            reducer = TimelineReducer()
            toolOutputStore = ToolOutputStore()
            toolArgsStore = ToolArgsStore()
            toolSegmentStore = ToolSegmentStore()
            connection = ServerConnection()
            scrollController = ChatScrollController()
            audioPlayer = AudioPlayerService()
        }

        func apply(
            items: [ChatItem],
            streamingAssistantID: String? = nil,
            isBusy: Bool = true
        ) {
            let config = makeTimelineConfiguration(
                items: items,
                isBusy: isBusy,
                streamingAssistantID: streamingAssistantID,
                sessionId: "test-streaming-fast-path",
                reducer: reducer,
                toolOutputStore: toolOutputStore,
                toolArgsStore: toolArgsStore,
                toolSegmentStore: toolSegmentStore,
                connection: connection,
                scrollController: scrollController,
                audioPlayer: audioPlayer
            )
            coordinator.apply(configuration: config, to: collectionView)
            collectionView.layoutIfNeeded()
        }

        deinit {
            MainActor.assumeIsolated {
                window.isHidden = true
            }
        }
    }

    // MARK: - Tests

    /// When the streaming assistant text changes AND an in-flight tool row
    /// output also changes, the tool row must be reconfigured — not frozen.
    @Test func toolRowUpdatesAlongsideStreamingAssistant() {
        let h = Harness()
        let streamingID = "assistant-1"

        // Initial state: assistant streaming + in-flight tool
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Hello", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "write", argsSummary: "file.swift",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // Verify initial tool output is empty
        let toolItem1 = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, _, let preview1, _, _, _) = toolItem1 else {
            Issue.record("Expected tool call item")
            return
        }
        #expect(preview1 == "")

        // Second apply: assistant text grew AND tool output arrived.
        // Same item count, same streaming ID — should trigger the fast path.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Hello world", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "write", argsSummary: "file.swift",
                outputPreview: "wrote 42 bytes", outputByteCount: 42, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // The tool item in the coordinator must reflect the updated output.
        let toolItem2 = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, _, let preview2, let bytes2, _, _) = toolItem2 else {
            Issue.record("Expected tool call item after update")
            return
        }
        #expect(preview2 == "wrote 42 bytes", "Tool row output should be updated by fast path")
        #expect(bytes2 == 42, "Tool row byte count should be updated by fast path")
    }

    /// When the streaming assistant text changes AND a thinking row preview
    /// updates, the thinking row must be reconfigured.
    @Test func thinkingRowUpdatesAlongsideStreamingAssistant() {
        let h = Harness()
        let streamingID = "assistant-1"

        h.apply(items: [
            .thinking(id: "think-1", preview: "Analyzing...", hasMore: false, isDone: false),
            .assistantMessage(id: streamingID, text: "Based on", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        let thinkItem1 = h.coordinator.currentItemByID["think-1"]
        guard case .thinking(_, let preview1, _, _) = thinkItem1 else {
            Issue.record("Expected thinking item")
            return
        }
        #expect(preview1 == "Analyzing...")

        // Second apply: assistant grew + thinking preview updated.
        h.apply(items: [
            .thinking(id: "think-1", preview: "Analyzing the code structure...", hasMore: true, isDone: false),
            .assistantMessage(id: streamingID, text: "Based on my analysis", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        let thinkItem2 = h.coordinator.currentItemByID["think-1"]
        guard case .thinking(_, let preview2, let hasMore2, _) = thinkItem2 else {
            Issue.record("Expected thinking item after update")
            return
        }
        #expect(preview2 == "Analyzing the code structure...", "Thinking preview should be updated by fast path")
        #expect(hasMore2 == true, "Thinking hasMore should be updated by fast path")
    }

    /// When ONLY the streaming assistant changes (no other mutable items),
    /// the fast path should still fire correctly (regression guard).
    @Test func streamingOnlyAssistantStillWorks() {
        let h = Harness()
        let streamingID = "assistant-1"

        h.apply(items: [
            .userMessage(id: "user-1", text: "Hi", timestamp: timestamp),
            .assistantMessage(id: streamingID, text: "Hello", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        h.apply(items: [
            .userMessage(id: "user-1", text: "Hi", timestamp: timestamp),
            .assistantMessage(id: streamingID, text: "Hello, how can I help?", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        let assistantItem = h.coordinator.currentItemByID[streamingID]
        guard case .assistantMessage(_, let text, _) = assistantItem else {
            Issue.record("Expected assistant item")
            return
        }
        #expect(text == "Hello, how can I help?")
    }

    /// When a tool transitions from in-flight (isDone=false) to completed
    /// (isDone=true) while streaming continues, the tool row must update.
    /// Bug: isStreamingMutableItem only checks the NEW item, which has
    /// isDone=true → returns false → tool-done transition is invisible.
    @Test func toolDoneTransitionDuringStreaming() {
        let h = Harness()
        let streamingID = "assistant-1"

        // Tool is in-flight while assistant streams.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Running command", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "echo hi",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // Tool completes (isDone: false → true) while assistant text grows.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Running command completed", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "echo hi",
                outputPreview: "hi\n", outputByteCount: 3, isError: false, isDone: true
            ),
        ], streamingAssistantID: streamingID)

        let toolItem = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, _, let preview, let bytes, _, let isDone) = toolItem else {
            Issue.record("Expected tool call item after done transition")
            return
        }
        #expect(isDone == true, "Tool should be marked done")
        #expect(preview == "hi\n", "Tool output should reflect completed state")
        #expect(bytes == 3, "Tool byte count should reflect completed state")
    }

    /// When thinking transitions from active to done while streaming,
    /// the thinking row must update.
    @Test func thinkingDoneTransitionDuringStreaming() {
        let h = Harness()
        let streamingID = "assistant-1"

        h.apply(items: [
            .thinking(id: "think-1", preview: "Let me think...", hasMore: false, isDone: false),
            .assistantMessage(id: streamingID, text: "Based on", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        // Thinking completes while assistant text grows.
        h.apply(items: [
            .thinking(id: "think-1", preview: "Let me think about this carefully.", hasMore: true, isDone: true),
            .assistantMessage(id: streamingID, text: "Based on my analysis", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        let thinkItem = h.coordinator.currentItemByID["think-1"]
        guard case .thinking(_, let preview, _, let isDone) = thinkItem else {
            Issue.record("Expected thinking item after done transition")
            return
        }
        #expect(isDone == true, "Thinking should be marked done")
        #expect(preview == "Let me think about this carefully.", "Thinking preview should reflect completed state")
    }

    // MARK: - Structural change → fast path transition tests

    /// After a structural change adds a new tool (full path), subsequent
    /// fast path cycles must still update that tool's content.
    /// Bug: tool appears with initial content then freezes because the
    /// fast path doesn't pick up changes after structural insertion.
    @Test func newToolUpdatesAfterStructuralInsert() {
        let h = Harness()
        let streamingID = "assistant-1"

        // Step 1: assistant streaming alone (1 item).
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Running", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        // Step 2: structural change — new tool appears (2 items, full path).
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Running bash", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "$",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        let toolAfterInsert = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, let summary1, _, _, _, _) = toolAfterInsert else {
            Issue.record("Expected tool after structural insert")
            return
        }
        #expect(summary1 == "$", "Tool should have initial argsSummary")

        // Step 3: fast path — same 2 items, assistant text grew, tool args updated.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Running bash command", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "$ cd /Users/chenda/workspace",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        let toolAfterFastPath = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, let summary2, _, _, _, _) = toolAfterFastPath else {
            Issue.record("Expected tool after fast path update")
            return
        }
        #expect(
            summary2 == "$ cd /Users/chenda/workspace",
            "Tool argsSummary should update via fast path after structural insert"
        )
    }

    /// After a structural change adds a SECOND tool (with first already done),
    /// the new tool must update on subsequent fast path cycles.
    @Test func secondToolUpdatesAfterStructuralInsert() {
        let h = Harness()
        let streamingID = "assistant-1"

        // Step 1: assistant + completed tool (2 items).
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Done with first", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "echo hi",
                outputPreview: "hi", outputByteCount: 2, isError: false, isDone: true
            ),
        ], streamingAssistantID: streamingID)

        // Step 2: structural change — second tool appears (3 items, full path).
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Now running second", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "echo hi",
                outputPreview: "hi", outputByteCount: 2, isError: false, isDone: true
            ),
            .toolCall(
                id: "tool-2", tool: "bash", argsSummary: "$ cd",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // Step 3: fast path — assistant grew, tool-2 output arrived.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Now running second command", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "echo hi",
                outputPreview: "hi", outputByteCount: 2, isError: false, isDone: true
            ),
            .toolCall(
                id: "tool-2", tool: "bash", argsSummary: "$ cd /workspace",
                outputPreview: "ok", outputByteCount: 2, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        let tool2 = h.coordinator.currentItemByID["tool-2"]
        guard case .toolCall(_, _, let summary, let preview, _, _, _) = tool2 else {
            Issue.record("Expected tool-2 after fast path")
            return
        }
        #expect(summary == "$ cd /workspace", "Second tool argsSummary must update via fast path")
        #expect(preview == "ok", "Second tool output must update via fast path")
    }

    /// When a tool transitions from in-flight to done in a structural
    /// change (new item added simultaneously), the done tool must also
    /// be updated even though it is no longer mutable.
    @Test func toolDoneAndNewToolInSameStructuralChange() {
        let h = Harness()
        let streamingID = "assistant-1"

        // Step 1: assistant + in-flight tool.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Working", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "npm test",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // Step 2: structural change — tool-1 done + tool-2 new (3 items).
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "First done, starting second", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "npm test",
                outputPreview: "all passed", outputByteCount: 10, isError: false, isDone: true
            ),
            .toolCall(
                id: "tool-2", tool: "bash", argsSummary: "$ npm run build",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // tool-1 should be done with output.
        let tool1 = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, _, let preview1, _, _, let done1) = tool1 else {
            Issue.record("Expected tool-1")
            return
        }
        #expect(done1 == true, "tool-1 should be done after structural change")
        #expect(preview1 == "all passed", "tool-1 output should be updated")

        // Step 3: fast path — tool-2 updates.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Building now", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "npm test",
                outputPreview: "all passed", outputByteCount: 10, isError: false, isDone: true
            ),
            .toolCall(
                id: "tool-2", tool: "bash", argsSummary: "$ npm run build",
                outputPreview: "compiled", outputByteCount: 8, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        let tool2 = h.coordinator.currentItemByID["tool-2"]
        guard case .toolCall(_, _, _, let preview2, _, _, _) = tool2 else {
            Issue.record("Expected tool-2 after fast path")
            return
        }
        #expect(preview2 == "compiled", "tool-2 output should update via fast path")
    }

    /// A new tool appears but the streaming assistant ID is absent (nil)
    /// in the SAME tick. The structural change should still be applied
    /// via the full path.
    @Test func newToolWithoutStreamingAssistant() {
        let h = Harness()
        let streamingID = "assistant-1"

        // Step 1: assistant done, no streaming.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Let me run this", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        // Step 2: streaming stops, tool appears (structural + no streaming ID).
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Let me run this", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "ls -la",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: nil, isBusy: true)

        let tool = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, let summary, _, _, _, _) = tool else {
            Issue.record("Expected tool after structural insert without streaming")
            return
        }
        #expect(summary == "ls -la", "Tool should appear via full path when no streaming ID")
    }

    // MARK: - No-op fast path: assistant unchanged but other items changed

    /// When the assistant text is IDENTICAL between ticks but a tool's
    /// output changes, the no-op fast path must NOT swallow the update.
    /// Bug: the no-op path checks only `prevItem == nextItem` on the
    /// assistant and returns early, ignoring tool changes.
    @Test func toolUpdatesWhenAssistantTextUnchanged() {
        let h = Harness()
        let streamingID = "assistant-1"

        // Step 1: assistant streaming + tool in-flight (initial state).
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Running command", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "npm test",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // Step 2: assistant text IDENTICAL, but tool output arrived.
        // The 33ms coalescer may deliver tool output in a tick where
        // no new assistant text was flushed.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Running command", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "npm test",
                outputPreview: "3 tests passed", outputByteCount: 14, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        let tool = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, _, let preview, let bytes, _, _) = tool else {
            Issue.record("Expected tool after no-op path")
            return
        }
        #expect(preview == "3 tests passed", "Tool output must update even when assistant text unchanged")
        #expect(bytes == 14, "Tool byte count must update even when assistant text unchanged")
    }

    /// When the assistant text is identical and a tool completes (isDone
    /// transitions), the update must not be swallowed.
    @Test func toolCompletesWhenAssistantTextUnchanged() {
        let h = Harness()
        let streamingID = "assistant-1"

        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Waiting for result", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "ls",
                outputPreview: "", outputByteCount: 0, isError: false, isDone: false
            ),
        ], streamingAssistantID: streamingID)

        // Tool completes but assistant text is the same.
        h.apply(items: [
            .assistantMessage(id: streamingID, text: "Waiting for result", timestamp: timestamp),
            .toolCall(
                id: "tool-1", tool: "bash", argsSummary: "ls",
                outputPreview: "file.txt", outputByteCount: 8, isError: false, isDone: true
            ),
        ], streamingAssistantID: streamingID)

        let tool = h.coordinator.currentItemByID["tool-1"]
        guard case .toolCall(_, _, _, let preview, _, _, let isDone) = tool else {
            Issue.record("Expected tool after completion")
            return
        }
        #expect(isDone == true, "Tool should be done even when assistant text unchanged")
        #expect(preview == "file.txt", "Tool output should update even when assistant text unchanged")
    }

    /// When the assistant text is identical and thinking content changes,
    /// the thinking row must still update.
    @Test func thinkingUpdatesWhenAssistantTextUnchanged() {
        let h = Harness()
        let streamingID = "assistant-1"

        h.apply(items: [
            .thinking(id: "think-1", preview: "Hmm...", hasMore: false, isDone: false),
            .assistantMessage(id: streamingID, text: "Let me check", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        // Thinking preview grows but assistant text unchanged.
        h.apply(items: [
            .thinking(id: "think-1", preview: "Hmm... I need to look at the code", hasMore: true, isDone: false),
            .assistantMessage(id: streamingID, text: "Let me check", timestamp: timestamp),
        ], streamingAssistantID: streamingID)

        let think = h.coordinator.currentItemByID["think-1"]
        guard case .thinking(_, let preview, let hasMore, _) = think else {
            Issue.record("Expected thinking item")
            return
        }
        #expect(preview == "Hmm... I need to look at the code", "Thinking must update when assistant unchanged")
        #expect(hasMore == true, "Thinking hasMore must update when assistant unchanged")
    }
}
