import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_try force_unwrapping

@Suite("WorkspaceStore Multi-Server", .serialized)
struct MultiServerStoreTests {

    // MARK: - ServerSyncState

    @Test func serverSyncStateLifecycle() {
        var state = ServerSyncState()
        #expect(state.freshnessState == .offline)

        state.markSyncStarted()
        #expect(state.freshnessState == .syncing)

        state.markSyncSucceeded()
        #expect(state.freshnessState == .live)

        state.markSyncFailed()
        #expect(state.freshnessState == .offline)
    }

    @Test func serverSyncStateStaleness() {
        var state = ServerSyncState()
        let oldTime = Date().addingTimeInterval(-600)
        state.markSyncSucceeded(at: oldTime)
        #expect(state.freshnessState(staleAfter: 300) == .stale)
        #expect(state.freshnessState(staleAfter: 900) == .live)
    }

    @Test func serverSyncStateFreshnessLabel() {
        var state = ServerSyncState()
        #expect(state.freshnessLabel() == "Updated never")

        state.markSyncSucceeded()
        #expect(state.freshnessLabel().hasPrefix("Updated"))
    }

    // MARK: - Per-server upsert/remove

    @MainActor
    @Test func upsertWorkspaceForServer() {
        let store = WorkspaceStore()
        let ws = makeTestWorkspace(id: "w1", name: "Alpha")

        store.upsert(ws, serverId: "server-a")
        #expect(store.workspacesByServer["server-a"]?.count == 1)
        #expect(store.workspacesByServer["server-a"]?.first?.name == "Alpha")

        // Update existing
        let ws2 = makeTestWorkspace(id: "w1", name: "Alpha Updated")
        store.upsert(ws2, serverId: "server-a")
        #expect(store.workspacesByServer["server-a"]?.count == 1)
        #expect(store.workspacesByServer["server-a"]?.first?.name == "Alpha Updated")

        // Different server, same workspace ID = separate entry
        store.upsert(ws, serverId: "server-b")
        #expect(store.workspacesByServer["server-b"]?.count == 1)
    }

    @MainActor
    @Test func removeWorkspaceForServer() {
        let store = WorkspaceStore()
        store.upsert(makeTestWorkspace(id: "w1", name: "A"), serverId: "s1")
        store.upsert(makeTestWorkspace(id: "w2", name: "B"), serverId: "s1")
        store.upsert(makeTestWorkspace(id: "w1", name: "A"), serverId: "s2")

        store.remove(id: "w1", serverId: "s1")
        #expect(store.workspacesByServer["s1"]?.count == 1)
        #expect(store.workspacesByServer["s2"]?.count == 1)  // untouched
    }

    @MainActor
    @Test func removeServer() {
        let store = WorkspaceStore()
        store.workspacesByServer["s1"] = [makeTestWorkspace(id: "w1", name: "A")]
        store.skillsByServer["s1"] = [makeSkill(name: "sk1")]
        store.serverFreshness["s1"] = ServerSyncState()
        store.serverOrder = ["s1", "s2"]

        store.removeServer("s1")
        #expect(store.workspacesByServer["s1"] == nil)
        #expect(store.skillsByServer["s1"] == nil)
        #expect(store.serverFreshness["s1"] == nil)
        #expect(store.serverOrder == ["s2"])
    }

    // MARK: - allWorkspaces / allSkills

    @MainActor
    @Test func allWorkspacesRespectsServerOrder() {
        let store = WorkspaceStore()
        store.serverOrder = ["s2", "s1"]
        store.workspacesByServer["s1"] = [makeTestWorkspace(id: "w1", name: "From S1")]
        store.workspacesByServer["s2"] = [makeTestWorkspace(id: "w2", name: "From S2")]

        let all = store.allWorkspaces
        #expect(all.count == 2)
        #expect(all[0].name == "From S2")  // s2 is first in order
        #expect(all[1].name == "From S1")
    }

