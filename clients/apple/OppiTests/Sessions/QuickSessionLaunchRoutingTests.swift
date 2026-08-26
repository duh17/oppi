import Foundation
import Testing
@testable import Oppi

@Suite("Quick Session Prompt Template Slash Commands")
struct QuickSessionPromptTemplateSlashCommandTests {
    @Test func mapsCommandNameDescriptionAndPromptSource() {
        let options = [
            WorkspaceQuickActionOption(
                id: "prompt:review",
                title: "Review",
                commandName: "review",
                description: "Review the current workspace",
                argumentHint: nil,
                source: .prompt,
                sourceScope: "project",
                promptTemplateName: "review"
            )
        ]

        #expect(SlashCommand.promptTemplates(from: options) == [
            SlashCommand(
                name: "review",
                description: "Review the current workspace",
                source: .prompt
            )
        ])
    }

    @Test func emptyOptionsProduceNoCommands() {
        #expect(SlashCommand.promptTemplates(from: []).isEmpty)
    }
}

@Suite("Quick Session Skill Slash Commands")
struct QuickSessionSkillSlashCommandTests {
    @Test func mapsEnabledSkillsWithSkillSourceAndOptionalDescription() {
        let skills = [
            SkillInfo(
                name: "deep-research",
                description: "Research with source-backed evidence",
                path: "/skills/deep-research",
                enabled: true
            ),
            SkillInfo(
                name: "writing",
                description: "",
                path: "/skills/writing",
                enabled: true
            ),
        ]

        #expect(SlashCommand.skills(from: skills) == [
            SlashCommand(
                name: "skill:deep-research",
                description: "Research with source-backed evidence",
                source: .skill
            ),
            SlashCommand(
                name: "skill:writing",
                description: nil,
                source: .skill
            ),
        ])
    }

    @Test func omitsDisabledSkills() {
        let skills = [
            SkillInfo(
                name: "disabled-skill",
                description: "Not available in this workspace",
                path: "/skills/disabled-skill",
                enabled: false
            )
        ]

        #expect(SlashCommand.skills(from: skills).isEmpty)
    }

    @Test func emptySkillsProduceNoCommands() {
        #expect(SlashCommand.skills(from: []).isEmpty)
    }
}

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
        #expect(plan.worktreeId == WorkspaceWorktree.mainId)
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
        #expect(withAttachment.worktreeId == WorkspaceWorktree.mainId)
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

    @Test func agentAllowsAttachmentsAndRepoReferences() throws {
        let withAttachment = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                agentId: "reviewer",
                prompt: "Review this",
                hasAttachments: true,
                hasRepoReferences: false
            )
        ).get()
        let withReference = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                agentId: "reviewer",
                prompt: "Review this",
                hasAttachments: false,
                hasRepoReferences: true
            )
        ).get()

        #expect(withAttachment.mode == .agent(agentId: "reviewer"))
        #expect(withAttachment.shouldAutoSend)
        #expect(withReference.mode == .agent(agentId: "reviewer"))
        #expect(withReference.shouldAutoSend)
    }

    @Test func agentLaunchAutoSendsThroughChat() throws {
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
        #expect(plan.workspaceId == "ws-1")
        #expect(plan.worktreeId == WorkspaceWorktree.mainId)
        #expect(plan.prompt == "Review this")
        #expect(plan.shouldAutoSend)
    }

    @Test func preservesExplicitWorktreeOnPlainPiAndAgentLaunch() throws {
        let plain = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                worktreeId: "wt_feature",
                agentId: nil,
                prompt: "hello",
                hasAttachments: false,
                hasRepoReferences: false
            )
        ).get()
        let agent = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                worktreeId: "  wt_feature  ",
                agentId: "reviewer",
                prompt: "Review this",
                hasAttachments: false,
                hasRepoReferences: false
            )
        ).get()

        #expect(plain.mode == .plainPi)
        #expect(plain.worktreeId == "wt_feature")
        #expect(agent.mode == .agent(agentId: "reviewer"))
        #expect(agent.worktreeId == "wt_feature")
    }

    @Test func blankWorktreeIdResolvesToMain() throws {
        let plan = try QuickSessionLaunchRouting.plan(
            for: .init(
                workspaceId: "ws-1",
                worktreeId: "   ",
                agentId: nil,
                prompt: "hello",
                hasAttachments: false,
                hasRepoReferences: false
            )
        ).get()

        #expect(plan.worktreeId == WorkspaceWorktree.mainId)
    }

    @Test func filtersWorkspacesUsingAgentConstraints() {
        let host = Workspace(
            id: "host",
            name: "Host",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var sandbox = Workspace(
            id: "research",
            name: "Research",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        sandbox.runtime = .sandbox
        let constraints = AgentLaunchConstraints(
            allowedWorkspaceIds: ["research"],
            requiredRuntime: .sandbox
        )

        #expect(
            QuickSessionLaunchRouting.compatibleWorkspaces(
                for: constraints,
                in: [host, sandbox]
            ).map(\.id) == ["research"]
        )
    }

    @Test func rejectedOrUndeliveredAgentLaunchNeverNavigates() {
        let rejected = AgentSessionLaunchResponse(
            receipt: AgentLaunchReceipt(
                accepted: false,
                promptDispatch: "not_sent"
            ),
            session: nil
        )
        #expect(!QuickSessionLaunchRouting.canNavigateAfterAgentLaunch(rejected))
    }

    @Test func acceptedButUndeliveredAgentLaunchWithSessionNeverNavigates() throws {
        let response = try JSONDecoder().decode(
            AgentSessionLaunchResponse.self,
            from: Data("""
            {
              "receipt":{"accepted":true,"promptDispatch":"not_sent"},
              "session":{
                "id":"failed-1","status":"error","createdAt":1,"lastActivity":1,
                "messageCount":0,
                "tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                "cost":0
              }
            }
            """.utf8)
        )

        #expect(response.session != nil)
        #expect(!QuickSessionLaunchRouting.canNavigateAfterAgentLaunch(response))
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

@Suite("Quick Session worktree picker policy")
struct QuickSessionWorktreePickerPolicyTests {
    @Test(arguments: [
        (0, false),
        (1, false),
        (2, true),
        (3, true),
    ])
    func showsPickerOnlyWhenMultipleWorktreesExist(count: Int, expected: Bool) {
        #expect(QuickSessionWorktreePickerPolicy.shouldShowPicker(worktreeCount: count) == expected)
    }

    @Test func keepsSelectedWorktreeWhenItStillExists() {
        let worktrees = [
            makeWorktree(id: "main", isMain: true),
            makeWorktree(id: "wt_feature", isMain: false),
        ]

        #expect(
            QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                selectedId: "wt_feature",
                worktrees: worktrees
            ) == "wt_feature"
        )
    }

    @Test func fallsBackToMainWhenSelectionIsMissing() {
        let worktrees = [
            makeWorktree(id: "wt_feature", isMain: false),
            makeWorktree(id: "main", isMain: true),
        ]

        #expect(
            QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                selectedId: "gone",
                worktrees: worktrees
            ) == "main"
        )
        #expect(
            QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                selectedId: nil,
                worktrees: worktrees
            ) == "main"
        )
    }

    @Test func fallsBackToFirstWorktreeWhenMainIsAbsent() {
        let worktrees = [
            makeWorktree(id: "wt_one", isMain: false),
            makeWorktree(id: "wt_two", isMain: false),
        ]

        #expect(
            QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                selectedId: nil,
                worktrees: worktrees
            ) == "wt_one"
        )
    }

    @Test func usesImplicitMainWhenTheWorkspaceHasNoWorktrees() {
        #expect(
            QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                selectedId: "wt_feature",
                worktrees: []
            ) == WorkspaceWorktree.mainId
        )
    }

    @Test(arguments: [
        (Optional<String>.none, WorkspaceWorktree.mainId),
        (Optional(""), WorkspaceWorktree.mainId),
        (Optional("   "), WorkspaceWorktree.mainId),
        (Optional("wt_feature"), "wt_feature"),
        (Optional("  wt_feature  "), "wt_feature"),
    ])
    func normalizesLaunchWorktreeId(_ worktreeId: String?, expected: String) {
        #expect(QuickSessionWorktreePickerPolicy.normalizedLaunchWorktreeId(worktreeId) == expected)
    }

    private func makeWorktree(id: String, isMain: Bool) -> WorkspaceWorktree {
        WorkspaceWorktree(
            id: id,
            name: id,
            path: "/tmp/\(id)",
            branch: isMain ? "main" : id,
            headSha: nil,
            isMain: isMain,
            isGitRepo: true,
            sessionCount: nil
        )
    }
}

