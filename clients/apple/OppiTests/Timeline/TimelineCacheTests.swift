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

    @Test func missingSchemaMarkerPurgesExistingCacheOnce() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let traces = root.appending(path: "traces/\(traceServer)", directoryHint: .isDirectory)
        let staleTrace = traces.appending(path: "session-old.json")

        defer { try? fileManager.removeItem(at: base) }

        try fileManager.createDirectory(at: traces, withIntermediateDirectories: true)
        try Data("old-cache".utf8).write(to: staleTrace, options: .atomic)

        _ = TimelineCache(rootURL: root)

        #expect(!fileManager.fileExists(atPath: staleTrace.path))
        #expect(fileManager.fileExists(atPath: schemaMarkerURL(root).path))
    }

    /// While the device is locked the marker exists but cannot be read. That is
    /// not a missing marker: the cache survives and no new marker replaces it.
    @Test func unreadableSchemaMarkerKeepsCacheAndMarker() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let marker = schemaMarkerURL(root)

        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
            try? fileManager.removeItem(at: base)
        }

        let first = TimelineCache(rootURL: root)
        await first.saveTrace("session-1", serverId: traceServer, events: [makeTraceEvent(id: "evt-1")])
        let markerBytes = try Data(contentsOf: marker)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
        #expect((try? Data(contentsOf: marker)) == nil)

        _ = TimelineCache(rootURL: root)

        // An atomic rewrite would have replaced the unreadable file.
        let permissions = try fileManager.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int
        #expect(permissions == 0)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        #expect(try Data(contentsOf: marker) == markerBytes)

        let unlocked = TimelineCache(rootURL: root)
        let loaded = await unlocked.loadTrace("session-1", serverId: traceServer)
        #expect(loaded?.events.map(\.id) == ["evt-1"])
    }

    @Test func olderSchemaGenerationDropsSessionKeyedCache() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let traces = root.appending(path: "traces/\(traceServer)", directoryHint: .isDirectory)
        let staleTrace = traces.appending(path: "old-short-id.json")

        defer { try? fileManager.removeItem(at: base) }

        try fileManager.createDirectory(at: traces, withIntermediateDirectories: true)
        try Data("old-cache".utf8).write(to: staleTrace, options: .atomic)
        try JSONEncoder().encode(["generation": 2]).write(to: schemaMarkerURL(root), options: .atomic)

        _ = TimelineCache(rootURL: root)

        #expect(!fileManager.fileExists(atPath: staleTrace.path))
    }

    @Test func matchingSchemaPreservesCacheAcrossRelaunch() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let first = TimelineCache(rootURL: root)
        await first.saveTrace("session-1", serverId: traceServer, events: [makeTraceEvent(id: "evt-1")])

        let second = TimelineCache(rootURL: root)
        let loaded = await second.loadTrace("session-1", serverId: traceServer)

        #expect(loaded?.events.map(\.id) == ["evt-1"])
    }

    @Test func clearRecreatesCurrentSchemaMarker() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        await cache.clear()

        #expect(fileManager.fileExists(atPath: schemaMarkerURL(root).path))

        let relaunched = TimelineCache(rootURL: root)
        await relaunched.saveTrace("session-1", serverId: traceServer, events: [makeTraceEvent(id: "evt-1")])
        let loaded = await relaunched.loadTrace("session-1", serverId: traceServer)
        #expect(loaded?.events.map(\.id) == ["evt-1"])
    }

    @Test func initPrunesExpiredTraceFilesBeforeFirstSave() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let traces = root.appending(path: "traces/\(traceServer)", directoryHint: .isDirectory)
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

    /// Earlier builds wrote server-less files straight under the cache root, where
    /// Remove Server could not reach them. Launch deletes exactly those files.
    @Test func launchDeletesUnscopedFilesAndKeepsEverythingElse() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let catalog = ServerResourceCatalogSnapshot(
            skills: [], extensions: [], builtInTools: [],
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            skillsLoaded: true, extensionsLoaded: true,
            skillsSavedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extensionsSavedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await cache.saveTrace("session-1", serverId: traceServer, events: [makeTraceEvent(id: "evt-1")])
        await cache.saveSessionList([makeTestSession(id: "s1", workspaceId: "w")], serverId: traceServer)
        await cache.saveWorkspaces([makeTestWorkspace(id: "w1", name: "Scoped")], serverId: traceServer)
        await cache.saveSkills([SkillInfo(name: "scoped", description: "d", path: "/p", builtIn: true)], serverId: traceServer)
        await cache.saveServerResourceCatalog(catalog, serverId: traceServer)

        let unscoped = [
            root.appending(path: "workspaces.json"),
            root.appending(path: "skills.json"),
            root.appending(path: "session-list.json"),
            root.appending(path: "skills/fetch.json"),
            root.appending(path: "traces/legacy-session.json"),
        ]
        let unrelated = root.appending(path: "unrelated-note.txt")
        try fileManager.createDirectory(at: root.appending(path: "skills"), withIntermediateDirectories: true)
        for url in unscoped + [unrelated] {
            try Data("x".utf8).write(to: url)
        }

        let relaunched = TimelineCache(rootURL: root)
        // A second launch finds nothing to delete and changes nothing.
        let again = TimelineCache(rootURL: root)

        for url in unscoped {
            #expect(!fileManager.fileExists(atPath: url.path), "\(url.lastPathComponent) survived")
        }
        #expect(fileManager.fileExists(atPath: unrelated.path))
        #expect(fileManager.fileExists(atPath: schemaMarkerURL(root).path))
        for cache in [relaunched, again] {
            #expect(await cache.loadTrace("session-1", serverId: traceServer)?.events.map(\.id) == ["evt-1"])
            #expect(await cache.loadSessionList(serverId: traceServer)?.map(\.id) == ["s1"])
            #expect(await cache.loadWorkspaces(serverId: traceServer)?.map(\.id) == ["w1"])
            #expect(await cache.loadSkills(serverId: traceServer)?.map(\.name) == ["scoped"])
            #expect(await cache.loadServerResourceCatalog(serverId: traceServer) == catalog)
        }
    }

    @Test func decodeFailureReturnsMissAndRemovesCorruptFile() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let corruptURL = root.appending(path: "servers/\(traceServer)/session-list.json")

        try fileManager.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)

        let loaded = await cache.loadSessionList(serverId: traceServer)

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

        #expect(loadedStudio?.map(\.id) == ["studio-session"])
        #expect(loadedMini?.map(\.id) == ["mini-session"])
    }

    @Test func removeServerDeletesOnlyThatServersCache() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        for serverId in ["sha256:studio", "sha256:mini"] {
            await cache.saveTrace("session-1", serverId: serverId, events: [makeTraceEvent(id: serverId)])
            await cache.saveSessionList([makeTestSession(id: serverId, workspaceId: "w")], serverId: serverId)
        }

        await cache.removeServer("sha256:studio")

        #expect(await cache.loadTrace("session-1", serverId: "sha256:studio") == nil)
        #expect(await cache.loadSessionList(serverId: "sha256:studio") == nil)
        #expect(await cache.loadTrace("session-1", serverId: "sha256:mini")?.events.map(\.id) == ["sha256:mini"])
        #expect(await cache.loadSessionList(serverId: "sha256:mini")?.map(\.id) == ["sha256:mini"])
    }

    @Test func resourceCatalogNamespacingPreservesIndependentServerSnapshots() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let studioSavedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let miniSavedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let studio = ServerResourceCatalogSnapshot(
            skills: [],
            extensions: [],
            builtInTools: [],
            savedAt: studioSavedAt,
            skillsLoaded: true,
            extensionsLoaded: true,
            skillsSavedAt: studioSavedAt,
            extensionsSavedAt: studioSavedAt
        )
        let mini = ServerResourceCatalogSnapshot(
            skills: [],
            extensions: [],
            builtInTools: [],
            savedAt: miniSavedAt,
            skillsLoaded: true,
            extensionsLoaded: true,
            skillsSavedAt: miniSavedAt,
            extensionsSavedAt: miniSavedAt
        )

        await cache.saveServerResourceCatalog(studio, serverId: "sha256:studio")
        await cache.saveServerResourceCatalog(mini, serverId: "sha256:mini")

        #expect(await cache.loadServerResourceCatalog(serverId: "sha256:studio") == studio)
        #expect(await cache.loadServerResourceCatalog(serverId: "sha256:mini") == mini)
        #expect(await cache.loadServerResourceCatalog(serverId: "sha256:other") == nil)
    }

    @Test func resourceCatalogRoundTripPreservesIndependentLoadedAndFreshnessState() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        defer { try? fileManager.removeItem(at: base) }

        let savedAt = Date(timeIntervalSince1970: 1_700_000_010)
        let cache = TimelineCache(rootURL: root)
        let partial = ServerResourceCatalogSnapshot(
            skills: [],
            extensions: [],
            builtInTools: [],
            savedAt: savedAt,
            skillsLoaded: true,
            extensionsLoaded: false,
            skillsSavedAt: savedAt,
            extensionsSavedAt: nil
        )

        await cache.saveServerResourceCatalog(partial, serverId: "sha256:partial")
        let loaded = await cache.loadServerResourceCatalog(serverId: "sha256:partial")

        #expect(loaded == partial)
        #expect(loaded?.skillsLoaded == true)
        #expect(loaded?.extensionsLoaded == false)
        #expect(loaded?.skillsSavedAt == savedAt)
        #expect(loaded?.extensionsSavedAt == nil)
    }

    @Test func traceNamespacingIsolatesServersWithIdenticalSessionIds() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        await cache.saveTrace("shared-session", serverId: "sha256:studio", events: [makeTraceEvent(id: "studio")])
        await cache.saveTrace("shared-session", serverId: "sha256:mini", events: [makeTraceEvent(id: "mini")])

        let studio = await cache.loadTrace("shared-session", serverId: "sha256:studio")
        let mini = await cache.loadTrace("shared-session", serverId: "sha256:mini")

        #expect(studio?.events.map(\.id) == ["studio"])
        #expect(mini?.events.map(\.id) == ["mini"])
    }

    @Test func saveTraceSkipsIdenticalRewrite() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let events = [makeTraceEvent(id: "evt-1"), makeTraceEvent(id: "evt-2")]

        await cache.saveTrace("session-1", serverId: traceServer, events: events)
        let firstMetrics = await cache.metrics()
        await cache.saveTrace("session-1", serverId: traceServer, events: events)
        let secondMetrics = await cache.metrics()
        let loaded = await cache.loadTrace("session-1", serverId: traceServer)

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

        await cache.saveTrace("session-1", serverId: traceServer, events: firstEvents)
        await cache.saveTrace("session-1", serverId: traceServer, events: changedEvents)
        let metrics = await cache.metrics()
        let loaded = await cache.loadTrace("session-1", serverId: traceServer)

        #expect(metrics.writes == 2)
        #expect(loaded?.events.map(\.text) == ["old", "new"])
    }

    @Test func saveTracePersistsPartialPageMetadata() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "timeline-cache-tests-\(UUID().uuidString)")
        let root = base.appending(path: "root")

        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let page = TracePageMetadata(
            hasOlder: true,
            olderCursor: "cursor-1",
            traceVersion: "123:456",
            previewBytes: 4096,
            staleCursor: false
        )

        await cache.saveTrace("session-1", serverId: traceServer, events: [makeTraceEvent(id: "evt-1")], page: page)
        let loaded = await cache.loadTrace("session-1", serverId: traceServer)

        #expect(loaded?.page == page)
        #expect(loaded?.isPartial == true)
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
        let traceURL = root.appending(path: "traces/\(traceServer)/session-1.json")

        await cache.saveTrace("session-1", serverId: traceServer, events: existingEvents)
        #expect(fileManager.fileExists(atPath: traceURL.path))

        await cache.saveTrace("session-1", serverId: traceServer, events: largeEvents)
        let metrics = await cache.metrics()
        let loaded = await cache.loadTrace("session-1", serverId: traceServer)

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

        await cache.saveTrace("a-old", serverId: traceServer, events: [makeTraceEvent(id: "old", text: payload)])
        await cache.saveTrace("b-mid", serverId: traceServer, events: [makeTraceEvent(id: "mid", text: payload)])
        await cache.saveTrace("c-new", serverId: traceServer, events: [makeTraceEvent(id: "new", text: payload)])

        let old = await cache.loadTrace("a-old", serverId: traceServer)
        let mid = await cache.loadTrace("b-mid", serverId: traceServer)
        let new = await cache.loadTrace("c-new", serverId: traceServer)
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
        let oldTraceURL = root.appending(path: "traces/\(traceServer)/session-old.json")

        await cache.saveTrace("session-old", serverId: traceServer, events: [makeTraceEvent(id: "old")])
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: oldTraceURL.path
        )
        await cache.saveTrace("session-new", serverId: traceServer, events: [makeTraceEvent(id: "new")])

        let old = await cache.loadTrace("session-old", serverId: traceServer)
        let new = await cache.loadTrace("session-new", serverId: traceServer)

        #expect(old == nil)
        #expect(new?.events.map(\.id) == ["new"])
    }

    private let traceServer = "sha256:trace-server"

    private func schemaMarkerURL(_ root: URL) -> URL {
        root.appending(path: "timeline-cache-schema.json")
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
