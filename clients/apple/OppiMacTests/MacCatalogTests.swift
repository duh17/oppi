import Foundation
import Testing
@testable import Oppi

@Suite("Mac catalog presentation")
struct MacCatalogPresentationTests {
    @Test func agentsLeadWithPiThenSavedMatches() {
        let rows = MacCatalogAgentListPresentation(
            agents: [
                agent(id: "b", name: "Beta"),
                agent(id: "a", name: "Alpha", description: "Research scout"),
            ],
            query: ""
        ).rows

        #expect(rows.map(\.id) == ["pi", "a", "b"])
        #expect(rows.first == .pi)
        #expect(MacCatalogAgentListPresentation.emptyMessage.contains("not wired") == false)
    }

    @Test func agentSearchMatchesNameAndDescriptionAndHidesPiWhenUnrelated() {
        let presentation = MacCatalogAgentListPresentation(
            agents: [
                agent(id: "a", name: "Alpha", description: "Research scout"),
                agent(id: "b", name: "Beta"),
            ],
            query: "scout"
        )

        #expect(presentation.rows.map(\.id) == ["a"])
        #expect(presentation.isFilteredNoResults == false)

        let none = MacCatalogAgentListPresentation(
            agents: [agent(id: "a", name: "Alpha")],
            query: "missing"
        )
        #expect(none.rows.isEmpty)
        #expect(none.isFilteredNoResults)
        #expect(none.emptyMessage.contains("not wired") == false)
    }

    @Test func schedulesFilterByStatusAndQueryWithoutStubCopy() {
        let active = schedule(id: "s1", name: "Morning brief", status: .active)
        let paused = schedule(id: "s2", name: "Nightly review", status: .paused)
        let presentation = MacCatalogScheduleListPresentation(
            schedules: [active, paused],
            status: .active,
            query: "brief"
        )

        #expect(presentation.rows.map(\.id) == ["s1"])
        #expect(MacCatalogScheduleListPresentation.emptyMessage(for: .active).contains("will appear here") == false)

        let emptyPaused = MacCatalogScheduleListPresentation(schedules: [active], status: .paused, query: "")
        #expect(emptyPaused.rows.isEmpty)
        #expect(emptyPaused.isEmpty)
    }

    @Test func scheduleFilterKeepsCurrentIDWhenStillInTheNewFilter() {
        let alpha = schedule(id: "alpha", name: "Alpha", status: .active)
        let beta = schedule(id: "beta", name: "Beta", status: .active)
        let nightly = schedule(id: "night", name: "Nightly", status: .paused)
        let rows = [alpha, beta, nightly]

        let active = MacCatalogScheduleListPresentation(schedules: rows, status: .active, query: "")
        #expect(active.selectedID(keeping: "beta") == "beta")
        #expect(active.selectedID(keeping: "night") == "alpha")

        let paused = MacCatalogScheduleListPresentation(schedules: rows, status: .paused, query: "")
        #expect(paused.selectedID(keeping: "beta") == "night")
        #expect(paused.selectedID(keeping: "night") == "night")

        let archived = MacCatalogScheduleListPresentation(schedules: rows, status: .archived, query: "")
        #expect(archived.selectedID(keeping: "beta") == nil)
    }

    @Test func clearingAgentDraftDescriptionAndInstructionsProducesNils() {
        let existing = AgentDefinition(
            name: "Scout",
            description: "Old",
            instructions: AgentInstructions(mode: .append, text: "Be brief"),
            resources: AgentResources(skillPaths: ["review"])
        )
        let draft = MacAgentEditorDraft(
            name: "Scout",
            description: "  ",
            instructionMode: .append,
            instructionText: ""
        )

        let definition = draft.makeDefinition(preserving: existing)
        #expect(definition.description == nil)
        #expect(definition.instructions == nil)
        #expect(definition.resources?.skillPaths == ["review"])
    }

    @Test func skillsGroupNeedsAttentionEnabledAndDisabled() {
        let rows = [
            skill(id: "disabled-z", name: "Zulu", state: .disabled),
            skill(id: "enabled-z", name: "Zulu", state: .enabled),
            skill(id: "error", name: "Broken", state: .error, loadError: "Invalid frontmatter"),
            skill(id: "enabled-a", name: "Alpha", state: .enabled),
        ]
        let presentation = MacCatalogSkillListPresentation(skills: rows, query: "")

        #expect(presentation.sections.map(\.title) == ["Needs Attention", "Enabled", "Disabled"])
        #expect(presentation.sections[0].items.map(\.id) == ["error"])
        #expect(presentation.sections[1].items.map(\.id) == ["enabled-a", "enabled-z"])
        #expect(presentation.sections[2].items.map(\.id) == ["disabled-z"])
        #expect(MacCatalogSkillListPresentation.emptyMessage.contains("local server here") == false)
    }

    @Test func skillSearchMatchesNameDescriptionProvenanceAndState() {
        let rows = [
            skill(id: "release", name: "Release", description: "Checks shipping readiness", state: .enabled),
            skill(id: "reddit", name: "Reddit", provenance: "~/.agents/skills", state: .disabled),
        ]

        #expect(MacCatalogSkillListPresentation(skills: rows, query: "shipping").visible.map(\.id) == ["release"])
        #expect(MacCatalogSkillListPresentation(skills: rows, query: ".agents").visible.map(\.id) == ["reddit"])
        #expect(MacCatalogSkillListPresentation(skills: rows, query: "disabled").visible.map(\.id) == ["reddit"])
    }

