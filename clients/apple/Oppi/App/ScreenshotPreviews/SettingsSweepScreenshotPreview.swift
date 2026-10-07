#if DEBUG
import SwiftUI

/// The settings-like pages outside App, Server, and Workspace Settings: the
/// real views over one fixture server, with API pages answered by
/// `SettingsSweepFixtureURLProtocol`. `SCREENSHOT_SWEEP_PAGE` picks the page:
/// `tailscale`, `ssh-preflight`, `ssh-preflight-result`, `ssh-preflight-mismatch`,
/// `ssh-hosts`, `ssh-setup`, `share-redaction`, `mcp`, `mcp-workspace`,
/// `mcp-detail`, `mcp-add`, `quick-comments`, `quick-comment-editor`,
/// `auto-title`, `theme-import`, `dictionary`, `dictionary-workspace`,
/// `skills`, `skill-detail`, `extensions`, `extension-detail`,
/// `agents-pi`, `workspace-create`, `workspace-create-configure`.
/// `SCREENSHOT_COLOR_SCHEME=dark` selects the dark theme.
struct SettingsSweepScreenshotPreview: View {
    private let coordinator: ConnectionCoordinator
    private let connection: ServerConnection
    private let server: PairedServer
    private let client: APIClient
    @State private var navigation = AppNavigation()
    private let themeStore: ThemeStore
    private let page: String

