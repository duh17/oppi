#if DEBUG
import UIKit

/// The settings-like pages outside App, Server, and Workspace Settings: the
/// real views over one fixture server, with API pages answered by
/// `SettingsSweepFixtureURLProtocol`. `SCREENSHOT_SWEEP_PAGE` picks the page:
/// `ssh-hosts`, `mcp`, `theme-import`,
/// `skills`, `skills-offline` (the seeded catalog, cached while the refresh fails), `skill-detail`, `skill-browser`, `extensions`, `extensions-offline` (the catalog
/// request fails over a cached catalog), `extensions-unavailable` (the
/// request fails with nothing cached), `extensions-builtin-only`, `extension-detail`,
/// `agents-pi`, `workspace-create`, `workspace-create-configure`, `mcp-add`,
/// `model-providers` (the connected and available groups over fixture usage).
/// Router modal pages (`RouterSettingsModalsUITests`): `agents`,
/// `agents-pi-file`, `schedules`, `skill-file-review`, `skill-file-edit` (a
/// server that also edits Skill files in place),
/// `pairing-approval`, `onboarding-add-server`, `onboarding-tailscale` (the
/// same onboarding over a running tailnet); `mcp`, `theme-import`, and
/// `agents-pi` serve them too. `SCREENSHOT_SWEEP_SHOWS_WRITES=1` shows the
/// last write the fixture server received (`settingsSweep.lastWrite`);
/// `SCREENSHOT_SWEEP_WRITE_DELAY=<seconds>` holds each write's answer that long.
/// `SCREENSHOT_COLOR_SCHEME=dark|light|oled|night|custom:Paper` selects that theme.
final class SettingsSweepPreviewController: PreviewRootController {
    // The fixtures the pages read, held as long as the preview the way the
    // SwiftUI view's constants were.
    private let connection: ServerConnection
    private let server: PairedServer
    private let client: APIClient
    private let page: String
    private let showsWrites: Bool
    /// The last write, where the SwiftUI preview's bottom-leading overlay put it.
    private let writeLabel = UILabel()

    private static let skills: [ServerSkillSummary] = [
        ServerSkillSummary(
            id: "release", name: "release", description: "Review release readiness before shipping.",
            provenance: .init(kind: .piAgent, label: "~/.pi/agent/skills"),
            path: "/Users/preview/.pi/agent/skills/release/SKILL.md",
            state: .enabled, loadError: nil, warnings: [], editable: true
        ),
        ServerSkillSummary(
            id: "deep-research", name: "deep-research", description: "Source-backed, multi-step web research.",
            provenance: .init(kind: .userSettings, label: "Pi user settings"), path: nil,
            state: .disabled, loadError: nil, warnings: [], editable: false
        ),
        ServerSkillSummary(
            id: "broken", name: "release-checks", description: "Invalid frontmatter prevented this skill from loading.",
            provenance: .init(kind: .piAgent, label: "~/.pi/agent/skills"), path: nil,
            state: .error, loadError: "Missing description in frontmatter.", warnings: [], editable: true
        ),
    ]

    private static let extensions: [ServerExtensionSummary] = [
        ServerExtensionSummary(
            id: "oppi-ask", name: "oppi-ask", description: "Ask the user structured questions.",
            kind: .builtIn, provenance: .init(kind: .builtIn, label: "Oppi built-in"), path: nil,
            state: .on, loadError: nil, warnings: [], isRemovable: false
        ),
        ServerExtensionSummary(
            id: "workflow", name: "workflow", description: "Coordinates local automation.",
            kind: .file, provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"),
            path: "/Users/preview/.pi/agent/extensions/workflow.ts",
            state: .on, loadError: nil, warnings: [], isRemovable: true
        ),
        ServerExtensionSummary(
            id: "simplify", name: "simplify", description: "Review changed code for reuse and quality.",
            kind: .file, provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"), path: nil,
            state: .off, loadError: nil, warnings: [], isRemovable: true
        ),
        ServerExtensionSummary(
            id: "review-helper", name: "review-helper", description: "Extension could not be loaded.",
            kind: .file, provenance: .init(kind: .userSettings, label: "Pi user settings"), path: nil,
            state: .error, loadError: "Cannot find module './review'.", warnings: [], isRemovable: true
        ),
    ]