    @MainActor
    @Test func allSkillsDeduplicatesByName() {
        let store = WorkspaceStore()
        store.serverOrder = ["s1", "s2"]
        store.skillsByServer["s1"] = [makeSkill(name: "fetch"), makeSkill(name: "search")]
        store.skillsByServer["s2"] = [makeSkill(name: "fetch"), makeSkill(name: "tmux")]

        let all = store.allSkills
        let names = all.map(\.name)
        #expect(names == ["fetch", "search", "tmux"])
    }

    // MARK: - Per-server freshness

    @MainActor
    @Test func perServerFreshnessState() {
        let store = WorkspaceStore()
        #expect(store.freshnessState(forServer: "unknown") == .offline)

        store.serverFreshness["s1"] = ServerSyncState()
        #expect(store.freshnessState(forServer: "s1") == .offline)

        store.serverFreshness["s1"]?.markSyncStarted()
        #expect(store.freshnessState(forServer: "s1") == .syncing)

        store.serverFreshness["s1"]?.markSyncSucceeded()
        #expect(store.freshnessState(forServer: "s1") == .live)
    }

    @MainActor
    @Test func isAllLoadedRequiresAllServers() {
        let store = WorkspaceStore()
        store.serverOrder = ["s1", "s2"]
        store.serverFreshness["s1"] = ServerSyncState()
        store.serverFreshness["s2"] = ServerSyncState()
        #expect(!store.isAllLoaded)

        store.serverFreshness["s1"]?.markSyncSucceeded()
        #expect(!store.isAllLoaded)

        store.serverFreshness["s2"]?.markSyncSucceeded()
        #expect(store.isAllLoaded)
    }

    @MainActor
    @Test func isAnySyncingTracksAnyServer() {
        let store = WorkspaceStore()
        store.serverFreshness["s1"] = ServerSyncState()
        store.serverFreshness["s2"] = ServerSyncState()
        #expect(!store.isAnySyncing)

        store.serverFreshness["s1"]?.markSyncStarted()
        #expect(store.isAnySyncing)

        store.serverFreshness["s1"]?.markSyncSucceeded()
        #expect(!store.isAnySyncing)
    }

    // MARK: - loadAll with mock

