import Foundation
import Testing
@testable import Oppi

/// URLProtocol that answers every request with a cacheable 200.
private final class CacheableResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache-at-rest.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let response = (try #require(HTTPURLResponse(
                url: (testUnwrap(request.url)),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "max-age=3600", "Content-Type": "application/json"]
            )))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: Data(#"{"secret":"session-list"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Local cache at rest", .serialized)
@MainActor
struct LocalCacheAtRestTests {
    private let fileManager = FileManager.default

    // MARK: - Transport

    @Test func serverTransportDoesNotStoreResponsesInTheSharedURLCache() async throws {
        let configuration = TailnetTransportRoute.defaultSessionConfiguration(route: .forHost("cache-at-rest.test"))
        configuration.protocolClasses = [CacheableResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: (testUnwrap(URL(string: "https://cache-at-rest.test/\(UUID().uuidString)"))))
        request.setValue("Bearer at_secret", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)

        #expect(URLCache.shared.cachedResponse(for: request) == nil)

        // Control: the stock default configuration does store this exchange.
        let stock = URLSessionConfiguration.default
        stock.protocolClasses = [CacheableResponseProtocol.self]
        let stockSession = URLSession(configuration: stock)
        defer { stockSession.invalidateAndCancel() }
        _ = try await stockSession.data(for: request)
        #expect(URLCache.shared.cachedResponse(for: request) != nil)
        URLCache.shared.removeCachedResponse(for: request)
    }

    // MARK: - Leftover disk cache

    @Test func purgeRemovesCFNetworkCacheFilesAndNothingElse() throws {
        let dir = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: dir) }
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm"] {
            try Data("rows".utf8).write(to: dir.appending(path: name))
        }
        let fsCachedData = dir.appending(path: "fsCachedData", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: fsCachedData, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: fsCachedData.appending(path: "ABC"))
        let unrelated = dir.appending(path: "timeline-cache", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: unrelated, withIntermediateDirectories: true)

        LocalHTTPCache.purgeLeftovers(in: dir)

        let remaining = try fileManager.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["timeline-cache"])
        LocalHTTPCache.purgeLeftovers(in: dir) // second pass with nothing to delete
        LocalHTTPCache.purgeLeftovers(in: dir.appending(path: "missing"))
    }

    // MARK: - Clear Local Cache

    @Test func clearLocalCacheWipesEveryCacheAndTheHTTPLeftovers() async throws {
        let base = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: base) }
        let timeline = TimelineCache(rootURL: base.appending(path: "timeline"))
        let files = FileBrowserCache(root: base.appending(path: "files"))
        let http = base.appending(path: "http", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: http, withIntermediateDirectories: true)
        try Data("rows".utf8).write(to: http.appending(path: "Cache.db"))
        await timeline.saveWorkspaces([makeTestWorkspace(id: "w1", name: "One")], serverId: "sha256:a")
        await files.cacheFileIndex(["a.txt"], workspaceId: "w1", serverId: "sha256:a")

        await SettingsStoragePage.clearLocalCache(
            timelineCache: timeline,
            fileBrowserCache: files,
            httpCacheDirectory: http
        )

        #expect(await timeline.loadWorkspaces(serverId: "sha256:a") == nil)
        #expect(await files.fileIndex(workspaceId: "w1", serverId: "sha256:a") == nil)
        #expect(!fileManager.fileExists(atPath: http.appending(path: "Cache.db").path))
        #expect(await files.diskSize() == 0)
    }

    // MARK: - Remove Server

    @Test func removingAServerDeletesItsCachedDataAndLeavesOtherServersAlone() async throws {
        let base = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: base) }
        let (coordinator, timeline, files) = makeCoordinator(base: base)
        let gone = makeServer(id: "sha256:cache-gone")
        let kept = makeServer(id: "sha256:cache-kept")
        coordinator.serverStore.addOrUpdate(gone)
        coordinator.serverStore.addOrUpdate(kept)
        coordinator.switchToServer(gone)
        let goneConnection = coordinator.activeConnection
        coordinator.switchToServer(kept)

        await timeline.saveWorkspaces([makeTestWorkspace(id: "w-disk", name: "Disk")], serverId: gone.id)
        await timeline.saveTrace("s1", serverId: gone.id, events: [makeTraceEvent()])
        // Worktree keys and indexes of workspaces no catalog lists any more belong to the server too.
        await files.cacheFileIndex(["a"], workspaceId: "w-disk", serverId: gone.id)
        await files.cacheFileIndex(["b"], workspaceId: "w-disk:worktree-1", serverId: gone.id)
        await files.cacheFileIndex(["c"], workspaceId: "w-orphan", serverId: gone.id)
        await timeline.saveWorkspaces([makeTestWorkspace(id: "w-kept", name: "Kept")], serverId: kept.id)
        await timeline.saveTrace("s1", serverId: kept.id, events: [makeTraceEvent()])
        // The same workspace id on another server is a different cache entry.
        await files.cacheFileIndex(["kept"], workspaceId: "w-disk", serverId: kept.id)
        goneConnection.workspaceStore.upsert(makeTestWorkspace(id: "w-memory", name: "Memory"), serverId: gone.id)
        _ = goneConnection.sessionStore.upsert(makeTestSession(id: "s1", name: "S"))

        await coordinator.removeServer(id: gone.id)

        #expect(await timeline.loadWorkspaces(serverId: gone.id) == nil)
        #expect(await timeline.loadTrace("s1", serverId: gone.id) == nil)
        for key in ["w-disk", "w-disk:worktree-1", "w-orphan"] {
            #expect(await files.fileIndex(workspaceId: key, serverId: gone.id) == nil)
        }
        #expect(goneConnection.workspaceStore.workspacesByServer[gone.id] == nil)
        #expect(goneConnection.sessionStore.sessions(forServer: gone.id).isEmpty)
        #expect(await timeline.loadWorkspaces(serverId: kept.id) != nil)
        #expect(await timeline.loadTrace("s1", serverId: kept.id) != nil)
        #expect(await files.fileIndex(workspaceId: "w-disk", serverId: kept.id) == ["kept"])
        #expect(coordinator.activeServerId == kept.id)
    }

    @Test func savesArrivingAfterRemovalDoNotRecreateTheCacheUntilTheServerIsPairedAgain() async throws {
        let base = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: base) }
        let (coordinator, timeline, files) = makeCoordinator(base: base)
        let server = makeServer(id: "sha256:cache-late")
        coordinator.serverStore.addOrUpdate(server)
        coordinator.restoreActiveServer(server.id)
        await timeline.saveSessionList([makeTestSession(id: "s1", name: "S")], serverId: server.id)

        await coordinator.removeServer(id: server.id)

        // In-flight work finishing after the wipe: list refresh, workspace load,
        // trace save, skills, file-index fetch.
        await timeline.saveSessionList([makeTestSession(id: "s1", name: "Late")], serverId: server.id)
        await timeline.saveWorkspaces([makeTestWorkspace(id: "w1", name: "Late")], serverId: server.id)
        await timeline.saveTrace("s1", serverId: server.id, events: [makeTraceEvent()])
        await files.cacheFileIndex(["late"], workspaceId: "w1", serverId: server.id)
        #expect(await timeline.loadSessionList(serverId: server.id) == nil)
        #expect(await timeline.loadWorkspaces(serverId: server.id) == nil)
        #expect(await timeline.loadTrace("s1", serverId: server.id) == nil)
        #expect(await files.fileIndex(workspaceId: "w1", serverId: server.id) == nil)
        #expect(!fileManager.fileExists(atPath: base.appending(path: "timeline/servers/\(server.id)").path))
        #expect(!fileManager.fileExists(atPath: base.appending(path: "timeline/traces/\(server.id)").path))

        coordinator.addServer(server, switchTo: false)

        await timeline.saveSessionList([makeTestSession(id: "s1", name: "Again")], serverId: server.id)
        await files.cacheFileIndex(["again"], workspaceId: "w1", serverId: server.id)
        #expect(await timeline.loadSessionList(serverId: server.id)?.map(\.name) == ["Again"])
        #expect(await files.fileIndex(workspaceId: "w1", serverId: server.id) == ["again"])
    }

    @Test func aFailedRepairAfterRemovalKeepsTheCacheClosed() async throws {
        let base = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: base) }
        let (coordinator, timeline, files) = makeCoordinator(base: base)
        let server = makeServer(id: "sha256:cache-failed-repair")
        coordinator.serverStore.addOrUpdate(server)
        coordinator.restoreActiveServer(server.id)

        await coordinator.removeServer(id: server.id)
        coordinator._serverInfoBootstrapForTesting = { _, _ in
            throw APIError.server(status: 401, message: "Unauthorized")
        }
        #expect(await coordinator.addServerReady(server, switchTo: false) == .failed)

        // A trace save still in flight from before the removal lands now.
        await timeline.saveTrace("s1", serverId: server.id, events: [makeTraceEvent()])
        await files.cacheFileIndex(["late"], workspaceId: "w1", serverId: server.id)
        #expect(await timeline.loadTrace("s1", serverId: server.id) == nil)
        #expect(await files.fileIndex(workspaceId: "w1", serverId: server.id) == nil)
        #expect(!fileManager.fileExists(atPath: base.appending(path: "timeline/traces/\(server.id)").path))
    }

    @Test func unscopedFileBrowserEntriesFromOlderBuildsAreDeletedOnce() async throws {
        let base = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: base) }
        let legacy = base.appending(path: "0123456789abcdef", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("[\"old\"]".utf8).write(to: legacy.appending(path: "index.json"))

        let files = FileBrowserCache(root: base)
        await files.cacheFileIndex(["new"], workspaceId: "w1", serverId: "sha256:a")
        let relaunched = FileBrowserCache(root: base)

        #expect(!fileManager.fileExists(atPath: legacy.path))
        #expect(await relaunched.fileIndex(workspaceId: "w1", serverId: "sha256:a") == ["new"])
    }

    @Test func removingTheLastServerDeletesItsCacheAndEmptiesThePairing() async throws {
        let base = try makeTempDirectory()
        defer { try? fileManager.removeItem(at: base) }
        let (coordinator, timeline, _) = makeCoordinator(base: base)
        let only = makeServer(id: "sha256:cache-only")
        coordinator.serverStore.addOrUpdate(only)
        coordinator.restoreActiveServer(only.id)
        await timeline.saveSessionList([makeTestSession(id: "s1", name: "S")], serverId: only.id)

        await coordinator.removeServer(id: only.id)

        #expect(coordinator.serverStore.servers.isEmpty)
        #expect(coordinator.activeServerId == nil)
        #expect(await timeline.loadSessionList(serverId: only.id) == nil)
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appending(path: "cache-at-rest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCoordinator(base: URL) -> (ConnectionCoordinator, TimelineCache, FileBrowserCache) {
        UserDefaults.standard.removeObject(forKey: "pairedServerIds")
        KeychainService.deleteAllServers()
        let timeline = TimelineCache(rootURL: base.appending(path: "timeline"))
        let files = FileBrowserCache(root: base.appending(path: "files"))
        let coordinator = ConnectionCoordinator(
            serverStore: ServerStore(),
            timelineCache: timeline,
            fileBrowserCache: files
        )
        coordinator._initialLANEndpointForTesting = { _ in nil }
        coordinator._serverInfoBootstrapForTesting = { _, _ in throw URLError(.timedOut) }
        return (coordinator, timeline, files)
    }

    private func makeServer(id: String) -> PairedServer {
        let credentials = ServerCredentials(
            host: "localhost",
            port: 7749,
            token: "sk_test",
            name: id,
            scheme: .https,
            serverFingerprint: id,
            tlsCertFingerprint: nil
        )
        guard let server = PairedServer(from: credentials, sortOrder: 0) else {
            preconditionFailure("Failed to create PairedServer for test")
        }
        return server
    }

    private func makeTraceEvent() -> TraceEvent {
        TraceEvent(
            id: "evt-1",
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