    private static func catalogExtensions(page: String) -> [ServerExtensionSummary] {
        page == "extensions-builtin-only" ? extensions.filter { $0.kind == .builtIn } : extensions
    }

    /// Model Providers' fixture: one provider connected with usage, one still
    /// to connect, so both groups have a row.
    static let providers: [ProviderAuthProviderStatus] = [
        ProviderAuthProviderStatus(
            id: "anthropic", name: "Anthropic", supportsApiKey: true,
            oauth: ProviderAuthOAuthCapabilities(
                flowType: .oauth, supportsServerBrowserLaunch: true, supportsPhoneBrowserLaunch: true,
                supportsManualCodeInput: false, mayPromptForInput: false
            ),
            authenticated: true, credentialType: .apiKey, expiresAt: nil, maskedKey: "sk-ant-…c4f2"
        ),
        ProviderAuthProviderStatus(
            id: "openai", name: "OpenAI", supportsApiKey: true, oauth: nil,
            authenticated: false, credentialType: nil, expiresAt: nil, maskedKey: nil
        ),
    ]

    static var providerQuotas: ProviderQuotasInfo {
        let now = Date()
        let fetchedAt = Int(now.timeIntervalSince1970 * 1000)
        return ProviderQuotasInfo(
            providers: [
                ProviderQuota(
                    providerId: "anthropic", displayName: "Anthropic", authenticated: true,
                    planType: "Pro",
                    windows: [
                        ProviderQuota.Window(
                            key: "5h", shortLabel: "5h", title: "5-hour window",
                            usedPercent: 62, remainingPercent: 38,
                            limitWindowSeconds: 18_000,
                            resetAt: Int(now.addingTimeInterval(3_600).timeIntervalSince1970),
                            includeWeekdayInReset: false,
                            pacing: ProviderQuota.Window.Pacing(
                                source: "server", status: "plenty", timeRemainingSeconds: 3_600,
                                supplyRatio: 1.8, targetBurnPercentPerHour: 5,
                                recentBurnPercentPerHour: 3, paceRatio: 1.8,
                                projectedExhaustionAt: nil, projectedRemainingPercent: nil
                            )
                        ),
                    ],
                    credits: nil, prepaidBalanceCents: nil, fetchedAt: fetchedAt, error: nil
                ),
            ],
            fetchedAt: fetchedAt
        )
    }

