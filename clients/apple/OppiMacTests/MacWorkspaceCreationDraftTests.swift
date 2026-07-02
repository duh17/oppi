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
            defaultModel: "  anthropic/claude-sonnet-4-5  ",
            gitStatusEnabled: false,
            runtime: .host
        )

        let request = try #require(draft.request)
        #expect(request.name == "Oppi")
        #expect(request.hostMount == "/Users/chenda/workspace/oppi")
        #expect(request.description == "Main repo")
        #expect(request.defaultModel == "anthropic/claude-sonnet-4-5")
        #expect(request.gitStatusEnabled == false)
        #expect(request.runtime == .host)
    }

    @Test func emptyOptionalFieldsBecomeNil() throws {
        let draft = MacWorkspaceCreationDraft(name: "Scratch", hostMount: " ", description: " ")

        let request = try #require(draft.request)
        #expect(request.name == "Scratch")
        #expect(request.hostMount == nil)
        #expect(request.description == nil)
        #expect(request.defaultModel == nil)
    }

    @Test func initializesFromWorkspaceForEditing() {
        let workspace = Workspace(
            id: "ws-1",
            name: "Oppi",
            description: "Main repo",
            icon: nil,
            systemPrompt: nil,
            hostMount: "/Users/chenda/workspace/oppi",
            defaultModel: "openai/gpt-5.5",
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
        #expect(draft.defaultModel == "openai/gpt-5.5")
        #expect(draft.gitStatusEnabled == false)
    }

    @Test func updateRequestUsesNullForClearedOptionalFields() throws {
        let draft = MacWorkspaceCreationDraft(name: " Renamed ", hostMount: " ", description: " ")

        let request = try #require(draft.updateRequest)
        #expect(request.body["name"] == .string("Renamed"))
        #expect(request.body["hostMount"] == .null)
        #expect(request.body["description"] == .null)
        #expect(request.body["defaultModel"] == .null)
    }

    @Test func updateRequestTrimsDefaultModel() throws {
        let draft = MacWorkspaceCreationDraft(
            name: "Workspace",
            defaultModel: "  openai/gpt-5.5  "
        )

        let request = try #require(draft.updateRequest)
        #expect(request.body["defaultModel"] == .string("openai/gpt-5.5"))
    }
}
