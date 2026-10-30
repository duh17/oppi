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
        #expect(model.snapshot?.scope.servers.first?.name == "remote")
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

    /// The host menu and the iPad sidebar make another server the active one
    /// before its client is ready. From the switch until that host's own list
    /// arrives, the screen reads rows through `snapshot(forHost:)`: the old
    /// host's rows are gone at once and never show under the new host.
    @Test func aSwitchedHostShowsNoRowsUntilItsOwnListArrives() async {
        let model = McpServersModel()
        await model.refresh(hostId: "a", hostName: "A", flowClient: IdleFlowClient(), list: { response(flow: nil) })
        #expect(model.snapshot(forHost: "a")?.scope.servers.first?.name == "remote")
        #expect(model.snapshot(forHost: "b") == nil)

        model.switchHost(to: "b")
        #expect(model.snapshot(forHost: "a") == nil)
        #expect(model.snapshot(forHost: "b") == nil)
        #expect(model.error == nil)
        #expect(!model.loading)

        await model.refresh(hostId: "b", hostName: "B", flowClient: IdleFlowClient(), list: { response(flow: nil) })
        #expect(model.snapshot(forHost: "b")?.scope.servers.first?.name == "remote")
        #expect(model.snapshot(forHost: "a") == nil)
    }

    @Test func aProbeStillInFlightForTheOldHostNeverLandsUnderTheNewOne() async {
        let model = McpServersModel()
        let gate = Gate()
        let probe = Task { @MainActor in
            await model.refresh(hostId: "a", hostName: "A", flowClient: IdleFlowClient()) {
                await gate.wait()
                return response(flow: nil)
            }
        }
        await gate.waitUntilWaiting()
        #expect(model.loading)

        model.switchHost(to: "b")
        #expect(!model.loading)
        await gate.open()
        await probe.value

        #expect(model.snapshot(forHost: "a") == nil)
        #expect(model.snapshot(forHost: "b") == nil)
        #expect(model.snapshot == nil)
        #expect(!model.loading)
        #expect(model.error == nil)
    }

    /// A probe the page cancels (it left the screen) is control flow, not a
    /// failure: the list shows no error row and no Retry for it when it comes
    /// back, and it keeps whatever it had.
    @Test func aCancelledProbeLeavesNoErrorBehind() async {
        let model = McpServersModel()
        await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient()) {
            response(flow: nil)
        }
        let good = model.snapshot

        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let probe = Task { @MainActor in
            await model.refresh(hostId: "host", hostName: "Studio", flowClient: IdleFlowClient()) {
                startedContinuation.yield()
                try await Task.sleep(for: .seconds(30))
                return response(flow: nil)
            }
        }
        for await _ in started { break }
        probe.cancel()
        _ = await probe.result

        #expect(model.error == nil, "a cancelled probe is not a failure to show")
        #expect(model.snapshot == good, "the list keeps what it had")
        #expect(!model.loading)
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
        scope: McpScopeSnapshot(id: "global", title: "Global", kind: "global", projectTrust: nil,
                                servers: [server], inherited: nil, errors: []),
        activeSignIn: flow
    )
}
/// Holds a probe until the test lets it answer.
private actor Gate {
    private var isOpen = false
    private var isWaiting = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        await withCheckedContinuation { waiter = $0 }
    }

    /// Returns once a probe is parked in `wait()`.
    func waitUntilWaiting() async {
        while !isWaiting { await Task.yield() }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
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
