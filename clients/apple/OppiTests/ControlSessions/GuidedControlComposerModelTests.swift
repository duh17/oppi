import Foundation
import Testing
@testable import Oppi

@Suite("Guided control composer workspace context", .serialized)
@MainActor
struct GuidedControlComposerModelTests {
    private func makeModel(
        domain: ControlSessionDomain,
        connection: ServerConnection
    ) -> GuidedControlComposerModel {
        GuidedControlComposerModel(
            configuration: GuidedControlComposerConfiguration(
                domain: domain,
                intent: .create,
                placeholder: "Describe it…"
            ),
            connection: { connection },
            navigation: AppNavigation()
        )
    }

    private func makeConnection(workspaces: [Workspace]) async -> ServerConnection {
        let connection = ServerConnection()
        _ = await configureTestConnection(connection, credentials: makeTestCredentials())
        connection.workspaceStore.workspaces = workspaces
        return connection
    }

    /// Runs the composer's real setup and waits for it.
    private func appear(_ model: GuidedControlComposerModel) async throws {
        model.appear()
        let ready = await waitForMainActorCondition(timeout: .seconds(20)) { model.isInitialized }
        try #require(ready)
        model.disappear()
    }

    @Test(arguments: [
        ControlSessionDomain.agents, .extensions, .schedules, .skills, .themes, .workspaces,
    ])
    func workspacePillShowsOnlyForAgentsAndSchedulesWithAServerWorkspace(domain: ControlSessionDomain) async {
        let withWorkspace = makeModel(domain: domain, connection: await makeConnection(workspaces: [makeTestWorkspace()]))
        let withoutWorkspace = makeModel(domain: domain, connection: await makeConnection(workspaces: []))
        let takesWorkspace = domain == .agents || domain == .schedules

        #expect(withWorkspace.showsWorkspacePicker == takesWorkspace)
        #expect(!withoutWorkspace.showsWorkspacePicker)
    }

    @Test func agentsComposerWithNoSelectedWorkspaceStillAcceptsInputAndLaunchesWithoutWorkspace() async throws {
        let connection = await makeConnection(workspaces: [])
        let model = makeModel(domain: .agents, connection: connection)
        try await appear(model)
        // Workspaces arrive after setup: the pill appears, nothing is selected.
        connection.workspaceStore.workspaces = [makeTestWorkspace(id: "w1", name: "Oppi")]

        #expect(model.selectedWorkspace == nil)
        #expect(model.showsWorkspacePicker)
        #expect(model.acceptsInput)
        let prompt = model.makeLaunch(cleanRequest: "A careful reviewer").request.prompt ?? ""
        #expect(prompt.contains("User request:\nA careful reviewer"))
        #expect(!prompt.contains("Canonical workspace"))
    }

    @Test func agentsComposerLaunchNamesItsWorkspace() async throws {
        // No shared preference: other suites write the last-used workspace key, so this
        // test relies only on the first-workspace fallback, with IDs no other suite uses.
        let connection = await makeConnection(workspaces: [
            makeTestWorkspace(id: "composer-only-ws", name: "Composer Only"),
        ])
        let model = makeModel(domain: .agents, connection: connection)
        try await appear(model)

        let prompt = model.makeLaunch(cleanRequest: "A reviewer").request.prompt ?? ""
        #expect(prompt.contains("Canonical workspace ID: composer-only-ws"))
        #expect(prompt.contains("Canonical workspace name: Composer Only"))
    }

    @Test func themesComposerSendsNoWorkspaceEvenWithServerWorkspaces() async throws {
        let connection = await makeConnection(workspaces: [
            makeTestWorkspace(id: "composer-only-ws", name: "Composer Only"),
        ])
        let model = makeModel(domain: .themes, connection: connection)
        try await appear(model)

        #expect(model.acceptsInput)
        #expect(model.selectedWorkspace == nil)
        #expect(!model.showsWorkspacePicker)
        let prompt = model.makeLaunch(cleanRequest: "A warm dark theme").request.prompt ?? ""
        #expect(!prompt.contains("Canonical workspace"))
    }
}

@Suite("Guided control composer connection words", .serialized)
@MainActor
struct GuidedControlComposerConnectionWordsTests {    private func placeholder(connection: ServerConnection) -> String {
        GuidedControlComposerModel(
            configuration: GuidedControlComposerConfiguration(
                domain: .themes,
                intent: .create,
                placeholder: "Describe a new theme…"
            ),
            connection: { connection },
            navigation: AppNavigation()
        ).placeholder
    }

    @Test func aRebuildingRouteSaysItIsReconnectingNotConnectToUseSetup() async {
        let connection = ServerConnection()
        _ = await configureTestConnection(connection)
        // A rebuild holds between its teardown and its commit: the client is gone
        // while a replacement is on its way.
        let gate = RebuildGate()
        let rebuild = Task { [credentials = makeTestCredentials()] in
            await connection.route.reconfigureForExplicitRetry(
                credentials: credentials,
                apiClientFactory: { _, _ in makeTestURLProtocolClient(host: credentials.host) },
                serverInfoBootstrap: { _, _ in
                    await gate.wait()
                    return makeTestServerInfo()
                }
            )
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            connection.apiClient == nil && connection.route.isTransportDemoting
        })
        #expect(connection.availability == .reconnecting)
        #expect(placeholder(connection: connection) == "Reconnecting to the server…")
        gate.open()
        _ = await rebuild.value
    }

    @Test func aRebuildThatFailedWithNothingPendingAsksThePersonToConnect() async {
        let connection = ServerConnection()
        _ = await configureTestConnection(connection)
        // A rebuild that ends on an answer waiting does not clear: nothing retries
        // it but the next foreground or path boundary, so the bar promises no
        // attempt of its own.
        let credentials = makeTestCredentials()
        _ = await connection.route.configureForUse(
            credentials: credentials,
            apiClientFactory: { _, _ in makeTestURLProtocolClient(host: credentials.host) },
            serverInfoBootstrap: { _, _ in throw APIError.server(status: 401, message: "refused") }
        )
        await connection.route.reevaluateNetworkEndpointAtBoundary()
        #expect(connection.apiClient == nil)
        #expect(connection.availability == .offline)
        #expect(placeholder(connection: connection) == "Connect to use guided theme setup")
    }

    @Test func aConnectionWithNoServerAsksThePersonToConnect() {
        let connection = ServerConnection()
        #expect(connection.availability == .offline)
        #expect(placeholder(connection: connection) == "Connect to use guided theme setup")
    }
}

/// A rebuild's bootstrap, held open until the test lets it answer.
@MainActor
private final class RebuildGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