    static let mcpGlobal = McpScopeSnapshot(
        id: McpScopeSnapshot.globalId, title: "Global", kind: "global", projectTrust: nil,
        servers: [
            mcpServer("github", config: McpServerConfig(url: "https://api.github.com/mcp"), state: "connected", tools: ["search_issues", "get_pull_request"], exposure: .deferred, oauth: true),
            mcpServer("filesystem", config: McpServerConfig(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"]), state: "connected", tools: ["read_file", "list_directory", "write_file"], exposure: .codemode),
            mcpServer("docs", config: McpServerConfig(url: "https://docs.example.com/mcp"), state: "needs-auth", tools: [], exposure: .direct, oauth: true),
            mcpServer("notes", config: McpServerConfig(url: "https://notes.example.com/mcp"), state: "disabled", tools: [], exposure: .hidden, enabled: false),
        ],
        inherited: nil, errors: []
    )

    private static func mcpServer(
        _ name: String, config: McpServerConfig, state: String, tools: [String],
        exposure: McpExposure, enabled: Bool = true, oauth: Bool = false
    ) -> McpServerSummary {
        McpServerSummary(
            name: name, transport: config.url == nil ? "stdio" : "http", config: config,
            enabled: enabled, exposure: exposure, state: state, tools: tools,
            toolExposure: nil, error: nil, supportsOAuth: oauth
        )
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        ScreenshotVolatileDefaults.applyThemeScheme(environment["SCREENSHOT_COLOR_SCHEME"])
        let themeStore = ThemeStore()
        page = environment["SCREENSHOT_SWEEP_PAGE"] ?? ""
        showsWrites = environment["SCREENSHOT_SWEEP_SHOWS_WRITES"] == "1"
        SettingsSweepFixtureURLProtocol.writeDelay = environment["SCREENSHOT_SWEEP_WRITE_DELAY"].flatMap(Double.init) ?? 0

        let credentials = ServerCredentials(
            host: "mac-studio.tail1234.ts.net",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            serverFingerprint: "sha256:preview-host"
        )
        guard var server = PairedServer(from: credentials, sortOrder: 0) else {
            preconditionFailure("The sweep preview needs a server fingerprint")
        }
        // This device's pairing, so the roster marks "dev-iphone" as this device.
        server.deviceCredential = DeviceCredential(deviceId: "dev-iphone", accessToken: "preview", expiresAt: .max, refreshChallenge: nil)
        self.server = server

        Self.installFixtureRoutes(page: page)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsSweepFixtureURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://mac-studio.tail1234.ts.net:7749") ?? URL(fileURLWithPath: "/"),
            token: "sk_preview",
            configuration: configuration
        )
        self.client = client

        let connection = ServerConnection()
        connection.setPreviewServerId(server.id)
        connection.setPreviewAPIClient(client)
        connection.serverResourceStore.replaceSkills(Self.skills, serverId: server.id)
        // `extensions-unavailable` has no cached catalog; its page clears the disk cache first.
        if page != "extensions-unavailable" {
            connection.serverResourceStore.replaceExtensions(
                Self.catalogExtensions(page: page),
                builtInTools: [],
                serverId: server.id
            )
        }
        connection.serverResourceStore.switchServer(to: server.id)
        self.connection = connection

        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        if page == "mcp" || page == "model-providers" {
            // The MCP and provider screens wait for `apiClientReady`, so their
            // connection is a ready one whose requests the fixture answers, as
            // the Router and Metrics previews build theirs.
            if coordinator.switchToServer(server) {
                coordinator.connection(for: server.id)?.setAPIClientForTesting(client)
            }
        } else {
            coordinator.installPreviewConnection(connection, serverId: server.id)
        }

        // The app root: router modals present with these services.
        let root = AppRootEnvironment(
            coordinator: coordinator,
            navigation: AppNavigation(),
            themeStore: themeStore,
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )

        switch page {
        case "onboarding-tailscale":
            Self.applyTailnetFixture()
        case "ssh-hosts":
            // Live SSH drive writes real catalog entries; a volatile fixture
            // catalog would shadow them so the new host never appears.
            if ProcessInfo.processInfo.environment["OPPI_LIVE_SSH"] != "1" {
                Self.seedSSHHosts()
            }
        case "agents":
            // Enables Schedule Recurring Run on the agent detail.
            connection.workspaceStore.workspacesByServer[server.id] = [Self.workspace]
        case "pairing-approval":
            connection.pendingPairingApprovals = [Self.pendingApproval]
        default:
            break
        }

        super.init(
            root: root,
            themeStore: themeStore,
            content: Self.makeContent(page: page, root: root, server: server, connection: connection, client: client)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        if showsWrites { addWriteLabel() }
    }

    /// The last write the fixture server received, where the SwiftUI preview's
    /// bottom-leading overlay showed it.
    private func addWriteLabel() {
        writeLabel.font = .preferredFont(forTextStyle: .caption2)
        writeLabel.numberOfLines = 1
        writeLabel.isUserInteractionEnabled = false
        writeLabel.accessibilityIdentifier = "settingsSweep.lastWrite"
        writeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(writeLabel)
        NSLayoutConstraint.activate([
            writeLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
            writeLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4),
            writeLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        observeWrites()
    }

    /// The write record is shared process state (`SettingsSweepWrites`), so the
    /// label follows it the way the SwiftUI overlay's `@State` did.
    private func observeWrites() {
        withObservationTracking {
            writeLabel.text = SettingsSweepWrites.shared.lastWrite
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeWrites() }
        }
    }

    /// The page's screen: the real surfaces over the fixture server, each at the
    /// root of a router navigation controller the way the shell hosts one.
    private static func makeContent(
        page: String,
        root: AppRootEnvironment,
        server: PairedServer,
        connection: ServerConnection,
        client: APIClient
    ) -> UIViewController {
        func stack(_ screen: @escaping () -> UIViewController) -> RouterNavigationController {
            PreviewHost.screenStack(root: root, screen: screen)
        }
        /// The release Skill's SKILL.md, the route's screen at the stack root.
        func skillFilePage() -> UIViewController {
            stack {
                ServerSkillFileViewController(
                    target: .init(serverId: server.id, resourceId: "release", path: "SKILL.md"),
                    root: root,
                    connection: connection
                )
            }
        }

        switch page {
        case "workspace-create":
            return stack { WorkspaceCreateViewController(root: root, server: server) }
        case "workspace-create-configure":
            return stack {
                WorkspaceCreateViewController(
                    root: root,
                    server: server,
                    prefillName: "oppi",
                    prefillPath: "~/workspace/oppi"
                )
            }
        case "onboarding-add-server", "onboarding-tailscale":
            // The simulator has no camera; show Scan QR Code as a phone would.
            return OnboardingViewController(root: root, mode: .addServer, canScan: true)
        case "pairing-approval":
            return stack { PairingApprovalPreviewScreen(root: root) }
        // Shell routes the router hosts directly: search lives in its bar.
        case "skills", "skills-offline":
            return stack { ServerSkillsViewController(root: root) }
        case "extensions", "extensions-offline", "extensions-builtin-only":
            return stack { ServerExtensionsViewController(root: root) }
        case "extensions-unavailable":
            // The disk cache outlives launches: an earlier page's saved catalog
            // would show, so the screen mounts once it is replaced by an empty one.
            return PreviewLoadingController(
                prepare: {
                    await TimelineCache.shared.saveServerResourceCatalog(
                        ServerResourceCatalogSnapshot(
                            skills: [], extensions: [], builtInTools: [], savedAt: Date(),
                            skillsLoaded: false, extensionsLoaded: false, skillsSavedAt: nil, extensionsSavedAt: nil
                        ),
                        serverId: server.id
                    )
                },
                content: { stack { ServerExtensionsViewController(root: root) } }
            )
        case "mcp":
            return stack { McpServersViewController(scopeId: McpScopeSnapshot.globalId, root: root) }
        case "model-providers":
            return stack { ModelProvidersViewController(target: .init(serverId: server.id), root: root) }
        case "mcp-add":
            // The add-server form at the root instead of in its sheet, for a
            // capture of the form itself.
            return stack {
                McpAddServerViewController(
                    client: client, scope: Self.mcpGlobal, serverName: server.name, root: root
                ) {}
            }
        case "ssh-hosts":
            // Off the tailnet whatever machine runs it, so the capture shows the hosts alone.
            return stack {
                SSHTerminalHostListViewController(
                    tailnetRex: RexTailnetSection(
                        store: RexDirectStore(defaults: UserDefaults(suiteName: "settings-sweep-tailnet") ?? .standard), reach: { .none }
                    ),
                    startsTailnet: {}
                )
            }
        case "theme-import":
            return stack { ThemeImportViewController(root: root) }
        case "schedules":
            return stack { ScheduleListViewController(root: root) }
        case "agents":
            return stack { AgentListViewController(root: root) }
        case "agents-pi", "agents-pi-file":
            return stack { PiAgentDetailViewController(root: root) }
        case "extension-detail":
            return stack {
                ServerExtensionDetailViewController(
                    target: .init(serverId: server.id, kind: .extension, resourceId: "workflow"),
                    root: root,
                    connection: connection
                )
            }
        case "skill-detail":
            return stack {
                ServerSkillDetailViewController(
                    target: .init(serverId: server.id, kind: .skill, resourceId: "release"),
                    root: root,
                    connection: connection
                )
            }
        case "skill-browser":
            return stack {
                ServerSkillBrowserViewController(
                    target: .init(serverId: server.id, resourceId: "release"),
                    root: root,
                    connection: connection
                )
            }
        case "skill-file-review":
            return skillFilePage()
        case "skill-file-edit":
            // The editor needs the server's file-editing capability first.
            return PreviewLoadingController(
                prepare: { _ = try? await client.serverInfo() },
                content: { skillFilePage() }
            )
        default:
            return PreviewHost.unknownScreen("Unknown SCREENSHOT_SWEEP_PAGE \(page)")
        }
    }

    // MARK: - Fixtures

    private static let tailnetPeers: [TailnetPeer] = [
        TailnetPeer(id: "n-mac-studio", hostName: "mac-studio", dnsName: "mac-studio.tail1234.ts.net", os: "macOS", tailscaleIPs: ["100.64.1.2"], isOnline: true),
        TailnetPeer(id: "n-mac-mini", hostName: "mac-mini", dnsName: "mac-mini.tail1234.ts.net", os: "macOS", tailscaleIPs: ["100.64.1.4"], isOnline: true),
        TailnetPeer(id: "n-nas", hostName: "nas", dnsName: "nas.tail1234.ts.net", os: "linux", tailscaleIPs: ["100.64.1.5"], isOnline: true),
        TailnetPeer(id: "n-devbox", hostName: "devbox", dnsName: "devbox.tail1234.ts.net", os: "linux", tailscaleIPs: ["100.64.1.6"], isOnline: true),
    ]

    private static func applyTailnetFixture() {
        TailnetNodeController.shared.applyPreviewSnapshot(
            TailnetStatusSnapshot(
                backendState: .running,
                authURL: nil,
                selfDNSName: "oppi-ios.tail1234.ts.net",
                tailnetName: "chen@example.com",
                peers: tailnetPeers
            )
        )
    }

    private static func seedSSHHosts() {
        // Argument-domain values only: no persistent defaults and no Keychain are written.
        let catalog = SSHTerminalCatalog(profiles: [
            SSHTerminalProfile(host: "mac-studio.tail1234.ts.net", username: "chenda", startupCommand: "herdr"),
            SSHTerminalProfile(host: "devbox.local", port: 2222, username: "dev", authentication: .deviceKey),
        ])
        var values: [String: Any] = [:]
        values[SSHTerminalProfileStore.catalogKey] = try? JSONEncoder().encode(catalog)
        ScreenshotVolatileDefaults.apply(values)
    }

    private static let workspace = Workspace(
        id: "preview-ws", name: "oppi-dev", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
    )

    private static let pendingApproval = PendingPairingApproval(
        id: "pa-preview", deviceName: "Chen's iPad", method: "invite", source: nil,
        requestedAt: Int64(Date().timeIntervalSince1970 * 1_000),
        expiresAt: Int64(Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000),
        keyThumbprint: "thumb"
    )

    private static let agent = StoredAgentDefinition(
        id: "agent-design", name: "Design Reviewer", icon: .defaultValue, description: "Reviews UI changes.",
        status: .active, version: 2,
        definition: AgentDefinition(
            name: "Design Reviewer",
            instructions: AgentInstructions(text: "Review the change against the HIG.")
        ),
        createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), archivedAt: nil
    )

    private static let schedule = AgentSchedule(
        id: "schedule-nightly", name: "Nightly digest", status: .active,
        trigger: .every(intervalMs: 3_600_000, timeZone: "America/Los_Angeles"),
        action: .newSession(
            workspaceId: "preview-ws", prompt: "Summarize yesterday's sessions.", agentId: nil,
            model: nil, thinkingLevel: nil, worktreeId: nil, name: nil
        ),
        createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), archivedAt: nil
    )