    private static let skills: [ServerSkillSummary] = [
        ServerSkillSummary(
            id: "release", name: "release", description: "Review release readiness before shipping.",
            provenance: .init(kind: .piAgent, label: "~/.pi/agent/skills"), path: nil,
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
            kind: .file, provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"), path: nil,
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
        ScreenshotVolatileDefaults.applyDarkTheme(environment["SCREENSHOT_COLOR_SCHEME"] == "dark")
        themeStore = ThemeStore()
        page = environment["SCREENSHOT_SWEEP_PAGE"] ?? "tailscale"

        let credentials = ServerCredentials(
            host: "mac-studio.tail1234.ts.net",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            serverFingerprint: "sha256:preview-host"
        )
        guard let server = PairedServer(from: credentials, sortOrder: 0) else {
            preconditionFailure("The sweep preview needs a server fingerprint")
        }
        self.server = server

        Self.installFixtureRoutes()
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
        connection.serverResourceStore.replaceExtensions(Self.extensions, serverId: server.id)
        connection.serverResourceStore.switchServer(to: server.id)
        self.connection = connection

        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        coordinator.installPreviewConnection(connection, serverId: server.id)
        self.coordinator = coordinator

        switch page {
        case "tailscale":
            Self.applyTailnetFixture()
        case "ssh-hosts":
            Self.seedSSHHosts()
        default:
            break
        }
    }

    var body: some View {
        content
            .environment(coordinator)
            .environment(coordinator.serverStore)
            .withServerScopedEnvironment(connection)
            .environment(QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults))
            .environment(navigation)
            .environment(themeStore)
            .environment(\.theme, themeStore.appTheme)
            .environment(\.themeID, themeStore.activeThemeID)
            .tint(.themeBlue)
            .preferredColorScheme(themeStore.preferredColorScheme)
            .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case "share-redaction":
            ShareRedactionSettingsPreview()
        case "workspace-create":
            WorkspaceCreateView(server: server)
        case "workspace-create-configure":
            WorkspaceCreateView(server: server, prefillName: "oppi", prefillPath: "~/workspace/oppi")
        default:
            NavigationStack {
                pushedPage
            }
        }
    }

    @ViewBuilder
    private var pushedPage: some View {
        switch page {
        case "ssh-preflight": SSHPreflightView()
        case "ssh-preflight-result":
            SSHPreflightView(previewReport: Self.sshReport, host: "mac-studio.tail1234.ts.net")
        case "ssh-preflight-mismatch":
            SSHPreflightView(
                previewFailure: .hostKeyMismatch(saved: Self.hostKeyA, presented: Self.hostKeyB),
                host: "mac-studio.tail1234.ts.net"
            )
        case "ssh-hosts": SSHTerminalHostListView()
        case "ssh-setup": SSHTerminalSetupView()
        case "mcp": McpServersView(scopeId: McpScopeSnapshot.globalId)
        case "mcp-detail":
            McpServerDetailView(
                scope: Self.mcpGlobal, entry: Self.mcpGlobal.servers[0],
                client: client, serverId: server.id, serverName: server.name,
                signIn: McpSignInOwner()
            )
        case "mcp-add":
            McpAddServerView(
                client: client, scope: Self.mcpGlobal, serverName: server.name, onAdded: {}
            )
        case "quick-comments": QuickCommentsSettingsView()
        case "quick-comment-editor":
            QuickCommentEditorView(
                template: QuickCommentTemplate.builtInDefaults[0], isNew: false, onSave: { _ in }, onCancel: {}
            )
        case "auto-title": AutoTitleSettingsView()
        case "theme-import": ThemeImportView()
        case "dictionary": DictationDictionaryView(workspaceId: nil)
        case "dictionary-workspace": DictationDictionaryView(workspaceId: "preview-ws")
        case "skills": ServerSkillsView()
        case "skill-detail":
            ServerSkillDetailView(target: .init(serverId: server.id, kind: .skill, resourceId: "release"))
        case "extensions": ServerExtensionsView()
        case "extension-detail":
            ServerExtensionDetailView(target: .init(serverId: server.id, kind: .extension, resourceId: "workflow"))
        case "agents-pi": PiAgentDetailView()
        default: TailnetSettingsView(previewProbes: Self.tailnetProbes)
        }
    }

    // MARK: - Fixtures

    private static let hostKeyA = SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB0Rj5G0b3Y8Hn0m6WmTz7J1cC0Hf3p1G7f3vJmP7oXw")
    private static let hostKeyB = SSHHostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJq2m1m3m8k7mQ4o5r1y2u3i4o5p6a7s8d9f0g1h2j3k")

    private static let sshReport = SSHPreflightReport(
        user: "chenda", kernel: "Darwin", release: "25.0.0", arch: "arm64",
        macOSVersion: "26.0", osRelease: nil,
        nodePath: "/opt/homebrew/bin/node", nodeVersion: "v24.1.0", npmPath: "/opt/homebrew/bin/npm",
        gitPath: "/usr/bin/git", oppiPath: nil, tailscalePath: "/usr/local/bin/tailscale",
        oppiStatus: nil, hasCommandLineTools: true
    )

    private static let tailnetPeers: [TailnetPeer] = [
        TailnetPeer(id: "n-mac-studio", hostName: "mac-studio", dnsName: "mac-studio.tail1234.ts.net", os: "macOS", tailscaleIPs: ["100.64.1.2"], isOnline: true),
        TailnetPeer(id: "n-mac-mini", hostName: "mac-mini", dnsName: "mac-mini.tail1234.ts.net", os: "macOS", tailscaleIPs: ["100.64.1.4"], isOnline: true),
        TailnetPeer(id: "n-nas", hostName: "nas", dnsName: "nas.tail1234.ts.net", os: "linux", tailscaleIPs: ["100.64.1.5"], isOnline: true),
        TailnetPeer(id: "n-devbox", hostName: "devbox", dnsName: "devbox.tail1234.ts.net", os: "linux", tailscaleIPs: ["100.64.1.6"], isOnline: true),
    ]

    private static let tailnetProbes: [String: TailnetPeerProbe] = [
        "n-mac-mini": .ready,
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
        var values: [String: Any] = [AppPreferences.Experiments.sshTerminalKey: true]
        values[SSHTerminalProfileStore.catalogKey] = try? JSONEncoder().encode(catalog)
        ScreenshotVolatileDefaults.apply(values)
    }

    private static func installFixtureRoutes() {
        let encoder = JSONEncoder()
        func json(_ value: some Encodable) -> Data { (try? encoder.encode(value)) ?? Data() }

        struct Themes: Encodable { let themes: [RemoteThemeSummary] }
        struct Models: Encodable { let models: [ModelInfo] }

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
            "/server/auto-title": json(APIClient.AutoTitleConfig(enabled: true, model: "anthropic/claude-haiku-5")),
            "/dictation/dictionary/global": Data(#"{"revision":3,"phrases":["Oppi","Tailscale","Herdr","Kypu","SwiftUI","Nerd Font Symbols Mono Extended Family Name That Is Long Enough To Wrap Past The Row"],"provider":"xai"}"#.utf8),
            "/dictation/dictionary/workspaces/preview-ws": Data(#"{"revision":1,"phrases":["oppi-dev","WorkspaceStore"],"provider":null}"#.utf8),
            "/mcp/scopes/global/servers": json(McpServersResponse(scope: mcpGlobal, activeSignIn: nil)),
            "/server/resources/pi/system-prompt": json(PiSystemPromptSnapshot(
                source: .default, path: "~/.pi/agent/SYSTEM.md", resolvedPath: nil, content: "You are a coding agent."
            )),
            "/server/resources/pi/default-tools": json(PiDefaultToolsSnapshot(defaultTools: ["+codemode"])),
            "/server/resources/extensions": json(ServerExtensionCatalog(
                extensions: extensions,
                builtInTools: [ServerToolSummary(name: "read"), ServerToolSummary(name: "bash")],
                optionalTools: [ServerToolSummary(name: "codemode")]
            )),
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
        ]
    }
}

/// Answers `APIClient` requests from a fixed path → JSON table. Anything else is a 404.
final class SettingsSweepFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.routes.first { path.hasSuffix($0.key) }?.value
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body ?? Data(#"{"error":"not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
