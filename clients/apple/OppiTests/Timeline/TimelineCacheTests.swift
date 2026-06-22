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

    @Test func sessionListNamespacingIsolatesServers() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let studioSessions = [makeTestSession(id: "studio-session", workspaceId: "w-studio")]
        let miniSessions = [makeTestSession(id: "mini-session", workspaceId: "w-mini")]

        await cache.saveSessionList(studioSessions, serverId: "sha256:studio")
        await cache.saveSessionList(miniSessions, serverId: "sha256:mini")

        let loadedStudio = await cache.loadSessionList(serverId: "sha256:studio")
        let loadedMini = await cache.loadSessionList(serverId: "sha256:mini")
        let loadedGlobal = await cache.loadSessionList()

        #expect(loadedStudio?.map(\.id) == ["studio-session"])
        #expect(loadedMini?.map(\.id) == ["mini-session"])
        #expect(loadedGlobal == nil)
    }

    @Test func saveTraceSkipsIdenticalRewrite() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let events = [makeTraceEvent(id: "evt-1"), makeTraceEvent(id: "evt-2")]

        await cache.saveTrace("session-1", events: events)
        let firstMetrics = await cache.metrics()
        await cache.saveTrace("session-1", events: events)
        let secondMetrics = await cache.metrics()
        let loaded = await cache.loadTrace("session-1")

        #expect(firstMetrics.writes == 1)
        #expect(secondMetrics.writes == 1)
        #expect(loaded?.events.map(\.id) == ["evt-1", "evt-2"])
    }

    @Test func saveTraceWritesChangedPayloadWithSameEventIds() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let firstEvents = [makeTraceEvent(id: "evt-1", text: "old"), makeTraceEvent(id: "evt-2", text: "old")]
        let changedEvents = [makeTraceEvent(id: "evt-1", text: "old"), makeTraceEvent(id: "evt-2", text: "new")]

        await cache.saveTrace("session-1", events: firstEvents)
        await cache.saveTrace("session-1", events: changedEvents)
        let metrics = await cache.metrics()
        let loaded = await cache.loadTrace("session-1")

        #expect(metrics.writes == 2)
        #expect(loaded?.events.map(\.text) == ["old", "new"])
    }

    @Test func saveTraceSkipsOversizedPayloadAndRemovesExistingFile() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let existingEvents = [makeTraceEvent(id: "evt-1", text: "small")]
        let oversizedText = String(repeating: "x", count: TimelineCache.maxTraceCacheBytesForTesting + 1)
        let oversizedEvents = [makeTraceEvent(id: "evt-2", text: oversizedText)]
        let traceURL = root.appending(path: "traces/session-1.json")

        await cache.saveTrace("session-1", events: existingEvents)
        #expect(fileManager.fileExists(atPath: traceURL.path))

        await cache.saveTrace("session-1", events: oversizedEvents)
        let metrics = await cache.metrics()
        let loaded = await cache.loadTrace("session-1")

        #expect(metrics.writes == 1)
        #expect(loaded == nil)
        #expect(!fileManager.fileExists(atPath: traceURL.path))
    }

    private func makeTraceEvent(id: String, text: String = "cached") -> TraceEvent {
        TraceEvent(
            id: id,
            type: .assistant,
            timestamp: "2026-02-11T00:00:00Z",
            text: text,
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
