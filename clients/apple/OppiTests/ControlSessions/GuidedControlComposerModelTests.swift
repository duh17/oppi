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

    private func makeConnection(workspaces: [Workspace]) -> ServerConnection {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials())
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
    func workspacePillShowsOnlyForAgentsAndSchedulesWithAServerWorkspace(domain: ControlSessionDomain) {
        let withWorkspace = makeModel(domain: domain, connection: makeConnection(workspaces: [makeTestWorkspace()]))
        let withoutWorkspace = makeModel(domain: domain, connection: makeConnection(workspaces: []))
        let takesWorkspace = domain == .agents || domain == .schedules

        #expect(withWorkspace.showsWorkspacePicker == takesWorkspace)
        #expect(!withoutWorkspace.showsWorkspacePicker)
    }

    @Test func agentsComposerWithNoSelectedWorkspaceStillAcceptsInputAndLaunchesWithoutWorkspace() async throws {
        let connection = makeConnection(workspaces: [])
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
        let connection = makeConnection(workspaces: [
            makeTestWorkspace(id: "composer-only-ws", name: "Composer Only"),
        ])
        let model = makeModel(domain: .agents, connection: connection)
        try await appear(model)

        let prompt = model.makeLaunch(cleanRequest: "A reviewer").request.prompt ?? ""
        #expect(prompt.contains("Canonical workspace ID: composer-only-ws"))
        #expect(prompt.contains("Canonical workspace name: Composer Only"))
    }

    @Test func themesComposerSendsNoWorkspaceEvenWithServerWorkspaces() async throws {
        let connection = makeConnection(workspaces: [
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
