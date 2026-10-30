#if DEBUG
import SwiftUI

/// The settings-like pages outside App, Server, and Workspace Settings: the
/// real views over one fixture server, with API pages answered by
/// `SettingsSweepFixtureURLProtocol`. `SCREENSHOT_SWEEP_PAGE` picks the page:
/// `ssh-hosts`, `mcp`, `theme-import`,
/// `skills`, `skills-offline` (the seeded catalog, cached while the refresh fails), `skill-detail`, `skill-browser`, `extensions`, `extensions-offline` (the catalog
/// request fails over a cached catalog), `extensions-unavailable` (the
/// request fails with nothing cached), `extensions-builtin-only`, `extension-detail`,
/// `agents-pi`, `workspace-create`, `workspace-create-configure`.
/// Router modal pages (`RouterSettingsModalsUITests`): `agents`,
/// `agents-pi-file`, `schedules`, `skill-file-review`, `skill-file-edit` (a
/// server that also edits Skill files in place),
/// `pairing-approval`, `onboarding-add-server`, `onboarding-tailscale` (the
/// same onboarding over a running tailnet); `mcp`, `theme-import`, and
/// `agents-pi` serve them too. `SCREENSHOT_SWEEP_SHOWS_WRITES=1` shows the
/// last write the fixture server received (`settingsSweep.lastWrite`);
/// `SCREENSHOT_SWEEP_WRITE_DELAY=<seconds>` holds each write's answer that long.
/// `SCREENSHOT_COLOR_SCHEME=dark|light|oled|night|custom:Paper` selects that theme.
struct SettingsSweepScreenshotPreview: View {
    private let coordinator: ConnectionCoordinator
    private let connection: ServerConnection
    private let server: PairedServer
    private let client: APIClient
    private let themeStore: ThemeStore
    private let root: AppRootEnvironment
    private let page: String
    private let showsWrites: Bool
    @State private var writes = SettingsSweepWrites.shared

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
        themeStore = ThemeStore()
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
        if page == "mcp" {
            // The MCP screens wait for `apiClientReady`, so their connection is
            // a ready one whose requests the fixture answers, as the Router and
            // Metrics previews build theirs.
            if coordinator.switchToServer(server) {
                coordinator.connection(for: server.id)?.setAPIClientForTesting(client)
            }
        } else {
            coordinator.installPreviewConnection(connection, serverId: server.id)
        }
        self.coordinator = coordinator

        // The app root: router modals present with these services.
        root = AppRootEnvironment(
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
    }

