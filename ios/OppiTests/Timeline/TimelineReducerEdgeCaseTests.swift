import Testing
import Foundation
@testable import Oppi

@Suite("TimelineReducer — Edge Cases")
struct TimelineReducerEdgeCaseTests {

    @MainActor
    @Test func duplicateToolStartDoesNotCreateDuplicateRows() {
        let reducer = TimelineReducer()
        let toolId = "call_1|fc_1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "ls"]))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "ls"]))

        let toolItems = reducer.items.filter {
            if case .toolCall = $0 { return true }
            return false
        }

        #expect(toolItems.count == 1)
        guard case .toolCall(let id, _, _, _, _, _, let isDone) = toolItems[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(id == toolId)
        #expect(!isDone)
    }

    @MainActor
    @Test func duplicateLiveToolStartUpdatesHistoryRowInPlace() {
        let reducer = TimelineReducer()
        let toolId = "call_2|fc_2"

        reducer.loadSession([
            TraceEvent(
                id: toolId,
                type: .toolCall,
                timestamp: "2025-01-01T00:00:00.000Z",
                text: nil,
                tool: "bash",
                args: ["command": .string("pwd")],
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ),
        ])

        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolId, tool: "bash", args: ["command": "pwd"]))

        #expect(reducer.items.count == 1)
        guard case .toolCall(_, _, _, _, _, _, let isDone) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(!isDone)
    }

    @MainActor
    @Test func messageEndDoesNotDuplicateTraceAssistantAfterReload() {
        let reducer = TimelineReducer()

        reducer.loadSession([
            TraceEvent(
                id: "a1",
                type: .assistant,
                timestamp: "2025-01-01T00:00:01.000Z",
                text: "Love you, man. Wrapped clean.",
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            ),
        ])

        reducer.process(.messageEnd(
            sessionId: "s1",
            content: "Love you, man. Wrapped clean."
        ))

        let assistantItems = reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }

        #expect(assistantItems.count == 1)
        guard case .assistantMessage(let id, let text, _) = assistantItems[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(id == "a1")
        #expect(text == "Love you, man. Wrapped clean.")
    }

    @MainActor
    @Test func doubleAgentStartPreservesFirstTurnItems() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "partial "))

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "fresh response"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let assistantItems = reducer.items.filter {
            if case .assistantMessage = $0 { return true }
            return false
        }
        #expect(assistantItems.count == 2)
        guard case .assistantMessage(_, let first, _) = assistantItems[0],
              case .assistantMessage(_, let second, _) = assistantItems[1] else {
            Issue.record("Expected two assistant messages")
            return
        }
        #expect(first == "partial ")
        #expect(second == "fresh response")
    }

    @MainActor
    @Test func resetThenReconnectProducesCleanTimeline() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "stale data"))

        reducer.reset()

        reducer.process(.agentStart(sessionId: "s2"))
        reducer.process(.textDelta(sessionId: "s2", delta: "fresh"))
        reducer.process(.agentEnd(sessionId: "s2"))

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected single assistant message")
            return
        }
        #expect(text == "fresh")
    }

    @MainActor
    @Test func resetClearsEverything() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "hello"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]))
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: "t1", output: "result", isError: false))
        reducer.process(.toolEnd(
            sessionId: "s1",
            toolEventId: "t1",
            details: .object(["ui": .array([.object(["kind": .string("chart")])])])
        ))
        reducer.process(.agentEnd(sessionId: "s1"))

        #expect(reducer.toolDetailsStore.details(for: "t1") != nil)

        let preResetVersion = reducer.renderVersion
        reducer.reset()

        #expect(reducer.items.isEmpty)
        #expect(reducer.streamingAssistantID == nil)
        #expect(reducer.toolOutputStore.totalBytes == 0)
        #expect(reducer.toolDetailsStore.details(for: "t1") == nil)
        #expect(reducer.renderVersion > preResetVersion)
    }

    @MainActor
    @Test func eventsAfterSessionEndedStillAppend() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "hello"))
        reducer.process(.sessionEnded(sessionId: "s1", reason: "stopped"))

        #expect(reducer.items.count == 2)

        reducer.process(.error(sessionId: "s1", message: "late error"))
        #expect(reducer.items.count == 3)
    }

    @MainActor
    @Test func memoryWarningClearsTransientStores() {
        let reducer = TimelineReducer()
        let toolID = "tool-1"

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.toolStart(sessionId: "s1", toolEventId: toolID, tool: "bash", args: ["command": "ls"]))
        reducer.process(.toolOutput(sessionId: "s1", toolEventId: toolID, output: "file1\nfile2", isError: false))
        reducer.process(.toolEnd(
            sessionId: "s1",
            toolEventId: toolID,
            details: .object(["ui": .array([.object(["kind": .string("chart")])])])
        ))
        reducer.process(.agentEnd(sessionId: "s1"))

        reducer.expandedItemIDs.insert(toolID)
        let versionBefore = reducer.renderVersion

        let stats = reducer.handleMemoryWarning()

        #expect(stats.toolOutputBytesCleared > 0)
        #expect(stats.expandedItemsCollapsed == 1)
        #expect(reducer.toolOutputStore.totalBytes == 0)
        #expect(reducer.toolDetailsStore.details(for: toolID) == nil)
        #expect(reducer.expandedItemIDs.isEmpty)
        #expect(reducer.renderVersion > versionBefore)
        #expect(!reducer.items.isEmpty)
    }

    @MainActor
    @Test func memoryWarningStripsImageAttachments() {
        let reducer = TimelineReducer()

        let images = [ImageAttachment(data: String(repeating: "A", count: 10_000), mimeType: "image/png")]
        reducer.appendUserMessage("check this image", images: images)
        reducer.appendUserMessage("no images here")

        let stats = reducer.handleMemoryWarning()

        #expect(stats.imagesStripped == 1)

        if case .userMessage(_, let text, let imgs, _) = reducer.items.first {
            #expect(text == "check this image")
            #expect(imgs.isEmpty)
        } else {
            Issue.record("Expected userMessage as first item")
        }
    }

    @MainActor
    @Test func markdownSegmentCacheSkipsOversizedEntries() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let oversized = String(repeating: "x", count: 50_000)
        cache.set(oversized, segments: [.text(AttributedString("oversized"))])

        #expect(cache.get(oversized) == nil)
        let stats = cache.snapshot()
        #expect(stats.entries == 0)
        #expect(stats.totalSourceBytes == 0)
    }

    @MainActor
    @Test func markdownSegmentCacheEvictsToBudget() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let segment = FlatSegment.text(AttributedString("cached"))
        for idx in 0..<300 {
            let text = "entry-\(idx)-" + String(repeating: "y", count: 2_000)
            cache.set(text, segments: [segment])
        }

        let stats = cache.snapshot()
        #expect(stats.entries <= 128)
        #expect(stats.totalSourceBytes <= 1024 * 1024)
    }

    @MainActor
    @Test func markdownSegmentCacheSeparatesEntriesByTheme() {
        let cache = MarkdownSegmentCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        let content = "same-content"
        cache.set(content, themeID: .dark, segments: [.text(AttributedString("dark"))])
        cache.set(content, themeID: .light, segments: [.text(AttributedString("light"))])

        #expect(cache.get(content, themeID: .dark) != nil)
        #expect(cache.get(content, themeID: .light) != nil)

        let stats = cache.snapshot()
        #expect(stats.entries == 2)
    }

    @MainActor
    @Test func previewTruncatesLongText() {
        let long = String(repeating: "x", count: 600)
        let preview = ChatItem.preview(long)
        #expect(preview.count == ChatItem.maxPreviewLength)
        #expect(preview.hasSuffix("…"))
    }

    @MainActor
    @Test func previewKeepsShortText() {
        let short = "hello"
        #expect(ChatItem.preview(short) == "hello")
    }

    @MainActor
    @Test func chatItemTimestamps() {
        let now = Date()
        let user = ChatItem.userMessage(id: "1", text: "hi", timestamp: now)
        #expect(user.timestamp == now)

        let assistant = ChatItem.assistantMessage(id: "2", text: "hi", timestamp: now)
        #expect(assistant.timestamp == now)

        let tool = ChatItem.toolCall(id: "3", tool: "bash", argsSummary: "", outputPreview: "", outputByteCount: 0, isError: false, isDone: true)
        #expect(tool.timestamp == nil)

        let thinking = ChatItem.thinking(id: "4", preview: "", hasMore: false)
        #expect(thinking.timestamp == nil)

        let perm = ChatItem.permission(PermissionRequest(
            id: "5", sessionId: "s1", tool: "bash",
            input: [:], displaySummary: "x",
            reason: "r",
            timeoutAt: Date()
        ))
        #expect(perm.timestamp == nil)

        let resolved = ChatItem.permissionResolved(id: "6", outcome: .allowed, tool: "bash", summary: "test")
        #expect(resolved.timestamp == nil)

        let system = ChatItem.systemEvent(id: "7", message: "x")
        #expect(system.timestamp == nil)

        let error = ChatItem.error(id: "8", message: "x")
        #expect(error.timestamp == nil)
    }
}