    @Test func extensionsGroupBuiltInAttentionEnabledAndDisabled() {
        let rows = [
            ext(id: "off", name: "Off Ext", kind: .file, state: .off),
            ext(id: "on-b", name: "Bravo", kind: .directory, state: .on),
            ext(id: "broken", name: "Broken", kind: .file, state: .error),
            ext(id: "read", name: "Read", kind: .builtIn, state: .on),
            ext(id: "on-a", name: "Alpha", kind: .file, state: .on),
        ]
        let presentation = MacCatalogExtensionListPresentation(extensions: rows, query: "")

        #expect(presentation.sections.map(\.title) == [
            "Built-in",
            "Needs Attention",
            "Enabled Pi Extensions",
            "Disabled Pi Extensions",
        ])
        #expect(presentation.sections[0].items.map(\.id) == ["read"])
        #expect(presentation.sections[1].items.map(\.id) == ["broken"])
        #expect(presentation.sections[2].items.map(\.id) == ["on-a", "on-b"])
        #expect(presentation.sections[3].items.map(\.id) == ["off"])
        #expect(MacCatalogExtensionListPresentation.emptyMessage.contains("local server here") == false)
    }

    @Test func agentDraftBuildsADefinitionWithoutDroppingResources() {
        let existing = AgentDefinition(
            name: "Scout",
            description: "Old",
            instructions: AgentInstructions(mode: .append, text: "Be brief"),
            resources: AgentResources(skillPaths: ["review"]),
            sessionDefaults: AgentSessionDefaults(model: "openai/gpt-5.5")
        )
        let draft = MacAgentEditorDraft(
            name: "Research Scout",
            description: "Finds sources",
            instructionMode: .replace,
            instructionText: "Stay curious"
        )

        let definition = draft.makeDefinition(preserving: existing)
        #expect(definition.name == "Research Scout")
        #expect(definition.description == "Finds sources")
        #expect(definition.instructions == AgentInstructions(mode: .replace, text: "Stay curious"))
        #expect(definition.resources?.skillPaths == ["review"])
        #expect(definition.sessionDefaults?.model == "openai/gpt-5.5")
    }

    @Test func agentCreateLaunchReusesStarterPromptAndRefusesEmptyRequest() {
        let workspace = workspace()
        var draft = MacControlSessionLaunchPresentation.createAgent(workspace: workspace)

        #expect(draft.domain == .agents)
        #expect(draft.intent == .create)
        #expect(draft.canSubmit == false)
        #expect(draft.title == "Create Agent")

        draft.userRequest = "A research scout"
        #expect(draft.canSubmit)
        #expect(draft.sessionName == "Agent: A research scout")
        #expect(
            draft.prompt == ControlSessionStarterPrompt.make(
                domain: .agents,
                intent: .create,
                workspaceId: workspace.id,
                workspaceName: workspace.name,
                userRequest: "A research scout"
            )
        )
        #expect(draft.prompt.contains("oppi agent"))
        #expect(draft.prompt.contains("User request:"))
    }

    @Test func scheduleReviseLaunchIncludesCanonicalTarget() {
        let workspace = workspace()
        var draft = MacControlSessionLaunchPresentation.reviseSchedule(
            schedule(id: "sched-1", name: "Morning brief", status: .active),
            workspace: workspace
        )
        draft.userRequest = "Run later"

        #expect(draft.domain == .schedules)
        #expect(draft.intent == .revise)
        #expect(draft.targetId == "sched-1")
        #expect(draft.targetName == "Morning brief")
        #expect(draft.title == "Revise Morning brief")
        #expect(draft.sessionName == "Revise Morning brief")
        #expect(
            draft.prompt == ControlSessionStarterPrompt.make(
                domain: .schedules,
                intent: .revise,
                targetId: "sched-1",
                targetName: "Morning brief",
                workspaceId: workspace.id,
                workspaceName: workspace.name,
                userRequest: "Run later"
            )
        )
        #expect(draft.prompt.contains("Canonical target ID: sched-1"))
    }

    @Test func launchWithoutWorkspaceCannotSubmit() {
        let draft = MacControlSessionLaunchPresentation.createAgent(workspace: nil)
        #expect(draft.workspaceId.isEmpty)
        #expect(draft.canSubmit == false)
    }

    @Test func workspaceCreateLaunchCanSubmitWithoutAnExistingWorkspace() {
        var draft = MacControlSessionLaunchPresentation.createWorkspace(workspace: nil)

        #expect(draft.domain == .workspaces)
        #expect(draft.intent == .create)
        #expect(draft.workspaceId.isEmpty)
        #expect(draft.canSubmit == false)
        #expect(draft.title == "Create Workspace")
        #expect(draft.placeholder == "Describe a new Workspace…")

        draft.userRequest = "A notes folder"
        #expect(draft.canSubmit)
        #expect(draft.sessionName == "Workspace: A notes folder")
        #expect(
            draft.prompt == ControlSessionStarterPrompt.make(
                domain: .workspaces,
                intent: .create,
                userRequest: "A notes folder"
            )
        )
        #expect(draft.prompt.contains("oppi workspace"))
        #expect(draft.prompt.contains("User request:"))
    }

    @Test func workspaceReviseLaunchIncludesCanonicalTarget() {
        let target = workspace(id: "ws-notes", name: "Notes")
        var draft = MacControlSessionLaunchPresentation.reviseWorkspace(target)
        draft.userRequest = "Use a different folder"

        #expect(draft.domain == .workspaces)
        #expect(draft.intent == .revise)
        #expect(draft.targetId == "ws-notes")
        #expect(draft.targetName == "Notes")
        #expect(draft.workspaceId == "ws-notes")
        #expect(draft.title == "Revise Notes")
        #expect(draft.sessionName == "Revise Notes")
        #expect(draft.placeholder == "Describe how this Workspace should change…")
        #expect(
            draft.prompt == ControlSessionStarterPrompt.make(
                domain: .workspaces,
                intent: .revise,
                targetId: "ws-notes",
                targetName: "Notes",
                workspaceId: "ws-notes",
                workspaceName: "Notes",
                userRequest: "Use a different folder"
            )
        )
        #expect(draft.prompt.contains("Canonical target ID: ws-notes"))
        #expect(draft.prompt.contains("oppi workspace"))
    }
}

