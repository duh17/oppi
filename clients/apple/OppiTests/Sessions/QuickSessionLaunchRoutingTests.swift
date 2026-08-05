import Testing
@testable import Oppi

@Suite("Quick Session Launch Routing")
struct QuickSessionLaunchRoutingTests {
    @Test func plainPiAllowsEmptyPromptWithoutAutoSend() throws {
        let plan = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                agentId: nil,
                prompt: "   ",
                hasAttachments: false,
                hasRepoReferences: false
            )
        ).get()

        #expect(plan.mode == .plainPi)
        #expect(plan.workspaceId == "ws-1")
        #expect(plan.shouldAutoSend == false)
    }

    @Test func plainPiAutoSendsWhenPromptOrAttachmentsPresent() throws {
        let withPrompt = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                agentId: nil,
                prompt: "hello",
                hasAttachments: false,
                hasRepoReferences: false
            )
        ).get()
        #expect(withPrompt.shouldAutoSend)

        let withAttachment = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                agentId: nil,
                prompt: "",
                hasAttachments: true,
                hasRepoReferences: false
            )
        ).get()
        #expect(withAttachment.mode == .plainPi)
        #expect(withAttachment.shouldAutoSend)
    }

    @Test func missingWorkspaceFails() {
        let result = QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: nil,
                agentId: nil,
                prompt: "hi",
                hasAttachments: false,
                hasRepoReferences: false
            )
        )
        #expect(result == .failure(.missingWorkspace))
    }

    @Test func agentRequiresNonEmptyPrompt() {
        let result = QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                agentId: "reviewer",
                prompt: "  ",
                hasAttachments: false,
                hasRepoReferences: false
            )
        )
        #expect(result == .failure(.agentRequiresPrompt))
    }

    @Test func agentRejectsAttachmentsAndRepoReferences() {
        #expect(
            QuickSessionLaunchRouting.plan(
                for: .init(
                    workspaceId: "ws-1",
                    agentId: "reviewer",
                    prompt: "Review this",
                    hasAttachments: true,
                    hasRepoReferences: false
                )
            ) == .failure(.agentAttachmentsUnsupported)
        )
        #expect(
            QuickSessionLaunchRouting.plan(
                for: .init(
                    workspaceId: "ws-1",
                    agentId: "reviewer",
                    prompt: "Review this",
                    hasAttachments: false,
                    hasRepoReferences: true
                )
            ) == .failure(.agentAttachmentsUnsupported)
        )
    }

    @Test func agentLaunchDoesNotAutoSend() throws {
        let plan = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                agentId: "reviewer",
                prompt: "Review this",
                hasAttachments: false,
                hasRepoReferences: false
            )
        ).get()

        #expect(plan.mode == .agent(agentId: "reviewer"))
        #expect(plan.prompt == "Review this")
        #expect(plan.shouldAutoSend == false)
    }

    @Test(arguments: [
        (Optional<String>.none, ["a", "b"], Optional<String>.none),
        ("missing", ["a", "b"], nil),
        ("a", ["a", "b"], "a"),
        ("", ["a"], nil),
    ])
    func preferredAgentId(
        lastAgentId: String?,
        available: [String],
        expected: String?
    ) {
        #expect(
            QuickSessionLaunchRouting.preferredAgentId(
                lastAgentId: lastAgentId,
                availableAgentIds: available
            ) == expected
        )
    }
}
