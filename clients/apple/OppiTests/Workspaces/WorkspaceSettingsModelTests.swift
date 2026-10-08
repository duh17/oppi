import Foundation
import Testing
@testable import Oppi

@Suite("Workspace settings requests")
struct WorkspaceSettingsRequestTests {
    @Test func detailsRequestCarriesOnlyChangedFields() {
        let workspace = makeTestWorkspace(name: "Notes", description: "old", hostMount: "~/notes")
        var draft = WorkspaceDetailsDraft(workspace: workspace)
        #expect(draft.request(against: workspace) == nil)

        draft.name = "Notes 2"
        draft.description = ""
        let body = draft.request(against: workspace)?.body

        #expect(body == ["name": .string("Notes 2"), "description": .null])
    }

    @Test func detailsFolderIsTrimmedAndClearedWithNull() {
        let workspace = makeTestWorkspace(hostMount: "~/notes")
        var draft = WorkspaceDetailsDraft(workspace: workspace)

        draft.hostMount = "  ~/notes  "
        #expect(draft.request(against: workspace) == nil)

        draft.hostMount = "  "
        #expect(draft.request(against: workspace)?.body == ["hostMount": .null])
    }

    @Test func sandboxWriteCarriesEveryFieldThatIsNotBeingChanged() {
        let current = SandboxConfig(allowedHosts: ["api.example.com"], env: ["TOKEN_NAME": "x"], mcpServers: ["b", "a"])

        let hostsWrite = WorkspaceSettingsRequests.sandboxConfig(current: current, allowedHosts: [])
        #expect(hostsWrite == .object([
            "allowedHosts": .array([]),
            "mcpServers": .array([.string("a"), .string("b")]),
            "env": .object(["TOKEN_NAME": .string("x")]),
        ]))

        let mcpWrite = WorkspaceSettingsRequests.sandboxConfig(current: current, mcpServers: ["c"])
        #expect(mcpWrite == .object([
            "allowedHosts": .array([.string("api.example.com")]),
            "mcpServers": .array([.string("c")]),
            "env": .object(["TOKEN_NAME": .string("x")]),
        ]))
    }

    @Test func sandboxWriteWithoutSavedConfigKeepsGondolinDefaults() {
        let write = WorkspaceSettingsRequests.sandboxConfig(current: nil, mcpServers: ["a"])
        #expect(write == .object([
            "allowedHosts": .array([.string("*")]),
            "mcpServers": .array([.string("a")]),
        ]))
    }
}

/// Writes through a real `APIClient` against a stubbed transport, so the tests
/// see what the server would receive and how the model reacts to its answer.
@Suite("Workspace settings model writes", .serialized)
@MainActor
struct WorkspaceSettingsModelTests {
    private let serverId = "s1"

    private func makeConnection(workspaces: [Workspace]) -> ServerConnection {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        let client = APIClient(
            environment: OppiClientEnvironment(
                baseURL: URL(string: "http://localhost:7749")!,
                bearerToken: "sk_test"
            ),
            configuration: config
        )
        let connection = ServerConnection()
        connection.setAPIClientForTesting(client)
        connection.workspaceStore.setActiveServer(serverId)
        for workspace in workspaces {
            connection.workspaceStore.upsert(workspace, serverId: serverId)
        }
        return connection
    }

