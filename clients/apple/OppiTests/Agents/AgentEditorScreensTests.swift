import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Edit Agent screens")
struct AgentEditorScreensTests {
    private static let serverId = "agent-editor-tests"

    private func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.setPreviewServerId(Self.serverId)
        return connection
    }

    private func makeAgent(
        capabilities: AgentCapabilities? = nil,
        context: AgentContext? = nil,
        workspaceIds: [String]? = nil
    ) -> StoredAgentDefinition {
        StoredAgentDefinition(
            id: "agent-editor-tests",
            name: "Design Reviewer",
            icon: .defaultValue,
            description: nil,
            status: .active,
            version: 1,
            definition: AgentDefinition(
                name: "Design Reviewer",
                icon: .defaultValue,
                capabilities: capabilities,
                context: context,
                launchConstraints: workspaceIds.map { AgentLaunchConstraints(allowedWorkspaceIds: $0) }
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        )
    }

    /// An editor over the catalog fixture, whose Save the fixture answers with the
    /// definition the body describes, so a test sees what the server would store.
    private func makeEditor(
        agent: StoredAgentDefinition? = nil,
        connection: ServerConnection? = nil
    ) -> AgentNativeEditViewController {
        AgentEditorURLProtocol.reset()
        let agent = agent ?? makeAgent()
        AgentEditorURLProtocol.agent = agent
        return AgentNativeEditViewController(
            agent: agent,
            apiClient: AgentEditorURLProtocol.makeClient(),
            connection: connection ?? makeConnection(),
            serverName: "mac-studio"
        ) { saved in AgentEditorURLProtocol.savedAgent = saved }
    }

    // MARK: - The editor

    @Test("Save waits for a name, and the custom prompt's rows and footer follow its switches")
    func saveAndPromptRows() async throws {
        let screen = try Screen(makeEditor())
        defer { screen.hide() }

        #expect(await screen.waitFor { screen.root.navigationItem.rightBarButtonItem != nil })
        let save = try #require(screen.root.navigationItem.rightBarButtonItem)
        #expect(await screen.waitFor { save.isEnabled }, "a named Agent can be saved")
        #expect(screen.footer("Uses the server's default system prompt."))
        #expect(screen.button("agent.nativeEdit.promptMode") == nil, "no custom prompt, no Append/Replace")

        let name = try #require(await screen.waitForTextView("agent.nativeEdit.name"))
        #expect(name.text == "Design Reviewer")
        Screen.type("  ", into: name)
        #expect(await screen.waitFor { !save.isEnabled }, "a blank name cannot be saved")
        Screen.type("Design Reviewer", into: name)
        #expect(await screen.waitFor { save.isEnabled })

        // The name is one line: Return ends editing and a pasted line break becomes a space.
        let delegate = try #require(name.delegate)
        let end = NSRange(location: name.text.utf16.count, length: 0)
        #expect(delegate.textView?(name, shouldChangeTextIn: end, replacementText: "\n") == false)
        #expect(delegate.textView?(name, shouldChangeTextIn: end, replacementText: "v2\nfinal") == false)
        #expect(name.text == "Design Reviewerv2 final")
        Screen.type("Design Reviewer", into: name)

        let toggle = try #require(await screen.waitForSwitch("agent.nativeEdit.customPrompt"))
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        #expect(await screen.waitFor {
            screen.footer("Adds these instructions after the server's default system prompt.")
        })
        #expect(!save.isEnabled, "a custom prompt needs text")

        let mode = try #require(await screen.waitForButton("agent.nativeEdit.promptMode"))
        #expect(mode.accessibilityValue == "Append")
        try Screen.choose("Replace", in: mode)
        #expect(await screen.waitFor {
            screen.footer("Uses these instructions instead of the server's default system prompt.")
        })
        #expect(screen.button("agent.nativeEdit.promptMode")?.accessibilityValue == "Replace")
    }

    /// A menu row keeps the closure that lists its choices for as long as the
    /// row lives. When that closure held the editor, the editor's own list kept
    /// it alive after it closed.
    @Test("the editor deallocates once it closes")
    func editorDeallocatesAfterClosing() async throws {
        weak var closedEditor: AgentNativeEditViewController?
        do {
            let editor = makeEditor()
            closedEditor = editor
            let screen = try Screen(editor)
            #expect(await screen.waitForButton("agent.nativeEdit.thinking") != nil, "a menu row is on screen")
            screen.hide()
        }
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { closedEditor == nil })
    }

    // MARK: - Capabilities

    /// Each switch is the definition it saves: nothing else is sent, and the Agent the
    /// server hands back reads back as the same switches.
    @Test("the Tools and Context switches reach the saved definition")
    func switchesReachTheSavedDefinition() async throws {
        let screen = try Screen(makeEditor())
        defer { screen.hide() }

        // The first row also waits for the page's own list to load, which sets the others.
        let toolsRow = try #require(await screen.waitForButton("agent.nativeEdit.tools"))
        #expect(toolsRow.accessibilityValue == "Pi standard", "a new Agent follows the setting")
        #expect(screen.button("agent.nativeEdit.plugins")?.accessibilityValue == "All")
        #expect(screen.button("agent.nativeEdit.mcpServers")?.accessibilityValue == "All")
        #expect(screen.button("agent.nativeEdit.skills")?.accessibilityValue == "All")

        // The Pi Tools page is Pi's own: choose an exact set, then take edit and write out of it.
        toolsRow.sendActions(for: .touchUpInside)
        let tools = try #require(await screen.waitForPushedPage(AgentToolSelectionViewController.self))
        let mode = try #require(await screen.waitForButton("agent.nativeEdit.toolMode", in: tools.view))
        try KitMenuRow.choose("Choose tools", in: mode)
        for name in ["edit", "write"] {
            let tool = try #require(await screen.waitForButton("agent.nativeEdit.tool.\(name)", in: tools.view))
            #expect(tool.accessibilityValue == "Selected", "the set starts from Pi's own tools")
            tool.sendActions(for: .touchUpInside)
            #expect(await screen.waitFor {
                screen.button("agent.nativeEdit.tool.\(name)", in: tools.view)?.accessibilityValue == "Not selected"
            })
        }
        screen.navigation.popViewController(animated: false)

        // Without edit and write the Agent cannot change files, and it names what it reaches.
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.plugins")?.accessibilityValue == "None" })
        #expect(screen.button("agent.nativeEdit.mcpServers")?.accessibilityValue == "None")
        #expect(await screen.waitFor {
            screen.footer("Without edit and write this Agent cannot change files, and it names the plugins and MCP servers it may use (both start at None). Ask me, Notify me, and Delegate decide whether it can ask you a question, send a push when it is done, and start child sessions.")
        })

        for identifier in ["agent.nativeEdit.askMe", "agent.nativeEdit.notifyMe", "agent.nativeEdit.delegate",
                           "agent.nativeEdit.contextFiles", "agent.nativeEdit.sessionHistory"] {
            let toggle = try #require(await screen.waitForSwitch(identifier))
            #expect(toggle.isOn, "\(identifier) starts on")
            toggle.isOn = false
            toggle.sendActions(for: .valueChanged)
        }
        #expect(await screen.waitFor { screen.switchIsOn("agent.nativeEdit.sessionHistory") == false })

        try await screen.saveAndWait()

        let definition = try #require(AgentEditorURLProtocol.savedAgent?.definition)
        let capabilities = try #require(definition.capabilities)
        #expect(capabilities.tools == ["read", "bash"])
        #expect(capabilities.ask == false)
        #expect(capabilities.notify == false)
        #expect(capabilities.subagent == false)
        #expect(capabilities.plugins?.isEmpty == true, "a read-only Agent names its plugins, so the list is sent, not omitted")
        #expect(capabilities.mcp?.isEmpty == true, "a read-only Agent names its MCP servers, so the map is sent, not omitted")
        #expect(definition.context?.readsContextFiles == false)
        #expect(definition.context?.readsSessionHistory == false)
        #expect(definition.context?.skills == nil, "no Skill list means Pi discovery")

        // What the server stored is what the editor shows when it opens again.
        let reopened = try Screen(makeEditor(agent: AgentEditorURLProtocol.savedAgent))
        defer { reopened.hide() }
        let reopenedTools = try #require(await reopened.waitForButton("agent.nativeEdit.tools"))
        // The stored order reads the same before the tools catalog loads and after it.
        #expect(reopenedTools.accessibilityValue == "read, bash")
        #expect(reopened.button("agent.nativeEdit.plugins")?.accessibilityValue == "None")
        #expect(reopened.switchIsOn("agent.nativeEdit.askMe") == false)
        #expect(reopened.switchIsOn("agent.nativeEdit.contextFiles") == false)
        #expect(reopened.switchIsOn("agent.nativeEdit.sessionHistory") == false)
    }

    /// A read-only Agent never widens by omission: its plugins and MCP servers are a
    /// list, so "all of them" is not offered.
    @Test("a read-only Agent's plugin page offers a list, not everything")
    func readOnlyAgentCannotFollowEveryPlugin() async throws {
        let screen = try Screen(makeEditor(
            agent: makeAgent(capabilities: AgentCapabilities(tools: ["read", "bash"], plugins: [], mcp: [:]))
        ))
        defer { screen.hide() }

        let plugins = try #require(await screen.waitForButton("agent.nativeEdit.plugins"))
        #expect(plugins.accessibilityValue == "None")
        plugins.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))

        let all = try #require(await screen.waitForSwitch("agent.nativeEdit.pluginAll", in: page.view))
        #expect(!all.isOn)
        #expect(!all.isEnabled, "a read-only Agent cannot follow every plugin")
        #expect(screen.footer(AgentCapabilityPages.readOnlyFooter))
        #expect(await screen.waitForButton("agent.nativeEdit.plugin.webtools", in: page.view) != nil)

        let webtools = try #require(screen.button("agent.nativeEdit.plugin.webtools", in: page.view))
        webtools.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.plugin.webtools", in: page.view)?.accessibilityValue?.hasPrefix("Selected") == true
        })
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.plugins")?.accessibilityValue == "1 selected" })

        try await screen.saveAndWait()

        let capabilities = try #require(AgentEditorURLProtocol.savedAgent?.definition.capabilities)
        #expect(capabilities.tools == ["read", "bash"])
        #expect(capabilities.plugins == ["webtools"])
        #expect(capabilities.mcp?.isEmpty == true, "the MCP map is still stated, so the server keeps it explicit")
    }

    @Test("a read-only Agent with plugins and MCP keeps both lists when turning codemode on")
    func readOnlyAgentTurningCodemodeOnKeepsPluginsAndMcp() async throws {
        let screen = try Screen(makeEditor(
            agent: makeAgent(capabilities: AgentCapabilities(
                tools: ["read", "bash"],
                plugins: ["webtools"],
                mcp: [
                    "gmail": .tools(["search_emails", "read_email"]),
                    "coros": .all,
                ]
            ))
        ))
        defer { screen.hide() }

        let toolsRow = try #require(await screen.waitForButton("agent.nativeEdit.tools"))
        #expect(toolsRow.accessibilityValue == "read, bash")
        #expect(screen.button("agent.nativeEdit.plugins")?.accessibilityValue == "1 selected")
        #expect(screen.button("agent.nativeEdit.mcpServers")?.accessibilityValue == "2 selected")

        toolsRow.sendActions(for: .touchUpInside)
        let tools = try #require(await screen.waitForPushedPage(AgentToolSelectionViewController.self))
        let codemode = try #require(await screen.waitForSwitch("agent.nativeEdit.optionalTool.codemode", in: tools.view))
        #expect(!codemode.isOn)
        codemode.setOn(true, animated: false)
        codemode.sendActions(for: .valueChanged)
        #expect(await screen.waitFor {
            screen.visibleViews(of: UISwitch.self, in: tools.view)
                .first { $0.accessibilityIdentifier == "agent.nativeEdit.optionalTool.codemode" }?.isOn == true
        })

        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.tools")?.accessibilityValue == "read, bash, codemode"
        })
        #expect(screen.button("agent.nativeEdit.plugins")?.accessibilityValue == "1 selected")
        #expect(screen.button("agent.nativeEdit.mcpServers")?.accessibilityValue == "2 selected")

        try await screen.saveAndWait()

        let capabilities = try #require(AgentEditorURLProtocol.savedAgent?.definition.capabilities)
        #expect(capabilities.tools == ["read", "bash", "codemode"])
        #expect(capabilities.plugins == ["webtools"])
        #expect(capabilities.mcp == [
            "gmail": .tools(["search_emails", "read_email"]),
            "coros": .all,
        ])
    }

    @Test("choosing exact tools before the catalog loads does not produce an empty set or wipe plugins and MCP")
    func choosingExactBeforeCatalogLoadsDoesNotProduceEmptySetOrWipe() async throws {
        let draft = AgentNativeEditDraft(
            agent: makeAgent(capabilities: AgentCapabilities(
                tools: nil,
                plugins: ["webtools"],
                mcp: ["gmail": .all]
            )),
            connection: makeConnection(),
            serverName: "mac-studio"
        )
        #expect(draft.builtInTools.isEmpty, "catalog has not loaded yet")
        let page = AgentToolSelectionViewController(selection: .agent(draft, serverName: "mac-studio"))
        let screen = try Screen(page)
        defer { screen.hide() }

        let mode = try #require(await screen.waitForButton("agent.nativeEdit.toolMode", in: page.view))
        try Screen.choose("Choose tools", in: mode)

        #expect(!draft.toolsAll)
        #expect(!draft.selectedTools.isEmpty, "switching to Choose tools before load must not start empty")
        #expect(draft.canEditFiles, "default tools remain editable until edit and write are turned off")
        #expect(draft.selectedPlugins == ["webtools"])
        #expect(draft.mcpSelection == ["gmail": .all])
    }

    @Test("Pi-defaults mode hides optional switches for an Agent and shows them once Choose tools is picked")
    func piDefaultsModeHidesOptionalSwitchesUntilExactIsChosen() async throws {
        let screen = try Screen(makeEditor(agent: makeAgent()))
        defer { screen.hide() }

        let toolsRow = try #require(await screen.waitForButton("agent.nativeEdit.tools"))
        toolsRow.sendActions(for: .touchUpInside)
        let tools = try #require(await screen.waitForPushedPage(AgentToolSelectionViewController.self))
        let mode = try #require(await screen.waitForButton("agent.nativeEdit.toolMode", in: tools.view))
        #expect(mode.accessibilityValue == "Pi defaults")
        #expect(await screen.waitFor {
            screen.footer(AgentManagementPresentation.agentToolsFollowSettingFooter)
        })
        // Optional switches do not apply in Pi-defaults mode: an Agent follows the server setting.
        #expect(
            screen.visibleViews(of: UISwitch.self, in: tools.view)
                .first { $0.accessibilityIdentifier == "agent.nativeEdit.optionalTool.codemode" } == nil
        )

        // Choosing an exact set reveals both built-in and optional tools, and codemode saves.
        try Screen.choose("Choose tools", in: mode)
        let codemode = try #require(await screen.waitForSwitch("agent.nativeEdit.optionalTool.codemode", in: tools.view))
        #expect(!codemode.isOn)
        codemode.setOn(true, animated: false)
        codemode.sendActions(for: .valueChanged)
        screen.navigation.popViewController(animated: false)

        try await screen.saveAndWait()
        #expect(
            AgentEditorURLProtocol.savedAgent?.definition.capabilities?.tools
                == ["read", "bash", "edit", "write", "codemode"]
        )
    }

    @Test("a plugin with no summary attached is still offered, by its contributed tools")
    func pluginWithoutItsSummaryIsOffered() async throws {
        let screen = try Screen(makeEditor(agent: makeAgent()))
        defer { screen.hide() }

        let row = try #require(await screen.waitForButton("agent.nativeEdit.plugins"))
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))
        // "All" is the omitted list: the rows appear once it is off.
        let all = try #require(await screen.waitForSwitch("agent.nativeEdit.pluginAll", in: page.view))
        all.setOn(false, animated: false)
        all.sendActions(for: .valueChanged)
        // The live `secret` row is only a Pi extension: no plugin summary, tools contributed.
        let secret = try #require(
            await screen.waitForButton("agent.nativeEdit.plugin.secret", in: page.view),
            "a selectable row without a plugin summary is still a plugin an Agent may name"
        )
        #expect(secret.accessibilityValue?.contains("secret_run") == true)
        secret.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.plugin.secret", in: page.view)?
                .accessibilityValue?.hasPrefix("Selected") == true
        })
        // A toggle's package is its switch's: the server does not mark `ask` selectable.
        #expect(screen.button("agent.nativeEdit.plugin.ask", in: page.view) == nil)
    }

    /// "All" is the omitted list, so the page's rows only appear when it is off, and a checked
    /// row is one name in the saved list.
    @Test("a plugin chosen from the list is the one the definition names")
    func pluginsAreChosenByName() async throws {
        let screen = try Screen(makeEditor(
            agent: makeAgent(capabilities: AgentCapabilities(plugins: ["notebook"]))
        ))
        defer { screen.hide() }

        let row = try #require(await screen.waitForButton("agent.nativeEdit.plugins"))
        #expect(row.accessibilityValue == "1 selected")
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))

        let all = try #require(await screen.waitForSwitch("agent.nativeEdit.pluginAll", in: page.view))
        #expect(!all.isOn)
        #expect(all.isEnabled)
        let notebook = try #require(await screen.waitForButton("agent.nativeEdit.plugin.notebook", in: page.view))
        #expect(notebook.accessibilityValue?.hasPrefix("Selected") == true)
        let voice = try #require(screen.button("agent.nativeEdit.plugin.voice", in: page.view))
        #expect(voice.accessibilityValue?.hasPrefix("Not selected") == true)
        voice.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.plugin.voice", in: page.view)?.accessibilityValue?.hasPrefix("Selected") == true
        })

        // Turning "All" on drops the list: every plugin, including the ones added later.
        all.isOn = true
        all.sendActions(for: .valueChanged)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.plugin.notebook", in: page.view) == nil
        }, "everything leaves no list to check")
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.plugins")?.accessibilityValue == "All" })

        // Back on the page, All is on, so there is no list. Turning it off starts from
        // nothing, and a row checked there is the list the definition gets.
        let pluginsRow = try #require(await screen.waitForButton("agent.nativeEdit.plugins"))
        pluginsRow.sendActions(for: .touchUpInside)
        let list = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))
        let allSwitch = try #require(await screen.waitForSwitch("agent.nativeEdit.pluginAll", in: list.view))
        #expect(allSwitch.isOn)
        #expect(screen.button("agent.nativeEdit.plugin.notebook", in: list.view) == nil)
        allSwitch.isOn = false
        allSwitch.sendActions(for: .valueChanged)
        let notebookAgain = try #require(await screen.waitForButton("agent.nativeEdit.plugin.notebook", in: list.view))
        #expect(notebookAgain.accessibilityValue?.hasPrefix("Not selected") == true, "turning All off starts from nothing")
        notebookAgain.sendActions(for: .touchUpInside)
        screen.navigation.popViewController(animated: false)

        try await screen.saveAndWait()

        #expect(AgentEditorURLProtocol.savedAgent?.definition.capabilities?.plugins == ["notebook"])
    }

    /// Mail triage's shape: one server of the several the server has, and only some of
    /// its tools.
    @Test("an MCP server's tools are narrowed on the server's own page")
    func mcpToolsAreNarrowedPerServer() async throws {
        let gmailTools = [
            "search_emails", "read_email", "list_labels", "create_draft", "send_email",
            "archive_email", "trash_email", "mark_spam", "list_threads", "read_thread",
            "list_attachments", "download_attachment",
        ]
        let screen = try Screen(makeEditor(
            agent: makeAgent(capabilities: AgentCapabilities(
                mcp: ["gmail": .tools(["search_emails", "read_email", "list_threads"])]
            ))
        ))
        defer { screen.hide() }

        let row = try #require(await screen.waitForButton("agent.nativeEdit.mcpServers"))
        #expect(row.accessibilityValue == "1 selected")
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))

        let gmail = try #require(await screen.waitForButton("agent.nativeEdit.mcp.gmail", in: page.view))
        #expect(gmail.accessibilityValue?.hasPrefix("Selected") == true)
        let coros = try #require(screen.button("agent.nativeEdit.mcp.coros", in: page.view))
        #expect(coros.accessibilityValue?.hasPrefix("Not selected") == true)
        #expect(screen.button("agent.nativeEdit.mcp.coros.disclosure", in: page.view) != nil)

        // The row's disclosure opens the server's tools, with the same switch on top.
        let disclosure = try #require(screen.button("agent.nativeEdit.mcp.gmail.disclosure", in: page.view))
        disclosure.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor { screen.navigation.topViewController !== page })
        let tools = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))
        #expect(tools.title == "gmail")
        let all = try #require(await screen.waitForSwitch("agent.nativeEdit.mcpToolAll", in: tools.view))
        #expect(!all.isOn, "three of the server's twelve tools are chosen")
        for tool in ["search_emails", "read_email", "list_threads"] {
            #expect(await screen.waitFor {
                screen.button("agent.nativeEdit.mcpTool.\(tool)", in: tools.view)?.accessibilityValue?.hasPrefix("Selected") == true
            })
        }
        #expect(screen.button("agent.nativeEdit.mcpTool.send_email", in: tools.view)?.accessibilityValue?.hasPrefix("Not selected") == true)

        let send = try #require(screen.button("agent.nativeEdit.mcpTool.send_email", in: tools.view))
        send.sendActions(for: .touchUpInside)
        let archive = try #require(screen.button("agent.nativeEdit.mcpTool.archive_email", in: tools.view))
        archive.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.mcpTool.send_email", in: tools.view)?.accessibilityValue?.hasPrefix("Selected") == true
                && screen.button("agent.nativeEdit.mcpTool.archive_email", in: tools.view)?.accessibilityValue?.hasPrefix("Selected") == true
        })
        #expect(gmailTools.count == 12, "the fixture is the twelve tools the page lists")

        screen.navigation.popViewController(animated: false)
        #expect(screen.navigation.topViewController === page)
        let corosRow = try #require(await screen.waitForButton("agent.nativeEdit.mcp.coros", in: page.view))
        corosRow.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.mcp.coros", in: page.view)?.accessibilityValue?.hasPrefix("Selected") == true
        })
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.mcpServers")?.accessibilityValue == "2 selected" })

        try await screen.saveAndWait()

        let mcp = try #require(AgentEditorURLProtocol.savedAgent?.definition.capabilities?.mcp)
        #expect(mcp["gmail"]?.toolNames == ["archive_email", "list_threads", "read_email", "search_emails", "send_email"])
        #expect(mcp["coros"] == .all, "a server checked here is reached with all of its tools")
    }

    @Test("Skills are chosen by name, and a Skill that cannot load cannot be chosen")
    func skillsAreChosenByName() async throws {
        let screen = try Screen(makeEditor(agent: makeAgent(context: AgentContext(skills: ["nanny"]))))
        defer { screen.hide() }

        let row = try #require(await screen.waitForButton("agent.nativeEdit.skills"))
        #expect(row.accessibilityValue == "1 selected")
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))

        let nanny = try #require(await screen.waitForButton("agent.nativeEdit.skill.nanny", in: page.view))
        #expect(nanny.accessibilityValue?.hasPrefix("Selected") == true)
        let release = try #require(screen.button("agent.nativeEdit.skill.release", in: page.view))
        #expect(release.accessibilityValue?.hasPrefix("Not selected") == true)
        let broken = try #require(screen.button("agent.nativeEdit.skill.broken", in: page.view))
        #expect(!broken.isEnabled, "a Skill whose last load failed cannot be chosen")
        release.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.skill.release", in: page.view)?.accessibilityValue?.hasPrefix("Selected") == true
        })
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.skills")?.accessibilityValue == "2 selected" })

        try await screen.saveAndWait()

        #expect(AgentEditorURLProtocol.savedAgent?.definition.context?.skills == ["nanny", "release"])
    }

    /// A project server is an Agent's to choose too: the picker lists every scope, merges a name
    /// two scopes configure into one row, and says which workspace the project one belongs to.
    @Test("the MCP picker lists a project server beside the global one, and merges a shared name")
    func mcpPickerListsEveryScope() async throws {
        let connection = makeConnection()
        connection.workspaceStore.workspacesByServer[Self.serverId] = [
            Workspace(id: "ws-kypu", name: "kypu", runtime: .host, createdAt: .now, updatedAt: .now),
        ]
        let editor = makeEditor(connection: connection)
        // The editor's fixture reset clears its scopes, so the project servers go in after it.
        AgentEditorURLProtocol.setServers(
            [
                McpServerSummary(
                    name: "kypu-repo", transport: "stdio", config: McpServerConfig(command: "kypu"),
                    enabled: true, exposure: .codemode, state: "connected", tools: ["repo_status"],
                    toolExposure: nil, error: nil, supportsOAuth: false
                ),
                McpServerSummary(
                    name: "gmail", transport: "stdio", config: McpServerConfig(command: "gmail"),
                    enabled: true, exposure: .codemode, state: "connected",
                    tools: ["search_emails"], toolExposure: nil, error: nil, supportsOAuth: false
                ),
            ],
            scope: "ws-kypu"
        )
        let screen = try Screen(editor)
        defer { screen.hide() }

        let row = try #require(await screen.waitForButton("agent.nativeEdit.mcpServers"))
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentCapabilitySelectionViewController.self))
        let all = try #require(await screen.waitForSwitch("agent.nativeEdit.mcpAll", in: page.view))
        all.isOn = false
        all.sendActions(for: .valueChanged)

        // The project server is here, and its workspace is what the row says.
        let project = try #require(await screen.waitForButton("agent.nativeEdit.mcp.kypu-repo", in: page.view))
        #expect(project.accessibilityValue == "Not selected, 1 tools \u{00B7} kypu project")
        // gmail is configured globally and in kypu's own scope: one row, the global listing's.
        let gmailRows = screen.visibleViews(of: UIButton.self, in: page.view)
            .filter { $0.accessibilityIdentifier == "agent.nativeEdit.mcp.gmail" }
        #expect(gmailRows.count == 1)
        #expect(gmailRows.first?.accessibilityValue == "Not selected, 12 tools")
    }

    @Test("an unlisted workspace stays choosable when it is already chosen, and the runtime filters the rest")
    func workspacePageFiltersByRuntime() async throws {
        let connection = makeConnection()
        connection.workspaceStore.workspacesByServer[Self.serverId] = [
            Workspace(id: "ws-host", name: "On the host", runtime: .host, createdAt: .now, updatedAt: .now),
            Workspace(id: "ws-box", name: "In a sandbox", runtime: .sandbox, createdAt: .now, updatedAt: .now),
        ]
        let editor = makeEditor(connection: connection)
        let screen = try Screen(editor)
        defer { screen.hide() }

        // Constrain the Agent to host workspaces and to a list.
        let runtime = try #require(await screen.waitForButton("agent.nativeEdit.requiredRuntime"))
        try Screen.choose("Host", in: runtime)
        let mode = try #require(await screen.waitForButton("agent.nativeEdit.workspaceMode"))
        try Screen.choose("Allowed list", in: mode)
        let row = try #require(await screen.waitForButton("agent.nativeEdit.workspaces"))
        #expect(await screen.waitFor { row.accessibilityValue == "None" })
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentWorkspaceSelectionViewController.self))

        #expect(await screen.waitForButton("agent.nativeEdit.workspace.ws-host", in: page.view) != nil)
        #expect(screen.button("agent.nativeEdit.workspace.ws-box", in: page.view) == nil, "a sandbox workspace does not fit")
        let host = try #require(screen.button("agent.nativeEdit.workspace.ws-host", in: page.view))
        host.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.workspace.ws-host", in: page.view)?.accessibilityValue?.hasPrefix("Selected") == true
        })
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.workspaces")?.accessibilityValue == "1" })
        let save = try #require(screen.root.navigationItem.rightBarButtonItem)
        #expect(save.isEnabled, "a compatible workspace is chosen")
    }
}