    private static func installFixtureRoutes(page: String) {
        let encoder = JSONEncoder()
        func json(_ value: some Encodable) -> Data { (try? encoder.encode(value)) ?? Data() }

        struct Themes: Encodable { let themes: [RemoteThemeSummary] }
        struct Models: Encodable { let models: [ModelInfo] }
        struct Agents: Encodable { let agents: [AgentDefinitionSummary] }
        struct AgentBody: Encodable { let agent: StoredAgentDefinition }
        struct Schedules: Encodable { let schedules: [AgentScheduleSummary] }
        struct ScheduleBody: Encodable { let schedule: AgentSchedule }
        struct McpFlowBody: Encodable { let flow: McpAuthFlowSnapshot }
        struct Providers: Encodable { let providers: [ProviderAuthProviderStatus] }

        let agentSummary = AgentDefinitionSummary(
            id: agent.id, name: agent.name, icon: agent.icon, description: agent.description,
            status: agent.status, version: agent.version, createdAt: agent.createdAt,
            updatedAt: agent.updatedAt, archivedAt: nil
        )
        let scheduleSummary = AgentScheduleSummary(
            id: schedule.id, name: schedule.name, status: .active, trigger: schedule.trigger,
            action: AgentScheduleActionSummary(
                type: .newSession, workspaceId: "preview-ws", sessionId: nil, agentId: nil, promptChars: 31
            ),
            createdAt: schedule.createdAt, updatedAt: schedule.updatedAt, archivedAt: nil
        )
        let mcpFlow = McpAuthFlowSnapshot(
            flowId: "mcp-flow", scopeId: McpScopeSnapshot.globalId, serverName: "github",
            launchMode: .phoneBrowser, status: .awaitingManualCode,
            auth: .init(url: "https://github.com/login/oauth", instructions: nil), error: nil,
            createdAt: 1, updatedAt: 1, expiresAt: 9_999_999_999_999
        )
        let systemPrompt = page == "agents-pi-file"
            ? PiSystemPromptSnapshot(
                source: .file, path: "~/.pi/agent/SYSTEM.md",
                resolvedPath: "/Users/preview/.pi/agent/SYSTEM.md", content: "# System\n\nYou are a coding agent."
            )
            : PiSystemPromptSnapshot(
                source: .default, path: "~/.pi/agent/SYSTEM.md", resolvedPath: nil, content: "You are a coding agent."
            )

        SettingsSweepFixtureURLProtocol.routes = [
            "/themes": json(Themes(themes: [
                RemoteThemeSummary(name: "Solarized Night", filename: "solarized-night", colorScheme: "dark"),
                RemoteThemeSummary(name: "Paper", filename: "paper", colorScheme: "light"),
                RemoteThemeSummary(name: "Gruvbox", filename: "gruvbox", colorScheme: "dark"),
            ])),
            "/models": json(Models(models: [
                ModelInfo(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", provider: "anthropic", contextWindow: 200_000),
                ModelInfo(id: "claude-haiku-5", name: "Claude Haiku 5", provider: "anthropic", contextWindow: 200_000),
                ModelInfo(id: "gpt-5-mini", name: "GPT-5 mini", provider: "openai", contextWindow: 400_000),
            ])),
            "/server/metrics/settings": Data(#"{"enabled":true,"revision":3}"#.utf8),
            "/server/mobile-output-guide": Data(#"{"enabled":true,"revision":3}"#.utf8),
            "/mcp/scopes/global/servers": json(McpServersResponse(scope: mcpGlobal, activeSignIn: nil)),
            // Model Providers: the statuses and the usage the page loads.
            "/provider-auth/status": json(Providers(providers: providers)),
            "/server/provider-quotas": json(providerQuotas),
            "/server/resources/pi/system-prompt": json(systemPrompt),
            "/server/resources/pi/default-tools": json(PiDefaultToolsSnapshot(defaultTools: ["+codemode"])),
            "/server/resources/extensions": json(ServerExtensionCatalog(
                extensions: catalogExtensions(page: page),
                builtInTools: [ServerToolSummary(name: "read"), ServerToolSummary(name: "bash")],
                optionalTools: [ServerToolSummary(name: "codemode")]
            )),
            // A Skill file is a host read; the fixture answers every one.
            "/files/current": Data("# Release\n\nReview release readiness.".utf8),
            // `skill-file-edit`: the server edits Skill files, read through the Skill.
            "/server/info": Data(#"{"name":"mac-studio","version":"1.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"mac-studio","nodeVersion":"22","piVersion":"1","configVersion":1,"capabilities":{"currentFiles":{"version":1},"workspaceFileEditing":{"version":1,"maxBytes":1048576},"skillFileEditing":{"version":1,"maxBytes":1048576}},"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":1,"modelCount":0}}"#.utf8),
            "PUT /files/current": Data(#"{"etag":"\"sha256-\#(String(repeating: "b", count: 64))\"","size":1,"mtimeMs":1}"#.utf8),
            "/server/resources/skills": json(ServerSkillsCatalog(skills: skills)),
            "PUT /server/resources/skills/release/enabled": json({ () -> ServerSkillSummary in
                let release = skills[0]
                return ServerSkillSummary(
                    id: release.id, name: release.name, description: release.description,
                    provenance: release.provenance, path: release.path,
                    state: .disabled, loadError: nil, warnings: [], editable: release.editable
                )
            }()),
            "/server/resources/skills/release": json(ServerSkillDetail(
                summary: skills[0],
                skillMarkdown: "# Release\n\nReview release readiness.",
                files: ["SKILL.md", "scripts/check.sh", "references/checklist.md"]
            )),
            "/server/resources/extensions/workflow": json(ServerExtensionDetail(
                summary: extensions[1],
                contributedTools: ["workflow_run", "workflow_status"],
                contributedCommands: ["/workflow"]
            )),
            "/agents": json(Agents(agents: [agentSummary])),
            "/agents/\(agent.id)": json(AgentBody(agent: agent)),
            // The saved icon comes back different from the fixture's, so the
            // detail visibly takes the server's answer.
            "PATCH /agents/\(agent.id)": json(AgentBody(agent: {
                var saved = agent
                saved.icon = .emoji("🦊")
                saved.definition.icon = .emoji("🦊")
                return saved
            }())),
            "/schedules": json(Schedules(schedules: [scheduleSummary])),
            "/schedules/\(schedule.id)": json(ScheduleBody(schedule: schedule)),
            "/schedules/\(schedule.id)/runs": Data(#"{"runs":[]}"#.utf8),
            "/servers/github/login": json(McpFlowBody(flow: mcpFlow)),
            "/mcp/auth/flows/mcp-flow": json(McpFlowBody(flow: mcpFlow)),
            "/mcp/auth/flows/mcp-flow/cancel": Data(#"{"flow":{"flowId":"mcp-flow","scopeId":"global","serverName":"github","launchMode":"phone_browser","status":"cancelled","createdAt":1,"updatedAt":2,"expiresAt":9999999999999}}"#.utf8),
        ]
        // The catalog request answers 404, so a sync fails.
        if page == "extensions-offline" || page == "extensions-unavailable" {
            SettingsSweepFixtureURLProtocol.routes["/server/resources/extensions"] = nil
        }
        // `skills-offline`: the refresh fails and the seeded catalog shows as cached.
        if page == "skills-offline" {
            SettingsSweepFixtureURLProtocol.routes["/server/resources/skills"] = nil
        }
    }
}

/// The last write (`POST`, `PUT`, `PATCH`, `DELETE`) the fixture server
/// received, as `METHOD path {sorted JSON body}`.
@MainActor @Observable
final class SettingsSweepWrites {
    static let shared = SettingsSweepWrites()
    var lastWrite = "none"
}

/// Answers `APIClient` requests from a fixed path → JSON table, where a
/// `"METHOD /path"` key answers that method first. Anything else is a 404.
final class SettingsSweepFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: Data] = [:]
    /// The editor's tagged read: a strong ETag on every `origin=skill` GET.
    private static let skillSourceETag = "\"sha256-\(String(repeating: "a", count: 64))\""
    nonisolated(unsafe) static var writeDelay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let method = request.httpMethod, method != "GET" else {
            answer()
            return
        }
        let summary = "\(method) \(request.url?.path ?? "") \(Self.sortedJSONBody(of: request))"
        Task { @MainActor in SettingsSweepWrites.shared.lastWrite = summary }
        guard Self.writeDelay > 0 else {
            answer()
            return
        }
        // URLProtocol is not Sendable; the loading system never touches this
        // instance again until `answer()` reports through its client.
        nonisolated(unsafe) let fixture = self
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.writeDelay) {
            fixture.answer()
        }
    }

    private func answer() {
        let path = request.url?.path ?? ""
        let methodPrefix = "\(request.httpMethod ?? "GET") "
        let body = Self.routes.first { $0.key.hasPrefix(methodPrefix) && path.hasSuffix($0.key.dropFirst(methodPrefix.count)) }?.value
            ?? Self.routes.first { $0.key.hasPrefix("/") && path.hasSuffix($0.key) }?.value
        var headers = ["Content-Type": "application/json"]
        if request.httpMethod == "GET", request.url?.query?.contains("origin=skill") == true {
            headers["ETag"] = Self.skillSourceETag
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol its body as a stream.
    private static func sortedJSONBody(of request: URLRequest) -> String {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: sorted, as: UTF8.self)
    }
}

/// `pairing-approval`: an empty screen over which the approval sheet presents, the way the
/// app root presents it, for the fixture server's one pending approval.
@MainActor
final class PairingApprovalPreviewScreen: UIViewController {
    private let root: AppRootEnvironment
    private let controller = PairingApprovalController()
    private lazy var presentation = PairingApprovalPresentation(controller: controller, root: root, anchor: self)

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
        title = "Pairing approval host"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = root.themeStore.backgroundColor
        controller.startSyncing(coordinator: root.coordinator)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentation.anchorDidAppear()
    }

    override func updateProperties() {
        super.updateProperties()
        presentation.update()
    }
}

#endif