    private func response(status: Int = 200, json: String) throws -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            (try #require(HTTPURLResponse(
                url: URL(string: "http://localhost:7749")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )))
        )
    }

    /// `updatedAt` is later than `makeTestWorkspace`'s unless a test says otherwise.
    private func workspaceJSON(id: String, gitStatusEnabled: Bool, updatedAt: Int64 = 1_800_000_000_000) -> String {
        """
        {"workspace":{"id":"\(id)","name":"Saved","gitStatusEnabled":\(gitStatusEnabled),"createdAt":0,"updatedAt":\(updatedAt)}}
        """
    }

    private func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer.prefix(read))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func toggleWritesOnlyItsFieldAndUpdatesTheStore() async {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", gitStatusEnabled: true)
        let connection = makeConnection(workspaces: [workspace])
        let model = WorkspaceSettingsModel(seed: workspace)
        model.attach(connection: connection, workspace: workspace)

        nonisolated(unsafe) var sentBody: [String: Any] = [:]
        TestURLProtocol.handler = { request in
            sentBody = self.body(of: request)
            return try self.response(json: self.workspaceJSON(id: "w1", gitStatusEnabled: false))
        }

        await model.setGitStatusEnabled(false)

        #expect(sentBody.keys.sorted() == ["gitStatusEnabled"])
        #expect(sentBody["gitStatusEnabled"] as? Bool == false)
        #expect(connection.workspaceStore.workspacesByServer[serverId]?.first?.name == "Saved")
        #expect(model.gitStatusEnabled == false)
        #expect(model.error == nil)
        #expect(!model.isSavingGitStatus)
    }

    @Test func failedToggleRevertsAndShowsTheError() async {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", gitStatusEnabled: true)
        let connection = makeConnection(workspaces: [workspace])
        let model = WorkspaceSettingsModel(seed: workspace)
        model.attach(connection: connection, workspace: workspace)

        TestURLProtocol.handler = { _ in
            try self.response(status: 500, json: "{\"error\":\"disk full\"}")
        }

        await model.setGitStatusEnabled(false)

        #expect(model.gitStatusEnabled == true)
        #expect(model.error != nil)
        #expect(!model.isSavingGitStatus)
        #expect(connection.workspaceStore.workspacesByServer[serverId]?.first?.gitStatusEnabled == true)
    }

    @Test func writeFinishingAfterSwitchingWorkspaceStaysWithItsWorkspace() async {
        defer { TestURLProtocol.handler = nil }
        let first = makeTestWorkspace(id: "w1", gitStatusEnabled: true)
        let second = makeTestWorkspace(id: "w2", gitStatusEnabled: true)
        let connection = makeConnection(workspaces: [first, second])
        let model = WorkspaceSettingsModel(seed: first)
        model.attach(connection: connection, workspace: first)

        TestURLProtocol.handler = { _ in
            try self.response(status: 500, json: "{\"error\":\"disk full\"}")
        }

        // The write is in flight when the view moves to another workspace.
        let write = Task { await model.setGitStatusEnabled(false) }
        await Task.yield()
        model.attach(connection: connection, workspace: second)
        await write.value

        #expect(model.scope?.workspaceId == "w2")
        #expect(model.error == nil)
        #expect(!model.isSavingGitStatus)
        #expect(model.gitStatusEnabled == true)
    }

    @Test func successfulWriteAfterSwitchingWorkspaceStillUpdatesTheOriginalInTheStore() async {
        defer { TestURLProtocol.handler = nil }
        let first = makeTestWorkspace(id: "w1", gitStatusEnabled: true)
        let second = makeTestWorkspace(id: "w2", gitStatusEnabled: true)
        let connection = makeConnection(workspaces: [first, second])
        let model = WorkspaceSettingsModel(seed: first)
        model.attach(connection: connection, workspace: first)

        TestURLProtocol.handler = { _ in
            try self.response(json: self.workspaceJSON(id: "w1", gitStatusEnabled: false))
        }

        let write = Task { await model.setGitStatusEnabled(false) }
        await Task.yield()
        model.attach(connection: connection, workspace: second)
        await write.value

        let stored = connection.workspaceStore.workspacesByServer[serverId] ?? []
        #expect(stored.first { $0.id == "w1" }?.gitStatusEnabled == false)
        #expect(stored.first { $0.id == "w2" }?.gitStatusEnabled == true)
        #expect(model.gitStatusEnabled == true)
    }

    @Test func responseOlderThanTheStoredWorkspaceIsDropped() async {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", gitStatusEnabled: true)
        let connection = makeConnection(workspaces: [workspace])
        let model = WorkspaceSettingsModel(seed: workspace)
        model.attach(connection: connection, workspace: workspace)

        TestURLProtocol.handler = { _ in
            try self.response(json: self.workspaceJSON(id: "w1", gitStatusEnabled: false, updatedAt: 1))
        }

        await model.setGitStatusEnabled(false)

        #expect(connection.workspaceStore.workspacesByServer[serverId]?.first?.name == "Workspace")
    }

    @Test func overlappingWritesRunOneAtATimeAndComposeTheSandboxConfig() async {
        defer { TestURLProtocol.handler = nil }
        var workspace = makeTestWorkspace(id: "w1", gitStatusEnabled: true)
        workspace.runtime = .sandbox
        workspace.sandboxConfig = SandboxConfig(allowedHosts: ["*"], env: ["LANG": "C"], mcpServers: [])
        let connection = makeConnection(workspaces: [workspace])
        let model = WorkspaceSettingsModel(seed: workspace)
        model.attach(connection: connection, workspace: workspace)

        let server = FakeWorkspaceServer(workspaceId: "w1")
        TestURLProtocol.handler = { request in
            let (status, json) = server.handle(request, body: self.body(of: request))
            return try self.response(status: status, json: json)
        }

        async let git: Void = model.setGitStatusEnabled(false)
        async let hosts = model.saveAllowedHosts([])
        async let docs: Void = model.setSandboxMcpServer("docs", enabled: true)
        async let github: Void = model.setSandboxMcpServer("github", enabled: true)
        _ = await (git, hosts, docs, github)

        #expect(server.maxConcurrentRequests == 1)
        let stored = connection.workspaceStore.workspacesByServer[serverId]?.first
        #expect(stored?.gitStatusEnabled == false)
        #expect(stored?.sandboxConfig?.allowedHosts?.isEmpty == true)
        #expect(stored?.sandboxConfig?.mcpServers == ["docs", "github"])
        #expect(stored?.sandboxConfig?.env == ["LANG": "C"])
        // Every sandbox write replaced the config whole, env included.
        #expect(server.sandboxBodies.count == 3)
        #expect(server.sandboxBodies.allSatisfy { ($0["env"] as? [String: String]) == ["LANG": "C"] })
        #expect(model.sandboxMcpSelection == ["docs", "github"])
        #expect(!model.isWritingSandboxConfig)
    }

    @Test func writesAfterDeleteNeverBringTheWorkspaceBack() async {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", gitStatusEnabled: true)
        let connection = makeConnection(workspaces: [workspace])
        let model = WorkspaceSettingsModel(seed: workspace)
        model.attach(connection: connection, workspace: workspace)

        let server = FakeWorkspaceServer(workspaceId: "w1")
        TestURLProtocol.handler = { request in
            let (status, json) = server.handle(request, body: self.body(of: request))
            return try self.response(status: status, json: json)
        }

        async let toggle: Void = model.setGitStatusEnabled(false)
        async let deleted = model.deleteWorkspace()
        _ = await toggle
        let scope = await deleted
        let late = await model.saveInstructions("late")

        #expect(scope == WorkspaceSettingsModel.Scope(serverId: serverId, workspaceId: "w1"))
        #expect(late == .superseded)
        #expect(connection.workspaceStore.workspacesByServer[serverId]?.isEmpty == true)
        #expect(model.isWriteQueueIdle)
    }
}