// MARK: - Harness

/// A screen presented in a navigation controller, in a window tall enough to lay out
/// the whole form, with what the tests ask of its rows. Presenting it is what the app
/// does, and what `Router.finish` closes.
@MainActor
private final class Screen {
    let window: UIWindow
    let navigation: UINavigationController
    let root: UIViewController

    init(_ root: UIViewController) throws {
        self.root = root
        navigation = UINavigationController(rootViewController: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2600)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.present(navigation, animated: false)
        window.layoutIfNeeded()
    }

    func hide() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func waitFor(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            self.window.layoutIfNeeded()
            return predicate()
        }
    }

    func waitForButton(_ identifier: String, in view: UIView? = nil) async -> UIButton? {
        _ = await waitFor { self.button(identifier, in: view) != nil }
        return button(identifier, in: view)
    }

    func waitForTextView(_ identifier: String) async -> UITextView? {
        _ = await waitFor { self.visibleViews(of: UITextView.self).contains { $0.accessibilityIdentifier == identifier } }
        return visibleViews(of: UITextView.self).first { $0.accessibilityIdentifier == identifier }
    }

    /// What typing does to a text view: its text changes and its delegate hears of it.
    static func type(_ text: String, into textView: UITextView) {
        textView.text = text
        textView.delegate?.textViewDidChange?(textView)
    }

    func waitForSwitch(_ identifier: String, in view: UIView? = nil) async -> UISwitch? {
        _ = await waitFor { self.visibleViews(of: UISwitch.self, in: view).contains { $0.accessibilityIdentifier == identifier } }
        return visibleViews(of: UISwitch.self, in: view).first { $0.accessibilityIdentifier == identifier }
    }

    func switchIsOn(_ identifier: String) -> Bool? {
        visibleViews(of: UISwitch.self).first { $0.accessibilityIdentifier == identifier }?.isOn
    }

    func waitForPushedPage<Page: UIViewController>(_ type: Page.Type) async -> Page? {
        _ = await waitFor { self.navigation.topViewController is Page && self.navigation.transitionCoordinator == nil }
        return navigation.topViewController as? Page
    }

    /// Runs the editor's Save and waits for the fixture server's answer to reach the
    /// editor's `onSaved`.
    func saveAndWait() async throws {
        let save = try #require(root.navigationItem.rightBarButtonItem)
        #expect(await waitFor { save.isEnabled }, "Save is enabled")
        save.primaryAction?.performWithSender(nil, target: nil)
        #expect(
            await waitForMainActorCondition(timeout: .seconds(5)) { AgentEditorURLProtocol.savedAgent != nil },
            "the save reached the server"
        )
    }

    /// A button in a row the list shows now; a pooled cell is not one.
    func button(_ identifier: String, in view: UIView? = nil) -> UIButton? {
        visibleViews(of: UIButton.self, in: view).first { $0.accessibilityIdentifier == identifier }
    }

    /// Whether a section footer on the top page says `text`.
    func footer(_ text: String) -> Bool {
        guard let list = (navigation.topViewController?.view).flatMap({ $0.firstSubview(of: UICollectionView.self) }) else { return false }
        let kind = UICollectionView.elementKindSectionFooter
        return list.indexPathsForVisibleSupplementaryElements(ofKind: kind).contains { indexPath in
            let view = list.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell
            return (view?.contentConfiguration as? UIListContentConfiguration)?.text?.contains(text) == true
        }
    }

    func visibleViews<T: UIView>(of type: T.Type, in view: UIView? = nil) -> [T] {
        let top = view ?? navigation.topViewController?.view ?? window
        guard let list = top.firstSubview(of: UICollectionView.self) else { return [] }
        return list.visibleCells.flatMap { $0.allSubviews(of: type) }
    }

    /// Runs the menu item `title` of a button's menu: a kit row builds its rows
    /// when the menu opens, so the row is asked for them.
    static func choose(_ title: String, in button: UIButton) throws {
        try KitMenuRow.choose(title, in: button)
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let found = subview.firstSubview(of: type) { return found }
        }
        return nil
    }

    func allSubviews<T: UIView>(of type: T.Type) -> [T] {
        var found = (self as? T).map { [$0] } ?? []
        for subview in subviews { found += subview.allSubviews(of: type) }
        return found
    }
}