@Suite("New session model presentation")
struct NewSessionModelPresentationTests {
    private let sonnet = ModelInfo(
        id: "anthropic/claude-sonnet-4-0",
        name: "Sonnet",
        provider: "anthropic",
        contextWindow: 200_000,
        isDefault: true
    )
    private let opus = ModelInfo(
        id: "anthropic/claude-opus-4-0",
        name: "Opus",
        provider: "anthropic",
        contextWindow: 200_000
    )

    @Test func inheritedCatalogDefaultIsDisplayOnly() {
        let presentation = NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: nil,
            isAgent: false,
            catalogModels: [opus, sonnet]
        )

        #expect(presentation.requestModelId == nil)
        #expect(presentation.pillText == sonnet.id)
        #expect(presentation.pillText != sonnet.name)
        #expect(shortModelName(presentation.pillText) == "sonnet-4-0")
        #expect(presentation.pillProvider == "anthropic")
        #expect(presentation.pillText != "default")
        #expect(
            NewSessionModelOverride(explicitlySelectedModelId: presentation.requestModelId)
                .requestModelId == nil
        )
    }

    @Test func inheritedCatalogDefaultUsesModelIdNotPrettyName() {
        let grok = ModelInfo(
            id: "xai/grok-4.6",
            name: "Grok 4.6",
            provider: "xai",
            contextWindow: 256_000,
            isDefault: true
        )
        let presentation = NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: nil,
            isAgent: false,
            catalogModels: [grok]
        )

        #expect(presentation.requestModelId == nil)
        #expect(presentation.pillText == grok.id)
        #expect(presentation.pillText != grok.name)
        #expect(shortModelName(presentation.pillText) == "grok-4.6")
        #expect(presentation.pillProvider == "xai")
        #expect(providerFromModel(presentation.pillText) == "xai")
    }

    @Test func pendingCatalogUsesModelNotDefault() {
        let presentation = NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: nil,
            isAgent: false,
            catalogModels: []
        )

        #expect(presentation.requestModelId == nil)
        #expect(presentation.pillText == "Model")
        #expect(presentation.pillProvider == nil)
        #expect(presentation.pillText != "default")
    }

    @Test func agentWithoutPickUsesAgentLabelNotCatalogStar() {
        let presentation = NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: nil,
            isAgent: true,
            catalogModels: [sonnet]
        )

        #expect(presentation.requestModelId == nil)
        #expect(presentation.pillText == "Agent")
        #expect(presentation.pillProvider == nil)
    }

    @Test func explicitPickIsRequestAndPill() {
        let presentation = NewSessionModelPresentation.resolve(
            explicitlySelectedModelId: opus.id,
            isAgent: false,
            catalogModels: [opus, sonnet]
        )

        #expect(presentation.requestModelId == opus.id)
        #expect(presentation.pillText == opus.id)
        #expect(presentation.pillText != opus.name)
        #expect(shortModelName(presentation.pillText) == "opus-4-0")
        #expect(presentation.pillProvider == "anthropic")
    }
}