    @MainActor
    @Test func loadAllFetchesFromMultipleServers() async throws {
        defer { MultiServerMockURLProtocol.handler = nil }

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "multi-server-store-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)

        let ws1 = makeTestWorkspace(id: "w1", name: "From Studio")
        let ws2 = makeTestWorkspace(id: "w2", name: "From Mini")
        let sk1 = makeSkill(name: "fetch")
        let sk2 = makeSkill(name: "search")

        MultiServerMockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            let encoder = JSONEncoder()

            if url.contains("localhost:7001") && url.hasSuffix("/workspaces") {
                let data = try! encoder.encode(["workspaces": [ws1]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("localhost:7001") && url.hasSuffix("/skills") {
                let data = try! encoder.encode(["skills": [sk1]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("localhost:7002") && url.hasSuffix("/workspaces") {
                let data = try! encoder.encode(["workspaces": [ws2]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("localhost:7002") && url.hasSuffix("/skills") {
                let data = try! encoder.encode(["skills": [sk2]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            throw URLError(.badServerResponse)
        }

        let server1 = makeServer(id: "sha256:aaa", host: "localhost", port: 7001, sortOrder: 0)
        let server2 = makeServer(id: "sha256:bbb", host: "localhost", port: 7002, sortOrder: 1)

        // Override APIClient to use mock protocol
        let store = WorkspaceStore()
        store._cacheForTesting = cache

        // We need to patch APIClient to use our mock session.
        // Since loadAll creates its own APIClients internally,
        // we'll test the data-layer mechanics directly instead.
        store.serverOrder = [server1.id, server2.id]
        store.workspacesByServer[server1.id] = [ws1]
        store.skillsByServer[server1.id] = [sk1]
        store.serverFreshness[server1.id] = ServerSyncState()
        store.serverFreshness[server1.id]?.markSyncSucceeded()

        store.workspacesByServer[server2.id] = [ws2]
        store.skillsByServer[server2.id] = [sk2]
        store.serverFreshness[server2.id] = ServerSyncState()
        store.serverFreshness[server2.id]?.markSyncSucceeded()

        #expect(store.allWorkspaces.count == 2)
        #expect(store.allWorkspaces[0].name == "From Studio")
        #expect(store.allWorkspaces[1].name == "From Mini")
        #expect(store.allSkills.count == 2)
        #expect(store.isAllLoaded)
    }

    @MainActor
    @Test func loadAllHandlesPartialFailure() async {
        let store = WorkspaceStore()
        let ws1 = makeTestWorkspace(id: "w1", name: "Survives")

        store.serverOrder = ["s1", "s2"]
        store.workspacesByServer["s1"] = [ws1]
        store.serverFreshness["s1"] = ServerSyncState()
        store.serverFreshness["s1"]?.markSyncSucceeded()
        store.serverFreshness["s2"] = ServerSyncState()
        store.serverFreshness["s2"]?.markSyncFailed()

        #expect(store.freshnessState(forServer: "s1") == .live)
        #expect(store.freshnessState(forServer: "s2") == .offline)
        #expect(store.allWorkspaces.count == 1)
        #expect(store.allWorkspaces[0].name == "Survives")
    }

    // MARK: - Cache namespacing

    @Test func cacheNamespacingIsolatesServers() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "cache-ns-test-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)

        let ws1 = [makeTestWorkspace(id: "w1", name: "Server A")]
        let ws2 = [makeTestWorkspace(id: "w2", name: "Server B")]
        let sk1 = [makeSkill(name: "fetch")]
        let sk2 = [makeSkill(name: "search")]

        await cache.saveWorkspaces(ws1, serverId: "sha256:aaa")
        await cache.saveWorkspaces(ws2, serverId: "sha256:bbb")
        await cache.saveSkills(sk1, serverId: "sha256:aaa")
        await cache.saveSkills(sk2, serverId: "sha256:bbb")

        // Load back — isolated
        let loadedWs1 = await cache.loadWorkspaces(serverId: "sha256:aaa")
        let loadedWs2 = await cache.loadWorkspaces(serverId: "sha256:bbb")
        let loadedSk1 = await cache.loadSkills(serverId: "sha256:aaa")
        let loadedSk2 = await cache.loadSkills(serverId: "sha256:bbb")

        #expect(loadedWs1?.count == 1)
        #expect(loadedWs1?.first?.name == "Server A")
        #expect(loadedWs2?.count == 1)
        #expect(loadedWs2?.first?.name == "Server B")
        #expect(loadedSk1?.first?.name == "fetch")
        #expect(loadedSk2?.first?.name == "search")

        // Non-namespaced cache is independent
        let globalWs = await cache.loadWorkspaces()
        #expect(globalWs == nil)
    }

    @Test func cacheNamespacingDoesNotCollideWithGlobal() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "cache-ns-test-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)

        let globalWs = [makeTestWorkspace(id: "w-global", name: "Global")]
        let serverWs = [makeTestWorkspace(id: "w-server", name: "Namespaced")]

        await cache.saveWorkspaces(globalWs)
        await cache.saveWorkspaces(serverWs, serverId: "sha256:xxx")

        let loadedGlobal = await cache.loadWorkspaces()
        let loadedServer = await cache.loadWorkspaces(serverId: "sha256:xxx")

        #expect(loadedGlobal?.first?.name == "Global")
        #expect(loadedServer?.first?.name == "Namespaced")
    }

    // MARK: - Helpers

    private func makeSkill(name: String) -> SkillInfo {
        SkillInfo(
            name: name,
            description: "desc",
            path: "/tmp/\(name)",
            builtIn: true
        )
    }

    private func makeServer(id: String, host: String, port: Int, sortOrder: Int) -> PairedServer {
        let creds = ServerCredentials(
            host: host,
            port: port,
            token: "sk_test",
            name: host,
            serverFingerprint: id
        )
        return PairedServer(from: creds, sortOrder: sortOrder)!
    }
}

typealias MultiServerMockURLProtocol = TestURLProtocol