/// A server that keeps one workspace, applies partial updates the way the real
/// one does (`sandboxConfig` replaced whole), and records how requests overlap.
private final class FakeWorkspaceServer: @unchecked Sendable {
    private let lock = NSLock()
    private let workspaceId: String
    private var gitStatusEnabled = true
    private var instructions: Any = NSNull()
    private var sandboxConfig: [String: Any] = ["allowedHosts": ["*"], "env": ["LANG": "C"], "mcpServers": [String]()]
    private var updatedAt: Int64 = 1_800_000_000_000
    private var deleted = false
    private var inFlight = 0
    private(set) var maxConcurrentRequests = 0
    private(set) var sandboxBodies: [[String: Any]] = []

    init(workspaceId: String) {
        self.workspaceId = workspaceId
    }

    func handle(_ request: URLRequest, body: [String: Any]) -> (Int, String) {
        lock.lock()
        inFlight += 1
        maxConcurrentRequests = max(maxConcurrentRequests, inFlight)
        lock.unlock()
        // Long enough that two requests in flight at once would overlap.
        Thread.sleep(forTimeInterval: 0.03)
        lock.lock()
        defer {
            inFlight -= 1
            lock.unlock()
        }

        if request.httpMethod == "DELETE" {
            deleted = true
            return (200, "{}")
        }
        guard !deleted else { return (404, "{\"error\":\"not found\"}") }
        if let value = body["gitStatusEnabled"] as? Bool { gitStatusEnabled = value }
        if let value = body["systemPrompt"] { instructions = value }
        if let config = body["sandboxConfig"] as? [String: Any] {
            sandboxBodies.append(config)
            sandboxConfig = config
        }
        updatedAt += 1
        let workspace: [String: Any] = [
            "id": workspaceId,
            "name": "Saved",
            "gitStatusEnabled": gitStatusEnabled,
            "runtime": "sandbox",
            "sandboxConfig": sandboxConfig,
            "createdAt": 0,
            "updatedAt": updatedAt,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["workspace": workspace])) ?? Data()
        return (200, String(decoding: data, as: UTF8.self))
    }
}