/// Serves the Agent the editor opened, the three catalogs it reads (plugins, Skills,
/// MCP servers), and answers a save with the definition its body describes, so an
/// editor test runs the real draft, store, and encoder.
private final class AgentEditorURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "agent-editor.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var agentValue: StoredAgentDefinition?
    nonisolated(unsafe) private static var savedValue: StoredAgentDefinition?
    /// Servers by scope id: `global`, then each workspace's own `.pi/mcp.json`.
    nonisolated(unsafe) private static var scopedServers: [String: [McpServerSummary]] = [:]

    static var agent: StoredAgentDefinition? {
        get { lock.withLock { agentValue } }
        set { lock.withLock { agentValue = newValue } }
    }

    /// What the editor's `onSaved` received: the Agent the fixture answered with.
    static var savedAgent: StoredAgentDefinition? {
        get { lock.withLock { savedValue } }
        set { lock.withLock { savedValue = newValue } }
    }

    static func reset() {
        lock.withLock {
            agentValue = nil
            savedValue = nil
            scopedServers = [:]
        }
    }

    static func setServers(_ servers: [McpServerSummary], scope: String) {
        lock.withLock { scopedServers[scope] = servers }
    }

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentEditorURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return fail() }
        let body: Data
        switch (request.httpMethod, url.path) {
        case ("GET", "/server/resources/skills"):
            body = Self.json(ServerSkillsCatalog(skills: Self.skills))
        case ("GET", "/server/resources/extensions"):
            body = Self.json(ServerExtensionCatalog(
                extensions: Self.extensions,
                builtInTools: Self.builtInTools,
                optionalTools: Self.optionalTools
            ))
        case ("GET", let path) where path.hasPrefix("/mcp/scopes/") && path.hasSuffix("/servers"):
            let scopeId = path
                .replacingOccurrences(of: "/mcp/scopes/", with: "")
                .replacingOccurrences(of: "/servers", with: "")
            let listed = Self.lock.withLock { Self.scopedServers[scopeId] }
            body = Self.json(McpServersResponse(
                scope: McpScopeSnapshot(
                    id: scopeId,
                    title: scopeId == "global" ? "Global" : scopeId,
                    kind: scopeId == "global" ? "global" : "project",
                    projectTrust: nil,
                    servers: listed ?? (scopeId == "global" ? Self.scope.servers : []),
                    inherited: nil,
                    errors: []
                ),
                activeSignIn: nil
            ))
        case ("PATCH", let path) where path.hasPrefix("/agents/"):
            body = Self.answerSave(requestBody(request))
        case ("GET", let path) where path.hasPrefix("/agents/"):
            guard let agent = Self.agent else { return fail() }
            body = Self.json(["agent": agent])
        default:
            return fail()
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            return fail()
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
    }

    static func json(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func jsonObject(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }

    /// URLSession hands a protocol its body as a stream.
    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    /// The stored Agent a save produces: the body with its nulls dropped, as the
    /// server's key-by-key merge does.
    private static func answerSave(_ body: Data) -> Data {
        guard let agent = agent,
              var definition = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return Data()
        }
        definition.removeNulls()
        definition["name"] = agent.definition.name
        let answer: [String: Any] = [
            "agent": [
                "id": agent.id,
                "name": agent.definition.name,
                "status": "active",
                "version": agent.version + 1,
                "definition": definition,
                "createdAt": 1_000,
                "updatedAt": 2_000,
            ],
        ]
        return jsonObject(answer)
    }

    private static let skills: [ServerSkillSummary] = [
        ServerSkillSummary(
            id: "nanny", name: "nanny", description: "Household chores.", provenance: provenance("~/.pi/agent/skills"),
            path: "/skills/nanny/SKILL.md", state: .enabled, loadError: nil, warnings: [], editable: true
        ),
        ServerSkillSummary(
            id: "release", name: "release", description: "Release readiness.", provenance: provenance("~/.pi/agent/skills"),
            path: "/skills/release/SKILL.md", state: .enabled, loadError: nil, warnings: [], editable: true
        ),
        ServerSkillSummary(
            id: "broken", name: "broken", description: "Invalid frontmatter.", provenance: provenance("~/.pi/agent/skills"),
            path: "/skills/broken/SKILL.md", state: .error, loadError: "Missing description.", warnings: [], editable: true
        ),
    ]

    /// Pi's own built-in tools, as the server lists them: read, bash, edit and write are on.
    static let builtInTools: [ServerToolSummary] = [
        ServerToolSummary(name: "read", description: "Read a file", defaultEnabled: true),
        ServerToolSummary(name: "bash", description: "Run a command", defaultEnabled: true),
        ServerToolSummary(name: "edit", description: "Edit a file", defaultEnabled: true),
        ServerToolSummary(name: "write", description: "Write a file", defaultEnabled: true),
        ServerToolSummary(name: "grep", description: "Search text", defaultEnabled: false),
        ServerToolSummary(name: "find", description: "Find files", defaultEnabled: false),
        ServerToolSummary(name: "ls", description: "List a folder", defaultEnabled: false),
    ]
    static let optionalTools: [ServerToolSummary] = [
        ServerToolSummary(name: "codemode", description: "Run JavaScript", defaultEnabled: false),
        ServerToolSummary(name: "tool_search", description: "Search tools", defaultEnabled: false),
    ]

    private static let extensions: [ServerExtensionSummary] = [
        plugin("webtools", tools: ["web_search", "web_fetch"]),
        plugin("notebook", tools: ["notebook_todo"]),
        plugin("voice", tools: ["voice_speak"], state: .off),
        piExtension("secret", tools: ["secret_run", "secret_list"]),
    ]

    /// A row the server marks selectable with no plugin summary attached: the live `secret` row is
    /// one, and its tools are what it contributes.
    private static func piExtension(_ name: String, tools: [String]) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: "extension_\(name)", name: name, description: "The \(name) extension.",
            kind: .directory, provenance: provenance("~/.pi/agent/plugins"), path: "/plugins/\(name)",
            state: .on, loadError: nil, warnings: [], isRemovable: false, contributedTools: tools,
            kinds: [.piExtension], source: .owner, plugin: nil, agentSelectable: true
        )
    }

    private static func plugin(
        _ name: String,
        tools: [String],
        state: ServerExtensionState = .on
    ) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: "extension_\(name)", name: name, description: "The \(name) plugin.", kind: .directory,
            provenance: provenance("~/.pi/agent/plugins"), path: "/plugins/\(name)", state: state,
            loadError: nil, warnings: [], isRemovable: false, kinds: [.plugin], source: .owner,
            plugin: ServerPluginSummary(
                extensionName: name, required: false, enabled: state == .on, runtimes: ["host"],
                tools: tools, hooks: [], sections: [], wraps: [], tasks: [], loadError: nil, kept: false
            ),
            agentSelectable: true
        )
    }

    private static func provenance(_ label: String) -> ServerResourceProvenance {
        ServerResourceProvenance(kind: .piAgent, label: label)
    }

    private static let scope = McpScopeSnapshot(
        id: "global", title: "Global", kind: "global", projectTrust: nil,
        servers: [
            server("gmail", tools: [
                "search_emails", "read_email", "list_labels", "create_draft", "send_email",
                "archive_email", "trash_email", "mark_spam", "list_threads", "read_thread",
                "list_attachments", "download_attachment",
            ]),
            server("coros", tools: ["listWorkouts", "getWorkout", "createWorkout"]),
            server("xcode", tools: ["build", "test"], enabled: false),
        ],
        inherited: nil,
        errors: []
    )

    private static func server(
        _ name: String,
        tools: [String],
        enabled: Bool = true
    ) -> McpServerSummary {
        McpServerSummary(
            name: name, transport: "stdio", config: McpServerConfig(command: name), enabled: enabled,
            exposure: .codemode, state: "connected", tools: tools, toolExposure: nil, error: nil,
            supportsOAuth: false
        )
    }
}

private extension [String: Any] {
    /// A nested dictionary without its nulls: the server's merge drops a key it was sent
    /// as null for, so the definition it stores has none.
    mutating func removeNulls() {
        for (key, value) in self {
            if value is NSNull {
                removeValue(forKey: key)
            } else if var nested = value as? [String: Any] {
                nested.removeNulls()
                self[key] = nested
            }
        }
    }
}
