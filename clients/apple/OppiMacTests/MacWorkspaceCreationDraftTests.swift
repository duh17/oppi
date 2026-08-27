import Testing
@testable import Oppi

@Suite("Mac workspace creation draft")
struct MacWorkspaceCreationDraftTests {
    @Test func requiresWorkspaceName() {
        let draft = MacWorkspaceCreationDraft(name: "  ", hostMount: "/tmp/oppi")

        #expect(!draft.canSubmit)
        #expect(draft.validationMessage == "Workspace name is required.")
        #expect(draft.request == nil)
    }

    @Test func trimsOptionalFieldsIntoCreateRequest() throws {
        let draft = MacWorkspaceCreationDraft(
            name: "  Oppi  ",
            hostMount: "  /Users/chenda/workspace/oppi  ",
            description: "  Main repo  ",
            gitStatusEnabled: false,
            runtime: .host
        )

        let request = try #require(draft.request)
        #expect(request.name == "Oppi")
        #expect(request.hostMount == "/Users/chenda/workspace/oppi")
        #expect(request.description == "Main repo")
        #expect(request.gitStatusEnabled == false)
        #expect(request.runtime == .host)
    }

    @Test func emptyOptionalFieldsBecomeNil() throws {
        let draft = MacWorkspaceCreationDraft(name: "Scratch", hostMount: " ", description: " ")

        let request = try #require(draft.request)
        #expect(request.name == "Scratch")
        #expect(request.hostMount == nil)
        #expect(request.description == nil)
    }

    @Test func initializesFromWorkspaceForEditing() {
        let workspace = Workspace(
            id: "ws-1",
            name: "Oppi",
            description: "Main repo",
            icon: .defaultValue,
            systemPrompt: nil,
            hostMount: "/Users/chenda/workspace/oppi",
            tools: nil,
            gitStatusEnabled: false,
            runtime: .host,
            sandboxConfig: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let draft = MacWorkspaceCreationDraft(workspace: workspace)

        #expect(draft.name == "Oppi")
        #expect(draft.hostMount == "/Users/chenda/workspace/oppi")
        #expect(draft.description == "Main repo")
        #expect(draft.gitStatusEnabled == false)
    }

    @Test func updateRequestUsesNullForClearedOptionalFields() throws {
        let draft = MacWorkspaceCreationDraft(name: " Renamed ", hostMount: " ", description: " ")

        let request = try #require(draft.updateRequest)
        #expect(request.body["name"] == .string("Renamed"))
        #expect(request.body["hostMount"] == .null)
        #expect(request.body["description"] == .null)
    }
}
