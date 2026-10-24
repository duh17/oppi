import Testing
@testable import Oppi

@Suite("Guided control composer workspace context")
@MainActor
struct GuidedControlComposerModelTests {
    private func makeModel(domain: ControlSessionDomain, workspaces: [Workspace]) -> GuidedControlComposerModel {
        let connection = ServerConnection()
        connection.workspaceStore.workspaces = workspaces
        return GuidedControlComposerModel(
            configuration: GuidedControlComposerConfiguration(
                domain: domain,
                intent: .create,
                placeholder: "Describe it…"
            ),
            connection: { connection },
            navigation: AppNavigation()
        )
    }

    @Test(arguments: [
        ControlSessionDomain.agents, .extensions, .schedules, .skills, .themes, .workspaces,
    ])
    func workspacePillShowsOnlyForAgentsAndSchedulesWithAServerWorkspace(domain: ControlSessionDomain) {
        let withWorkspace = makeModel(domain: domain, workspaces: [makeTestWorkspace()])
        let withoutWorkspace = makeModel(domain: domain, workspaces: [])
        let takesWorkspace = domain == .agents || domain == .schedules

        #expect(withWorkspace.showsWorkspacePicker == takesWorkspace)
        #expect(!withoutWorkspace.showsWorkspacePicker)
    }

    @Test func placeholderNeverAsksForAWorkspace() {
        let model = makeModel(domain: .agents, workspaces: [makeTestWorkspace()])

        #expect(!model.placeholder.contains("workspace"))
    }
}