@Suite("Mac catalog client")
struct MacCatalogClientTests {
    @Test func listAgentsDecodesSummariesFromUnixSocket() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            #expect(request.method == "GET")
            #expect(request.path == "/agents")
            return jsonResponse(#"""
            {"agents":[{"id":"agent-1","name":"Sensei","icon":{"kind":"emoji","value":"🧘"},"status":"active","version":2,"createdAt":1000,"updatedAt":2000}]}
            """#)
        }
        let agents = try await makeClient(transport).listAgents()
        #expect(agents.map(\.id) == ["agent-1"])
        #expect(agents.first?.name == "Sensei")
        #expect(agents.first?.icon == .emoji("🧘"))
    }

    @Test func listSchedulesSkillsAndExtensionsHitOwnerRoutes() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            switch request.path {
            case "/schedules":
                return jsonResponse(#"""
                {"schedules":[{"id":"sched-1","name":"Morning","status":"active","trigger":{"type":"cron","expression":"0 9 * * *","timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":12},"createdAt":1000,"updatedAt":2000}]}
                """#)
            case "/server/resources/skills":
                return jsonResponse(#"""
                {"skills":[{"id":"review","name":"Review","description":"Review code","provenance":{"kind":"piAgent","label":"Pi"},"path":null,"state":"enabled","loadError":null,"warnings":[],"editable":false}]}
                """#)
            case "/server/resources/extensions":
                return jsonResponse(#"""
                {"extensions":[{"id":"files","name":"Files","description":"Workspace files","kind":"builtIn","provenance":{"kind":"builtIn","label":"Built-in"},"path":null,"state":"on","loadError":null,"warnings":[],"isRemovable":false}],"builtInTools":[{"name":"read"}]}
                """#)
            default:
                Issue.record("Unexpected path \(request.path)")
                return jsonResponse("{}")
            }
        }
        let client = makeClient(transport)

        let schedules = try await client.listAgentSchedules()
        let skills = try await client.listServerSkills()
        let catalog = try await client.listServerExtensions()

        #expect(schedules.map(\.id) == ["sched-1"])
        #expect(schedules.first?.trigger.scheduleScreenCadence == "DAILY")
        #expect(skills.map(\.id) == ["review"])
        #expect(catalog.extensions.map(\.id) == ["files"])
        #expect(catalog.builtInTools.map(\.name) == ["read"])
    }

    @Test func enableSkillPutsEnabledFlag() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            #expect(request.method == "PUT")
            #expect(request.path == "/server/resources/skills/review/enabled")
            let body = try JSONDecoder().decode(EnabledBody.self, from: request.body ?? Data())
            #expect(body.enabled == false)
            return jsonResponse(#"""
            {"id":"review","name":"Review","description":"Review code","provenance":{"kind":"piAgent","label":"Pi"},"path":null,"state":"disabled","loadError":null,"warnings":[],"editable":false}
            """#)
        }

        let summary = try await makeClient(transport).setServerSkillEnabled(id: "review", enabled: false)
        #expect(summary.state == .disabled)
    }

    @Test func updateAgentSendsJSONNullsForClearedDescriptionAndInstructions() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            #expect(request.method == "PATCH")
            #expect(request.path == "/agents/agent-1")
            let json = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            #expect(json?["name"] as? String == "Reviewer")
            #expect(json?["description"] is NSNull)
            #expect(json?["instructions"] is NSNull)
            return jsonResponse(#"""
            {"agent":{"id":"agent-1","name":"Reviewer","icon":{"kind":"default"},"status":"active","version":2,"definition":{"name":"Reviewer","icon":{"kind":"default"}},"createdAt":1000,"updatedAt":2000}}
            """#)
        }

        let agent = try await makeClient(transport).updateAgent(
            agentId: "agent-1",
            definition: AgentDefinition(name: "Reviewer")
        )
        #expect(agent.version == 2)
        #expect(agent.definition.description == nil)
        #expect(agent.definition.instructions == nil)
    }

    @Test func createControlSessionPostsMetadataAndStarterPrompt() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            #expect(request.method == "POST")
            #expect(request.path == "/control-sessions")
            let body = try JSONDecoder().decode(ControlCreateBody.self, from: request.body ?? Data())
            #expect(body.domain == .agents)
            #expect(body.intent == .create)
            #expect(body.targetId == nil)
            #expect(body.name == "Create Agent")
            #expect(body.prompt?.contains("oppi agent") == true)
            #expect(body.launchIdempotencyKey != nil)
            return jsonResponse(#"""
            {"session":{"id":"control-1","name":"Create Agent","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}},"prompted":true}
            """#)
        }

        let response = try await makeClient(transport).createControlSession(
            .init(
                domain: .agents,
                intent: .create,
                name: "Create Agent",
                prompt: ControlSessionStarterPrompt.make(
                    domain: .agents,
                    intent: .create,
                    workspaceId: "ws-1",
                    workspaceName: "Oppi",
                    userRequest: "A research scout"
                ),
                launchIdempotencyKey: "mac-control-1"
            )
        )

        #expect(response.session.id == "control-1")
        #expect(response.session.workspaceId == nil)
        #expect(response.session.control?.domain == .agents)
        #expect(response.session.control?.intent == .create)
        #expect(response.prompted == true)
    }
}

@MainActor
@Suite("Mac catalog store")
struct MacCatalogStoreTests {
    @Test func loadingAgentsReplacesTheStubWithSavedRowsAndSelectsPi() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            #expect(request.path == "/agents")
            return jsonResponse(#"""
            {"agents":[{"id":"agent-1","name":"Sensei","status":"active","version":1,"createdAt":1000,"updatedAt":2000}]}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))

        await store.load(.agents)

        #expect(store.agents.map(\.id) == ["agent-1"])
        #expect(store.selectedAgentID == MacCatalogAgentRow.pi.id)
        #expect(store.contentState(for: .agents) == .content)
        #expect(store.lastError(for: .agents) == nil)
    }

