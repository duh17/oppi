import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("WorkspaceStore Offline", .serialized)
struct WorkspaceStoreOfflineTests {
    @MainActor
    @Test func loadUsesCachedDataWhenOffline() async throws {
        defer { WorkspaceStoreMockURLProtocol.handler = nil }

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appending(path: "workspace-store-tests-\(UUID().uuidString)")
        let root = base.appending(path: "cache-root")
        defer { try? fileManager.removeItem(at: base) }

        let cache = TimelineCache(rootURL: root)
        let cachedWorkspaces = [makeWorkspace(id: "w-cached", name: "Cached Workspace")]
        let cachedSkills = [makeSkill(name: "cached-skill")]
        await cache.saveWorkspaces(cachedWorkspaces)
        await cache.saveSkills(cachedSkills)

        WorkspaceStoreMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let store = WorkspaceStore()
        store._cacheForTesting = cache

        let api = makeAPIClient()
        await store.load(api: api)

        #expect(store.workspaces == cachedWorkspaces)
        #expect(store.skills == cachedSkills)
        #expect(store.isLoaded)
    }

    @MainActor
    @Test func loadFailureKeepsExistingStateWhenAlreadyLoaded() async {
        defer { WorkspaceStoreMockURLProtocol.handler = nil }

        WorkspaceStoreMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let store = WorkspaceStore()
        let existingWorkspaces = [makeWorkspace(id: "w-existing", name: "Existing Workspace")]
        let existingSkills = [makeSkill(name: "existing-skill")]

        store.workspaces = existingWorkspaces
        store.skills = existingSkills
        store.isLoaded = true

        let api = makeAPIClient()
        await store.load(api: api)

        #expect(store.workspaces == existingWorkspaces)
        #expect(store.skills == existingSkills)
        #expect(store.isLoaded)
    }

    private func makeAPIClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceStoreMockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func makeWorkspace(id: String, name: String) -> Workspace {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Workspace(
            id: id,
            name: name,
            description: nil,
            icon: nil,
            skills: [],
            systemPrompt: nil,
            hostMount: nil,
            memoryEnabled: nil,
            memoryNamespace: nil,
            extensions: nil,
            defaultModel: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeSkill(name: String) -> SkillInfo {
        SkillInfo(
            name: name,
            description: "desc",
            containerSafe: true,
            hasScripts: false,
            path: "/tmp/\(name)",
            builtIn: true
        )
    }
}

class WorkspaceStoreMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
