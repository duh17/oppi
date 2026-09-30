import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("MCP servers list during sign-in")
struct McpServersModelTests {
    @Test func adoptsTheHostsLiveFlowFromAFreshListWithoutOpeningTheSheet() async {
        let model = McpServersModel()
        defer { model.signIn.attempt?.stopPolling() }
        await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient(),
                            list: { response(flow: flow(.awaitingExternal)) })
        #expect(model.signIn.hasActive)
        #expect(model.signIn.attempt?.serverId == "host")
        #expect(model.signIn.attempt?.serverName == "Studio")
        #expect(model.signIn.attempt?.providerName == "remote")
        #expect(model.signIn.scopeId == "global")
        #expect(!model.signIn.showingSheet)
        #expect(model.snapshot?.scopes.first?.servers.first?.name == "remote")
        #expect(model.error == nil)
    }

    @Test func aRefreshDuringALiveFlowKeepsTheHandleAndUpdatesRows() async {
        let model = McpServersModel()
        defer { model.signIn.attempt?.stopPolling() }
        for _ in 0..<2 {
            await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient(),
                                list: { response(flow: flow(.awaitingExternal)) })
        }
        let first = model.signIn.attempt
        await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient(),
                            list: { response(flow: flow(.awaitingExternal)) })
        #expect(model.signIn.attempt === first)
        #expect(model.snapshot != nil)
    }

    @Test func aFailedRefreshKeepsTheGoodSnapshotAndReportsTheError() async {
        let model = McpServersModel()
        await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient(),
                            list: { response(flow: nil) })
        let good = model.snapshot
        #expect(good != nil)
        await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient(),
                            list: { throw APIError.server(status: 503, message: "Try again") })
        #expect(model.snapshot == good)
        #expect(model.error != nil)
        #expect(!model.loading)
    }

    @Test func aDifferentHostNeverShowsTheOldHostsRows() async {
        let model = McpServersModel()
        await model.refresh(hostId: "a", hostName: "A", flowClient: IdleFlowClient(), list: { response(flow: nil) })
        await model.refresh(hostId: "b", hostName: "B", flowClient: IdleFlowClient(),
                            list: { throw APIError.server(status: 503, message: "Down") })
        #expect(model.snapshot == nil)
    }

    @Test func cancelledFlowKeepsAskingUntilTheHostSettlesWithoutAnError() async {
        let sleeps = Counter()
        let model = McpServersModel(sleep: { _ in await sleeps.increment() })
        let lists = Counter()
        await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient()) {
            let count = await lists.increment()
            return response(flow: count < 3 ? flow(.cancelled) : nil)
        }
        #expect(await lists.value == 3)
        #expect(await sleeps.value == 2)
        #expect(model.error == nil)
        #expect(!model.signIn.hasActive)
        #expect(!model.loading)
    }
}

private func flow(_ status: ProviderAuthFlowSnapshot.Status) -> McpAuthFlowSnapshot {
    McpAuthFlowSnapshot(
        flowId: "pa_mcp", scopeId: "global", serverName: "remote", launchMode: .phoneBrowser,
        status: status, auth: nil, error: nil, createdAt: 1, updatedAt: 2, expiresAt: 9
    )
}
private func response(flow: McpAuthFlowSnapshot?) -> McpServersResponse {
    let server = McpServerSummary(
        name: "remote", transport: "http", config: McpServerConfig(url: "https://example.test/mcp"),
        enabled: true, exposure: .codemode, state: "needs-auth", tools: [], toolExposure: nil,
        error: nil, supportsOAuth: true
    )
    return McpServersResponse(
        scopes: [McpScopeSnapshot(id: "global", title: "Global", kind: "global", hasConfig: true,
                                  trusted: true, servers: [server], errors: [], note: nil)],
        activeSignIn: flow
    )
}
private actor Counter {
    private(set) var value = 0
    @discardableResult func increment() -> Int { value += 1; return value }
}
private struct IdleFlowClient: ProviderAuthFlowClient {
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        try await Task.sleep(for: .seconds(3600))
        throw APIError.invalidResponse
    }
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot { throw APIError.invalidResponse }
    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot { throw APIError.invalidResponse }
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot { throw APIError.invalidResponse }
}