    @Test func savingAnAgentPatchesTheDefinitionAndRefreshesTheRow() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" && request.path == "/agents" {
                return jsonResponse(#"""
                {"agents":[{"id":"agent-1","name":"Sensei","status":"active","version":1,"createdAt":1000,"updatedAt":2000}]}
                """#)
            }
            if request.method == "GET" && request.path == "/agents/agent-1" {
                return jsonResponse(#"""
                {"agent":{"id":"agent-1","name":"Sensei","icon":{"kind":"default"},"status":"active","version":1,"definition":{"name":"Sensei","icon":{"kind":"default"}},"createdAt":1000,"updatedAt":2000}}
                """#)
            }
            #expect(request.method == "PATCH")
            #expect(request.path == "/agents/agent-1")
            let body = try JSONDecoder().decode(AgentDefinition.self, from: request.body ?? Data())
            #expect(body.name == "Research Sensei")
            return jsonResponse(#"""
            {"agent":{"id":"agent-1","name":"Research Sensei","icon":{"kind":"default"},"status":"active","version":2,"definition":{"name":"Research Sensei","icon":{"kind":"default"}},"createdAt":1000,"updatedAt":3000}}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.load(.agents)
        store.selectAgent("agent-1")
        await store.loadSelectedAgent()

        var draft = try #require(store.agentDraft)
        draft.name = "Research Sensei"
        try await store.saveAgent(draft)

        #expect(store.agents.first?.name == "Research Sensei")
        #expect(store.loadedAgent?.version == 2)
    }

    @Test func enablingASkillUpdatesTheCatalogRow() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" {
                return jsonResponse(#"""
                {"skills":[{"id":"review","name":"Review","description":"Review code","provenance":{"kind":"piAgent","label":"Pi"},"path":null,"state":"enabled","loadError":null,"warnings":[],"editable":false}]}
                """#)
            }
            #expect(request.method == "PUT")
            return jsonResponse(#"""
            {"id":"review","name":"Review","description":"Review code","provenance":{"kind":"piAgent","label":"Pi"},"path":null,"state":"disabled","loadError":null,"warnings":[],"editable":false}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.load(.skills)
        store.selectSkill("review")
        try await store.setSelectedSkillEnabled(false)

        #expect(store.skills.first?.state == .disabled)
        #expect(store.selectedSkill?.state == .disabled)
    }

