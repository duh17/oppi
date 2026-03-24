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
}
