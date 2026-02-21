import Foundation
import Testing
@testable import Oppi

@Suite("TimelineCache", .serialized)
struct TimelineCacheTests {
    @Test func defaultRootUsesApplicationSupport() async {
        let cache = TimelineCache()
        let metrics = await cache.metrics()

        #expect(metrics.rootPath.contains("Application Support"))
    }

    @Test func decodeFailureReturnsMissAndRemovesCorruptFile() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let corruptURL = root.appending(path: "session-list.json")

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)

        let loaded = await cache.loadSessionList()

        #expect(loaded == nil)
        #expect(!fileManager.fileExists(atPath: corruptURL.path))
    }

    @Test func evictStaleTracesRemovesUnknownSessions() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)

        await cache.saveTrace("s-keep", events: [makeTraceEvent(id: "evt-keep")])
        await cache.saveTrace("s-drop", events: [makeTraceEvent(id: "evt-drop")])

        await cache.evictStaleTraces(keepIds: ["s-keep"])

        let keep = await cache.loadTrace("s-keep")
        let drop = await cache.loadTrace("s-drop")

        #expect(keep != nil)
        #expect(drop == nil)
    }

    private func makeSession(id: String, name: String) -> Session {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Session(
            id: id,
            workspaceId: nil,
            workspaceName: nil,
            name: name,
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: nil,
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            contextTokens: nil,
            contextWindow: nil,
            firstMessage: nil,
            lastMessage: nil,
            thinkingLevel: nil
        )
    }

    private func makeTraceEvent(id: String) -> TraceEvent {
        TraceEvent(
            id: id,
            type: .assistant,
            timestamp: "2026-02-11T00:00:00Z",
            text: "cached",
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }
}