/// A catalog GET can start before a local save or delete and land after it.
@Suite("Workspace catalog merge")
struct WorkspaceCatalogMergeTests {
    private let before = Date(timeIntervalSince1970: 1_700_000_000)
    private let after = Date(timeIntervalSince1970: 1_700_000_100)

    @Test func staleCatalogRowDoesNotUndoANewerLocalSave() {
        let saved = makeTestWorkspace(id: "w1", name: "Locked down", updatedAt: after)
        let fetched = makeTestWorkspace(id: "w1", name: "Old allow-list", updatedAt: before)

        let merged = WorkspaceCatalogMerge.apply(incoming: [fetched], stored: [saved], deleted: [:])

        #expect(merged.map(\.name) == ["Locked down"])
    }

    @Test func newerCatalogRowReplacesTheStoredOne() {
        let stored = makeTestWorkspace(id: "w1", name: "Mine", updatedAt: before)
        let fetched = makeTestWorkspace(id: "w1", name: "Edited elsewhere", updatedAt: after)

        let merged = WorkspaceCatalogMerge.apply(incoming: [fetched], stored: [stored], deleted: [:])

        #expect(merged.map(\.name) == ["Edited elsewhere"])
    }

    @Test func catalogStillDecidesWhichWorkspacesExist() {
        let stored = [makeTestWorkspace(id: "gone", updatedAt: after)]
        let fetched = [makeTestWorkspace(id: "new", updatedAt: before)]

        let merged = WorkspaceCatalogMerge.apply(incoming: fetched, stored: stored, deleted: [:])

        #expect(merged.map(\.id) == ["new"])
    }

    @Test func locallyDeletedWorkspaceStaysGoneUnlessTheServerHasANewerRow() {
        let stale = makeTestWorkspace(id: "w1", updatedAt: before)
        #expect(WorkspaceCatalogMerge.apply(incoming: [stale], stored: [], deleted: ["w1": before]).isEmpty)

        let newer = makeTestWorkspace(id: "w1", updatedAt: after)
        #expect(WorkspaceCatalogMerge.apply(incoming: [newer], stored: [], deleted: ["w1": before]).map(\.id) == ["w1"])
    }
}