    var body: some View {
        content
            .appRootEnvironment(root)
            .publishesAppRootToWindow(root)
            .preferredColorScheme(themeStore.preferredColorScheme)
            .accessibilityIdentifier("screenshot.ready")
            // After the ready identifier, which would replace this one.
            .overlay(alignment: .bottomLeading) {
                if showsWrites {
                    Text(writes.lastWrite)
                        .font(.caption2)
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("settingsSweep.lastWrite")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case "workspace-create":
            RouterPreviewControllerStack(root: root) {
                WorkspaceCreateViewController(root: root, server: server)
            }
            .ignoresSafeArea()
        case "workspace-create-configure":
            RouterPreviewControllerStack(root: root) {
                WorkspaceCreateViewController(
                    root: root,
                    server: server,
                    prefillName: "oppi",
                    prefillPath: "~/workspace/oppi"
                )
            }
            .ignoresSafeArea()
        case "onboarding-add-server", "onboarding-tailscale":
            // The simulator has no camera; show Scan QR Code as a phone would.
            OnboardingPreviewHost(root: root)
                .ignoresSafeArea()
        case "pairing-approval":
            RouterPreviewControllerStack(root: root) { [root] in PairingApprovalPreviewScreen(root: root) }
                .ignoresSafeArea()
        // Shell routes the router hosts directly: search lives in its bar.
        case "skills", "skills-offline":
            RouterPreviewControllerStack(root: root) { ServerSkillsViewController(root: root) }
                .ignoresSafeArea()
        case "extensions", "extensions-offline", "extensions-builtin-only":
            RouterPreviewControllerStack(root: root) { ServerExtensionsViewController(root: root) }
                .ignoresSafeArea()
        case "extensions-unavailable":
            // The disk cache outlives launches: an earlier page's saved catalog
            // would show, so the screen mounts once it is replaced by an empty one.
            CatalogCacheCleared(serverId: server.id) {
                RouterPreviewControllerStack(root: root) { ServerExtensionsViewController(root: root) }
                    .ignoresSafeArea()
            }
        case "mcp":
            RouterPreviewControllerStack(root: root) { [root] in
                McpServersViewController(scopeId: McpScopeSnapshot.globalId, root: root)
            }
            .ignoresSafeArea()
        case "ssh-hosts":
            RouterPreviewControllerStack(root: root) { SSHTerminalHostListViewController() }
                .ignoresSafeArea()
        case "theme-import":
            RouterPreviewControllerStack(root: root) { ThemeImportViewController(root: root) }
                .ignoresSafeArea()
        case "schedules":
            RouterPreviewControllerStack(root: root) { ScheduleListViewController(root: root) }
                .ignoresSafeArea()
        case "agents":
            RouterPreviewControllerStack(root: root) { AgentListViewController(root: root) }
                .ignoresSafeArea()
        case "agents-pi", "agents-pi-file":
            RouterPreviewControllerStack(root: root) { PiAgentDetailViewController(root: root) }
                .ignoresSafeArea()
        case "extension-detail":
            RouterPreviewControllerStack(root: root) { [server, root, connection] in
                ServerExtensionDetailViewController(
                    target: .init(serverId: server.id, kind: .extension, resourceId: "workflow"),
                    root: root,
                    connection: connection
                )
            }
            .ignoresSafeArea()
        case "skill-detail":
            RouterPreviewControllerStack(root: root) { [server, root, connection] in
                ServerSkillDetailViewController(
                    target: .init(serverId: server.id, kind: .skill, resourceId: "release"),
                    root: root,
                    connection: connection
                )
            }
            .ignoresSafeArea()
        case "skill-browser":
            RouterPreviewControllerStack(root: root) { [server, root, connection] in
                ServerSkillBrowserViewController(
                    target: .init(serverId: server.id, resourceId: "release"),
                    root: root,
                    connection: connection
                )
            }
            .ignoresSafeArea()
        case "skill-file-review":
            skillFilePage
        case "skill-file-edit":
            // The editor needs the server's file-editing capability first.
            ServerInfoLoaded(client: client) { skillFilePage }
        default:
            Text("Unknown SCREENSHOT_SWEEP_PAGE \(page)")
        }
    }

    /// The release Skill's SKILL.md, the route's screen at the stack root.
    private var skillFilePage: some View {
        RouterPreviewControllerStack(root: root) { [server, root, connection] in
            ServerSkillFileViewController(
                target: .init(serverId: server.id, resourceId: "release", path: "SKILL.md"),
                root: root,
                connection: connection
            )
        }
        .ignoresSafeArea()
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

/// Add Server onboarding embedded the way the app root embeds first-run
/// onboarding, with Scan QR Code offered.
private struct OnboardingPreviewHost: UIViewControllerRepresentable {
    let root: AppRootEnvironment

    func makeUIViewController(context: Context) -> OnboardingViewController {
        OnboardingViewController(root: root, mode: .addServer, canScan: true)
    }

    func updateUIViewController(_ controller: OnboardingViewController, context: Context) {}
}

/// Shows `content` after the client has read `/server/info`, the way a
/// connected app knows its server's capabilities before a file opens.
private struct ServerInfoLoaded<Content: View>: View {
    let client: APIClient
    @ViewBuilder let content: () -> Content
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded { content() } else { ProgressView() }
        }
        .task {
            _ = try? await client.serverInfo()
            loaded = true
        }
    }
}

/// Shows `content` once the server's saved Skills and Extensions catalog on disk
/// is replaced by an empty one.
private struct CatalogCacheCleared<Content: View>: View {
    let serverId: String
    @ViewBuilder let content: () -> Content
    @State private var cleared = false

    var body: some View {
        Group {
            if cleared { content() } else { ProgressView() }
        }
        .task {
            await TimelineCache.shared.saveServerResourceCatalog(
                ServerResourceCatalogSnapshot(
                    skills: [], extensions: [], builtInTools: [], savedAt: Date(),
                    skillsLoaded: false, extensionsLoaded: false, skillsSavedAt: nil, extensionsSavedAt: nil
                ),
                serverId: serverId
            )
            cleared = true
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
