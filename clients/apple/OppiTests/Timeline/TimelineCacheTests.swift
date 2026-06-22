import Foundation
import Testing
@testable import Oppi

@Suite("TimelineCache", .serialized)
struct TimelineCacheTests {
    @Test func defaultRootUsesCachesDirectory() async {
        let cache = TimelineCache()
        let metrics = await cache.metrics()

        #expect(metrics.rootPath.contains("Caches"))
        #expect(!metrics.rootPath.contains("Application Support"))
    }

    @Test func initPrunesExpiredTraceFilesBeforeFirstSave() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let traces = root.appending(path: "traces", directoryHint: .isDirectory)
        let expiredTrace = traces.appending(path: "session-old.json")

        defer { try? fileManager.removeItem(at: base) }

        try fileManager.createDirectory(at: traces, withIntermediateDirectories: true)
        try Data("old-cache".utf8).write(to: expiredTrace, options: .atomic)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: expiredTrace.path
        )

        _ = TimelineCache(
            rootURL: root,
            maxDiskBytes: 1_000_000,
            maxTraceAge: 60,
            now: { Date(timeIntervalSince1970: 120) }
        )

        #expect(!fileManager.fileExists(atPath: expiredTrace.path))
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

    @Test func saveTraceAllowsLargePayloadsAndReliesOnTotalBudget() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root, maxDiskBytes: 64 * 1024 * 1024, maxTraceAge: nil)
        let existingEvents = [makeTraceEvent(id: "evt-1", text: "small")]
        let largeText = String(repeating: "x", count: 9 * 1024 * 1024)
        let largeEvents = [makeTraceEvent(id: "evt-2", text: largeText)]
        let traceURL = root.appending(path: "traces/session-1.json")

        await cache.saveTrace("session-1", events: existingEvents)
        #expect(fileManager.fileExists(atPath: traceURL.path))

        await cache.saveTrace("session-1", events: largeEvents)
        let metrics = await cache.metrics()
        let loaded = await cache.loadTrace("session-1")

        #expect(metrics.writes == 2)
        #expect(loaded?.events.map(\.id) == ["evt-2"])
        #expect(loaded?.events.first?.text?.count == largeText.count)
        #expect(fileManager.fileExists(atPath: traceURL.path))
    }

    @Test func saveTracePrunesOldestTracesWhenCacheExceedsBudget() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root, maxDiskBytes: 5_500, maxTraceAge: nil)
        let payload = String(repeating: "x", count: 2_000)

        await cache.saveTrace("a-old", events: [makeTraceEvent(id: "old", text: payload)])
        await cache.saveTrace("b-mid", events: [makeTraceEvent(id: "mid", text: payload)])
        await cache.saveTrace("c-new", events: [makeTraceEvent(id: "new", text: payload)])

        let old = await cache.loadTrace("a-old")
        let mid = await cache.loadTrace("b-mid")
        let new = await cache.loadTrace("c-new")
        let bytes = await cache.diskSize()

        #expect(old == nil)
        #expect(mid?.events.map(\.id) == ["mid"])
        #expect(new?.events.map(\.id) == ["new"])
        #expect(bytes <= 5_500)
    }

    @Test func saveTracePrunesExpiredTraceFiles() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(
            rootURL: root,
            maxDiskBytes: 1_000_000,
            maxTraceAge: 60,
            now: { Date(timeIntervalSince1970: 120) }
        )
        let oldTraceURL = root.appending(path: "traces/session-old.json")

        await cache.saveTrace("session-old", events: [makeTraceEvent(id: "old")])
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: oldTraceURL.path
        )
        await cache.saveTrace("session-new", events: [makeTraceEvent(id: "new")])

        let old = await cache.loadTrace("session-old")
        let new = await cache.loadTrace("session-new")

        #expect(old == nil)
        #expect(new?.events.map(\.id) == ["new"])
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
