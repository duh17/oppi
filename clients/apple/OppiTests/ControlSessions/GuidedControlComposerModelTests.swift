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

    /// Runs `body` with the last-used workspace preference set, then restores it.
    private func withLastUsedWorkspace(_ id: String, _ body: () async throws -> Void) async rethrows {
        let key = "\(AppIdentifiers.subsystem).quickSession.lastWorkspaceId"
        let previous = UserDefaults.standard.object(forKey: key)
        AppPreferences.QuickSession.saveWorkspaceId(id)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try await body()
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

    @Test func agentsComposerLaunchNamesTheSelectedWorkspace() async throws {
        try await withLastUsedWorkspace("w2") {
            let connection = makeConnection(workspaces: [
                makeTestWorkspace(id: "w1", name: "First"),
                makeTestWorkspace(id: "w2", name: "Second"),
            ])
            let model = makeModel(domain: .agents, connection: connection)
            try await appear(model)

            let prompt = model.makeLaunch(cleanRequest: "A reviewer").request.prompt ?? ""
            #expect(prompt.contains("Canonical workspace ID: w2"))
            #expect(prompt.contains("Canonical workspace name: Second"))
        }
    }

    @Test func themesComposerSendsNoWorkspaceEvenWhenOneIsPreferred() async throws {
        try await withLastUsedWorkspace("w2") {
            let connection = makeConnection(workspaces: [
                makeTestWorkspace(id: "w1", name: "First"),
                makeTestWorkspace(id: "w2", name: "Second"),
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
}