    @Test func pausingAScheduleUpdatesStatusInTheList() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" && request.path == "/schedules" {
                return jsonResponse(#"""
                {"schedules":[{"id":"sched-1","name":"Morning","status":"active","trigger":{"type":"every","intervalMs":3600000,"timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":4},"createdAt":1000,"updatedAt":2000}]}
                """#)
            }
            if request.method == "GET" && request.path.hasPrefix("/workspaces") {
                return jsonResponse(#"""
                {"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1000,"updatedAt":2000}],"summaries":[]}
                """#)
            }
            #expect(request.method == "POST")
            #expect(request.path == "/schedules/sched-1/pause")
            return jsonResponse(#"""
            {"schedule":{"id":"sched-1","name":"Morning","status":"paused","trigger":{"type":"every","intervalMs":3600000,"timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":4},"createdAt":1000,"updatedAt":3000}}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.load(.schedules)
        store.selectSchedule("sched-1")
        try await store.setSelectedScheduleStatus(.paused)

        #expect(store.schedules.first?.status == .paused)
        #expect(store.scheduleStatusFilter == .paused)
    }

    @Test func applyingScheduleFilterKeepsTheCurrentIDWhenItRemainsVisible() {
        let store = MacCatalogStore(client: makeClient(RoutingLocalHTTPTransport { _ in jsonResponse("{}") }))
        store.schedules = [
            schedule(id: "alpha", name: "Alpha", status: .active),
            schedule(id: "beta", name: "Beta", status: .active),
            schedule(id: "night", name: "Nightly", status: .paused),
        ]
        store.selectedScheduleID = "beta"

        store.applyScheduleStatusFilter(.active)
        #expect(store.selectedScheduleID == "beta")
        #expect(store.scheduleStatusFilter == .active)

        store.applyScheduleStatusFilter(.paused)
        #expect(store.selectedScheduleID == "night")
        #expect(store.scheduleStatusFilter == .paused)

        store.applyScheduleStatusFilter(.archived)
        #expect(store.selectedScheduleID == nil)
        #expect(store.scheduleStatusFilter == .archived)
    }

    @Test func loadSelectedAgentDropsTheWriteWhenSelectionChangesDuringAwait() async {
        let transport = HeldLocalHTTPTransport(response: jsonResponse(#"""
        {"agent":{"id":"agent-1","name":"Sensei","icon":{"kind":"default"},"status":"active","version":1,"definition":{"name":"Sensei","icon":{"kind":"default"}},"createdAt":1000,"updatedAt":2000}}
        """#))
        let store = MacCatalogStore(client: makeClient(transport))
        store.selectedAgentID = "agent-1"

        let loading = Task { await store.loadSelectedAgent() }
        await transport.waitUntilStarted()
        store.selectedAgentID = "agent-2"
        await transport.release()
        await loading.value

        #expect(store.loadedAgent == nil)
        #expect(store.agentDraft == nil)
    }

    @Test func loadSelectedScheduleDropsTheWriteWhenSelectionChangesDuringAwait() async {
        let transport = HeldLocalHTTPTransport(response: jsonResponse(#"""
        {"schedule":{"id":"sched-1","name":"Morning","status":"active","trigger":{"type":"every","intervalMs":3600000,"timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","prompt":"Hi"},"createdAt":1000,"updatedAt":2000}}
        """#))
        let store = MacCatalogStore(client: makeClient(transport))
        store.selectedScheduleID = "sched-1"

        let loading = Task { await store.loadSelectedSchedule() }
        await transport.waitUntilStarted()
        store.selectedScheduleID = "sched-2"
        await transport.release()
        await loading.value

        #expect(store.loadedSchedule == nil)
        #expect(store.scheduleDraft == nil)
    }

    @Test func loadSelectedSkillDropsTheWriteWhenSelectionChangesDuringAwait() async {
        let transport = HeldLocalHTTPTransport(response: jsonResponse(#"""
        {"summary":{"id":"review","name":"Review","description":"Review code","provenance":{"kind":"piAgent","label":"Pi"},"path":null,"state":"enabled","loadError":null,"warnings":[],"editable":false},"skillMarkdown":"# Review","files":[]}
        """#))
        let store = MacCatalogStore(client: makeClient(transport))
        store.selectedSkillID = "review"

        let loading = Task { await store.loadSelectedSkill() }
        await transport.waitUntilStarted()
        store.selectedSkillID = "other"
        await transport.release()
        await loading.value

        #expect(store.loadedSkill == nil)
    }

    @Test func loadSelectedExtensionDropsTheWriteWhenSelectionChangesDuringAwait() async {
        let transport = HeldLocalHTTPTransport(response: jsonResponse(#"""
        {"summary":{"id":"files","name":"Files","description":null,"kind":"builtIn","provenance":{"kind":"builtIn","label":"Built-in"},"path":null,"state":"on","loadError":null,"warnings":[],"isRemovable":false},"contributedTools":["read"]}
        """#))
        let store = MacCatalogStore(client: makeClient(transport))
        store.selectedExtensionID = "files"

        let loading = Task { await store.loadSelectedExtension() }
        await transport.waitUntilStarted()
        store.selectedExtensionID = "other"
        await transport.release()
        await loading.value

        #expect(store.loadedExtension == nil)
    }

    @Test func launchingAnAgentCreateControlSessionPostsMetadataAndReturnsAControlTarget() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" && request.path == "/workspaces" {
                return jsonResponse(#"""
                {"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1000,"updatedAt":2000}],"summaries":[]}
                """#)
            }
            #expect(request.method == "POST")
            #expect(request.path == "/control-sessions")
            let body = try JSONDecoder().decode(ControlCreateBody.self, from: request.body ?? Data())
            #expect(body.domain == .agents)
            #expect(body.intent == .create)
            #expect(body.targetId == nil)
            #expect(body.name == "Agent: A research scout")
            #expect(body.prompt == ControlSessionStarterPrompt.make(
                domain: .agents,
                intent: .create,
                workspaceId: "ws-1",
                workspaceName: "Oppi",
                userRequest: "A research scout"
            ))
            return jsonResponse(#"""
            {"session":{"id":"control-1","name":"Agent: A research scout","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}},"prompted":true}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.beginCreateAgentControlSession()
        store.controlLaunchDraft?.userRequest = "A research scout"

        let target = try await store.launchControlSession()

        #expect(target.sessionId == "control-1")
        #expect(target.routeScope == .control)
        #expect(target.summary.control?.domain == .agents)
        #expect(target.summary.control?.intent == .create)
        #expect(store.controlLaunchDraft == nil)
    }

    @Test func launchingAScheduleRevisionIncludesCanonicalTarget() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" && request.path == "/schedules" {
                return jsonResponse(#"""
                {"schedules":[{"id":"sched-1","name":"Morning","status":"active","trigger":{"type":"every","intervalMs":3600000,"timeZone":"UTC"},"action":{"type":"new_session","workspaceId":"ws-1","promptChars":4},"createdAt":1000,"updatedAt":2000}]}
                """#)
            }
            if request.method == "GET" && request.path.hasPrefix("/workspaces") {
                return jsonResponse(#"""
                {"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1000,"updatedAt":2000}],"summaries":[]}
                """#)
            }
            #expect(request.method == "POST")
            #expect(request.path == "/control-sessions")
            let body = try JSONDecoder().decode(ControlCreateBody.self, from: request.body ?? Data())
            #expect(body.domain == .schedules)
            #expect(body.intent == .revise)
            #expect(body.targetId == "sched-1")
            #expect(body.targetName == "Morning")
            #expect(body.prompt?.contains("Canonical target ID: sched-1") == true)
            return jsonResponse(#"""
            {"session":{"id":"control-2","name":"Revise Morning","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"schedules","intent":"revise","targetId":"sched-1","targetName":"Morning"}},"prompted":true}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.load(.schedules)
        store.selectSchedule("sched-1")
        await store.beginReviseSelectedScheduleControlSession()
        store.controlLaunchDraft?.userRequest = "Run later"

        let target = try await store.launchControlSession()

        #expect(target.sessionId == "control-2")
        #expect(target.routeScope == .control)
        #expect(target.summary.control?.domain == .schedules)
        #expect(target.summary.control?.targetId == "sched-1")
    }

    @Test func revisingPiDoesNotOpenAControlLaunch() async {
        let store = MacCatalogStore(client: makeClient(RoutingLocalHTTPTransport { _ in jsonResponse("{}") }))
        store.selectedAgentID = MacCatalogAgentRow.pi.id
        await store.beginReviseSelectedAgentControlSession()
        #expect(store.controlLaunchDraft == nil)
    }

    @Test func launchWithoutControlMetadataFailsHonestly() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" {
                return jsonResponse(#"""
                {"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1000,"updatedAt":2000}],"summaries":[]}
                """#)
            }
            return jsonResponse(#"""
            {"session":{"id":"session-1","workspaceId":"ws-1","name":"Ordinary","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0},"prompted":true}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.beginCreateAgentControlSession()
        store.controlLaunchDraft?.userRequest = "A research scout"

        do {
            _ = try await store.launchControlSession()
            Issue.record("Ordinary sessions must not count as control launches")
        } catch let error as MacControlSessionLaunchError {
            #expect(error == .missingControlMetadata)
        }
    }

    @Test func launchingAWorkspaceCreateControlSessionPostsMetadataWithoutRequiringAWorkspace() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" {
                return jsonResponse(#"""
                {"workspaces":[],"summaries":[]}
                """#)
            }
            #expect(request.method == "POST")
            #expect(request.path == "/control-sessions")
            let body = try JSONDecoder().decode(ControlCreateBody.self, from: request.body ?? Data())
            #expect(body.domain == .workspaces)
            #expect(body.intent == .create)
            #expect(body.targetId == nil)
            #expect(body.name == "Workspace: A notes folder")
            #expect(body.prompt == ControlSessionStarterPrompt.make(
                domain: .workspaces,
                intent: .create,
                userRequest: "A notes folder"
            ))
            return jsonResponse(#"""
            {"session":{"id":"control-ws-1","name":"Workspace: A notes folder","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"workspaces","intent":"create"}},"prompted":true}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.beginCreateWorkspaceControlSession()
        store.controlLaunchDraft?.userRequest = "A notes folder"

        let target = try await store.launchControlSession()

        #expect(target.sessionId == "control-ws-1")
        #expect(target.routeScope == .control)
        #expect(target.summary.control?.domain == .workspaces)
        #expect(target.summary.control?.intent == .create)
        #expect(store.controlLaunchDraft == nil)
    }

    @Test func launchingAWorkspaceCreateControlSessionFromAPopulatedCatalogOmitsCanonicalWorkspace() async throws {
        let expectedPrompt = ControlSessionStarterPrompt.make(
            domain: .workspaces,
            intent: .create,
            userRequest: "A notes folder"
        )
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" {
                return jsonResponse(#"""
                {"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1000,"updatedAt":2000},{"id":"ws-2","name":"Notes","createdAt":1100,"updatedAt":2100}],"summaries":[]}
                """#)
            }
            #expect(request.method == "POST")
            #expect(request.path == "/control-sessions")
            let body = try JSONDecoder().decode(ControlCreateBody.self, from: request.body ?? Data())
            #expect(body.domain == .workspaces)
            #expect(body.intent == .create)
            #expect(body.targetId == nil)
            #expect(body.targetName == nil)
            #expect(body.name == "Workspace: A notes folder")
            #expect(body.prompt == expectedPrompt)
            #expect(body.prompt?.contains("Canonical workspace ID") == false)
            #expect(body.prompt?.contains("Canonical workspace name") == false)
            #expect(body.prompt?.contains("ws-1") == false)
            return jsonResponse(#"""
            {"session":{"id":"control-ws-3","name":"Workspace: A notes folder","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"workspaces","intent":"create"}},"prompted":true}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.beginCreateWorkspaceControlSession()
        #expect(store.controlLaunchDraft?.workspaceId.isEmpty == true)
        #expect(store.controlLaunchDraft?.workspaceName.isEmpty == true)
        store.controlLaunchDraft?.userRequest = "A notes folder"

        let target = try await store.launchControlSession()

        #expect(target.sessionId == "control-ws-3")
        #expect(target.routeScope == .control)
        #expect(target.summary.control?.domain == .workspaces)
        #expect(target.summary.control?.intent == .create)
        #expect(store.controlLaunchDraft == nil)
    }

    @Test func launchingAWorkspaceRevisionIncludesCanonicalTarget() async throws {
        let transport = RoutingLocalHTTPTransport { request in
            if request.method == "GET" {
                return jsonResponse(#"""
                {"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1000,"updatedAt":2000}],"summaries":[]}
                """#)
            }
            #expect(request.method == "POST")
            #expect(request.path == "/control-sessions")
            let body = try JSONDecoder().decode(ControlCreateBody.self, from: request.body ?? Data())
            #expect(body.domain == .workspaces)
            #expect(body.intent == .revise)
            #expect(body.targetId == "ws-1")
            #expect(body.targetName == "Oppi")
            #expect(body.name == "Revise Oppi")
            #expect(body.prompt?.contains("Canonical target ID: ws-1") == true)
            #expect(body.prompt?.contains("oppi workspace") == true)
            return jsonResponse(#"""
            {"session":{"id":"control-ws-2","name":"Revise Oppi","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"workspaces","intent":"revise","targetId":"ws-1","targetName":"Oppi"}},"prompted":true}
            """#)
        }
        let store = MacCatalogStore(client: makeClient(transport))
        await store.beginReviseWorkspaceControlSession(workspace())
        store.controlLaunchDraft?.userRequest = "Use a different folder"

        let target = try await store.launchControlSession()

        #expect(target.sessionId == "control-ws-2")
        #expect(target.routeScope == .control)
        #expect(target.summary.control?.domain == .workspaces)
        #expect(target.summary.control?.intent == .revise)
        #expect(target.summary.control?.targetId == "ws-1")
        #expect(store.controlLaunchDraft == nil)
    }

    @Test func retryingALostControlLaunchReusesTheFrozenRequestAndIdempotencyKey() async throws {
        let transport = FailFirstControlLaunchTransport()
        let store = MacCatalogStore(client: makeClient(transport))
        await store.beginCreateAgentControlSession()
        store.controlLaunchDraft?.userRequest = "A research scout"
        let originalPrompt = try #require(store.controlLaunchDraft?.prompt)
        let originalName = try #require(store.controlLaunchDraft?.sessionName)

        await #expect(throws: MacLocalHTTPError.timeout) {
            try await store.launchControlSession()
        }

        store.controlLaunchDraft?.userRequest = "Revised unsent request."
        let target = try await store.launchControlSession()
        #expect(target.sessionId == "control-1")
        #expect(store.controlLaunchDraft?.userRequest == "Revised unsent request.")
        #expect(store.controlLaunchError?.contains("earlier request was delivered") == true)

        let secondTarget = try await store.launchControlSession()
        #expect(secondTarget.sessionId == "control-2")
        #expect(store.controlLaunchDraft == nil)

        let posts = await transport.posted()
        #expect(posts.count == 3)
        let firstKey = try #require(posts[0].launchIdempotencyKey)
        #expect(!firstKey.isEmpty)
        #expect(posts[1].launchIdempotencyKey == firstKey)
        #expect(posts[1].name == originalName)
        #expect(posts[1].prompt == originalPrompt)
        #expect(posts[1].prompt?.contains("A research scout") == true)
        #expect(posts[1].prompt?.contains("Revised unsent") == false)
        #expect(posts[2].launchIdempotencyKey != firstKey)
        #expect(posts[2].prompt?.contains("Revised unsent request.") == true)
    }

    @Test func cancelAndNewLaunchAreIgnoredWhileControlPostIsInFlight() async throws {
        let transport = HeldLocalHTTPTransport(response: jsonResponse(#"""
        {"session":{"id":"control-1","name":"Agent: A research scout","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}},"prompted":true}
        """#))
        let store = MacCatalogStore(client: makeClient(transport))
        store.workspaces = [workspace()]
        await store.beginCreateAgentControlSession()
        store.controlLaunchDraft?.userRequest = "A research scout"
        let sourceDraft = try #require(store.controlLaunchDraft)

        let launching = Task { try await store.launchControlSession() }
        await transport.waitUntilStarted()
        #expect(store.isLaunchingControlSession)

        store.cancelControlSessionLaunch()
        await store.beginCreateWorkspaceControlSession()

        #expect(store.controlLaunchDraft == sourceDraft)
        await transport.release()
        let target = try await launching.value

        #expect(target.sessionId == "control-1")
        #expect(store.controlLaunchDraft == nil)
        #expect(store.isLaunchingControlSession == false)
    }

    @Test func aSecondControlLaunchCannotOverlapAnInFlightPost() async throws {
        let transport = HeldLocalHTTPTransport(response: jsonResponse(#"""
        {"session":{"id":"control-1","name":"Agent: A research scout","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}},"prompted":true}
        """#))
        let store = MacCatalogStore(client: makeClient(transport))
        store.workspaces = [workspace()]
        await store.beginCreateAgentControlSession()
        store.controlLaunchDraft?.userRequest = "A research scout"

        let firstLaunch = Task { try await store.launchControlSession() }
        await transport.waitUntilStarted()
        let secondLaunch = Task {
            do {
                _ = try await store.launchControlSession()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await Task.yield()
        await transport.release()

        #expect(try await firstLaunch.value.sessionId == "control-1")
        #expect(await secondLaunch.value)
        #expect(await transport.startedCount() == 1)
    }

    @Test func beginCreateAgentControlSessionPreservesWorkspaceLoadFailure() async {
        let transport = RoutingLocalHTTPTransport { request in
            #expect(request.method == "GET")
            #expect(request.path == "/workspaces")
            throw MacLocalHTTPError.connectionFailed("catalog down")
        }
        let store = MacCatalogStore(client: makeClient(transport))
        store.controlLaunchError = "stale launch error"

        await store.beginCreateAgentControlSession()

        #expect(store.controlLaunchDraft != nil)
        #expect(store.controlLaunchError?.contains("catalog down") == true)
        #expect(store.controlLaunchError?.contains("stale launch error") == false)
    }
}

private struct EnabledBody: Decodable {
    let enabled: Bool
}

private struct ControlCreateBody: Decodable {
    let domain: ControlSessionDomain
    let intent: ControlSessionIntent
    let targetId: String?
    let targetName: String?
    let name: String?
    let prompt: String?
    let launchIdempotencyKey: String?
}

private func makeClient(_ transport: any MacLocalHTTPPerforming) -> MacWorkspaceClient {
    MacWorkspaceClient(
        socketPath: "/tmp/oppi-catalog-test.sock",
        token: "sk_owner",
        transport: transport
    )
}

private func jsonResponse(_ json: String) -> MacLocalHTTPResponse {
    MacLocalHTTPResponse(
        statusCode: 200,
        headers: ["content-type": "application/json"],
        body: Data(json.utf8)
    )
}

private actor RoutingLocalHTTPTransport: MacLocalHTTPPerforming {
    private let handler: @Sendable (MacLocalHTTPRequest) throws -> MacLocalHTTPResponse

    init(handler: @escaping @Sendable (MacLocalHTTPRequest) throws -> MacLocalHTTPResponse) {
        self.handler = handler
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        try handler(request)
    }
}

private actor FailFirstControlLaunchTransport: MacLocalHTTPPerforming {
    private var posts: [ControlCreateBody] = []

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        if request.method == "GET" {
            return jsonResponse(#"""
            {"workspaces":[{"id":"ws-1","name":"Oppi","createdAt":1000,"updatedAt":2000}],"summaries":[]}
            """#)
        }
        let body = try JSONDecoder().decode(ControlCreateBody.self, from: request.body ?? Data())
        posts.append(body)
        if posts.count == 1 {
            throw MacLocalHTTPError.timeout
        }
        let sessionId = posts.count == 2 ? "control-1" : "control-2"
        return jsonResponse("""
        {"session":{"id":"\(sessionId)","name":"\(body.name ?? "")","status":"busy","createdAt":1000,"lastActivity":1000,"messageCount":1,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}},"prompted":true}
        """)
    }

    func posted() -> [ControlCreateBody] { posts }
}

private actor HeldLocalHTTPTransport: MacLocalHTTPPerforming {
    private let response: MacLocalHTTPResponse
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiters: [CheckedContinuation<MacLocalHTTPResponse, Error>] = []
    private var requestCount = 0
    private var released = false

    init(response: MacLocalHTTPResponse) {
        self.response = response
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requestCount += 1
        if released {
            return response
        }
        return try await withCheckedThrowingContinuation { continuation in
            responseWaiters.append(continuation)
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume(returning: response) }
    }

    func startedCount() -> Int { requestCount }
}

private func workspace(id: String = "ws-1", name: String = "Oppi") -> Workspace {
    Workspace(
        id: id,
        name: name,
        description: nil,
        icon: .defaultValue,
        hostMount: "/tmp/\(id)",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
}

private func agent(
    id: String,
    name: String,
    description: String? = nil
) -> AgentDefinitionSummary {
    AgentDefinitionSummary(
        id: id,
        name: name,
        icon: .defaultValue,
        description: description,
        status: .active,
        version: 1,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
}

private func schedule(
    id: String,
    name: String,
    status: AgentScheduleStatus
) -> AgentScheduleSummary {
    AgentScheduleSummary(
        id: id,
        name: name,
        status: status,
        trigger: .every(intervalMs: 3_600_000, timeZone: "UTC"),
        action: AgentScheduleActionSummary(
            type: .newSession,
            workspaceId: "ws-1",
            sessionId: nil,
            agentId: nil,
            promptChars: 12
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
}

private func skill(
    id: String,
    name: String,
    description: String = "",
    provenance: String = "Pi",
    state: ServerSkillState,
    loadError: String? = nil
) -> ServerSkillSummary {
    ServerSkillSummary(
        id: id,
        name: name,
        description: description,
        provenance: ServerResourceProvenance(kind: .piAgent, label: provenance),
        path: nil,
        state: state,
        loadError: loadError,
        warnings: [],
        editable: false
    )
}

private func ext(
    id: String,
    name: String,
    kind: ServerExtensionKind,
    state: ServerExtensionState
) -> ServerExtensionSummary {
    ServerExtensionSummary(
        id: id,
        name: name,
        description: nil,
        kind: kind,
        provenance: ServerResourceProvenance(
            kind: kind == .builtIn ? .builtIn : .piAgent,
            label: kind == .builtIn ? "Built-in" : "Pi"
        ),
        path: nil,
        state: state,
        loadError: nil,
        warnings: [],
        isRemovable: false
    )
}
