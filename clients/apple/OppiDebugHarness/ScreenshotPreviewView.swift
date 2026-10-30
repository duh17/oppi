#if DEBUG
import Foundation
import SwiftUI
import UIKit

// MARK: - Configuration

enum ScreenshotPreviewConfig {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--screenshot-preview")
    }

    static var screen: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_SCREEN"] ?? "workspace-settings"
    }
}

/// Debug-only: `SCREENSHOT_ORIENTATION=landscape-left|landscape-right|portrait` rotates the scene so
/// Duo landscape poses (vertical rail on the trailing edge) can be captured
/// without driving Simulator.app.
@MainActor
enum ScreenshotPreviewOrientation {
    static func applyRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SCREENSHOT_ORIENTATION"],
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        let mask: UIInterfaceOrientationMask = switch raw {
        case "landscape", "landscape-right": .landscapeRight
        case "landscape-left": .landscapeLeft
        default: .portrait
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

/// Preview-only defaults in the argument domain: a preview reads them like
/// real preferences, and nothing is written to the app's persistent defaults,
/// which a simulator keeps across launches and test runs.
enum ScreenshotVolatileDefaults {
    static func apply(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments.merge(values) { _, new in new }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Call before `ThemeStore()`: its setters would persist the theme.
    static func applyTheme(_ themeID: ThemeID) {
        apply([
            "\(AppIdentifiers.subsystem).theme.mode": ThemeMode.manual.rawValue,
            ThemeID.storageKey: themeID.rawValue,
        ])
    }

    /// Pins the theme `SCREENSHOT_COLOR_SCHEME` names: a built-in (`dark`,
    /// `light`, `oled`, `night`) or an imported one (`custom:Paper`, from the
    /// settings fixtures). Call before `ThemeStore()`.
    static func applyThemeScheme(_ scheme: String?) {
        guard let scheme, ["dark", "light", "oled", "night"].contains(scheme) || scheme.hasPrefix("custom:") else { return }
        if scheme.hasPrefix("custom:") { applyImportedThemes() }
        applyTheme(ThemeID(rawValue: scheme))
    }

    /// The two imported fixture themes the settings captures use.
    static func applyImportedThemes() {
        apply(["\(AppIdentifiers.subsystem).customThemes": SettingsPageScreenshotContent.importedThemes])
    }

    /// Call before `ThemeStore()`: its setters would persist the theme.
    static func applyDarkTheme(_ enabled: Bool) {
        guard enabled else { return }
        apply([
            "\(AppIdentifiers.subsystem).theme.mode": ThemeMode.manual.rawValue,
            ThemeID.storageKey: ThemeID.dark.rawValue,
        ])
    }
}

// MARK: - Root Preview View

/// Launches a standalone screen with mock data for screenshot capture in UI tests.
struct ScreenshotPreviewView: View {
    var body: some View {
        switch ScreenshotPreviewConfig.screen {
        case "workspace-settings":
            WorkspaceSettingsScreenshotPreview()
        case "settings-sweep":
            SettingsSweepScreenshotPreview()
        case "ssh-terminal":
            SSHTerminalScreenshotPreview()
        case "ssh-terminal-status-blocked":
            SSHTerminalScreenshotPreview(status: .blocked)
        case "router-routes":
            RouterRoutesPreview()
        case "router-modal-sites":
            RouterModalSitesPreview()
        case "chat-routes":
            ChatRoutesHarnessPreview()
        case "ask-card-intent-regression":
            AskCardIntentRegressionPreview()
        case "ask-card-tall-scroll":
            AskCardTallScrollPreview()
        case "session-timeline":
            SessionTimelinePreview()
        case "file-browser-motion":
            FileBrowserMotionPreview()
        case "review-file-motion":
            ReviewFileMotionPreview()
        case "streaming-flicker":
            StreamingFlickerPreviewView()
        case "feature-tip-p0":
            FeatureEducationP0TipPreview()
        case "audio-script-reader":
            AudioScriptReaderPreview()
        case "workspace-shell":
            WorkspaceShellScreenshotPreview()
        case "chat-top-bar-default":
            ChatTopBarScreenshotPreview(
                order: ChatTopBarAction.allCases,
                shown: ChatTopBarAction.defaultShown
            )
        case "chat-top-bar-terminal":
            ChatTopBarScreenshotPreview(
                order: [.terminal, .files, .git, .outline, .context],
                shown: [.terminal, .files]
            )
        case "chat-top-bar-all":
            ChatTopBarScreenshotPreview(
                order: ChatTopBarAction.allCases,
                shown: Set(ChatTopBarAction.allCases)
            )
        case "chat-top-bar-none":
            ChatTopBarScreenshotPreview(
                order: ChatTopBarAction.allCases,
                shown: []
            )
        case "chat-top-bar-reordered":
            ChatTopBarScreenshotPreview(
                order: [.outline, .files, .context, .git, .terminal],
                shown: Set(ChatTopBarAction.allCases)
            )
        case "settings-chat", "settings-chat-top-bar":
            SettingsPageScreenshotPreview(screen: ScreenshotPreviewConfig.screen)
        default:
            Text("Unknown screen: \(ScreenshotPreviewConfig.screen)")
        }
    }
}

/// The UIKit router with real screens and fixture services, no network: a
/// `RouterNavigationController` whose root is a screen hosted by `HostFactory`
/// (large title, bottom bar). Quick Comments is pushed and opens its editor
/// sheet (detents, navigation) and the icon popover; Edit Agent is a full-screen
/// modal that pushes its Tools page; Edit Schedule opens the time zone search
/// sheet; both editors open the model picker. The editors save to an in-process
/// stub server, and "Last save sent" shows what reached it.
/// `SCREENSHOT_COLOR_SCHEME=light|dark` pins the theme.
private struct RouterRoutesPreview: View {
    private let root: AppRootEnvironment

    init() {
        switch ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] {
        case "dark":
            ScreenshotVolatileDefaults.applyDarkTheme(true)
        case "light":
            ScreenshotVolatileDefaults.apply([
                "\(AppIdentifiers.subsystem).theme.mode": ThemeMode.manual.rawValue,
                ThemeID.storageKey: ThemeID.light.rawValue,
            ])
        default:
            break
        }
        root = AppRootEnvironment(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            navigation: AppNavigation(),
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )
    }

    var body: some View {
        RouterRoutesStack(root: root)
            .ignoresSafeArea()
            // Modals present from the window, so UIKit screens they show (the
            // model picker) find this root, and its theme, in their traits.
            .publishesAppRootToWindow(root)
    }
}

private struct RouterRoutesStack: UIViewControllerRepresentable {
    let root: AppRootEnvironment

    func makeUIViewController(context: Context) -> RouterNavigationController {
        let menu = HostFactory.screen(root: root, bars: ScreenBars(largeTitle: true, showsToolbar: true)) {
            RouterRoutesMenu()
        }
        let navigation = RouterNavigationController(rootViewController: menu)
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {}
}

private struct RouterRoutesMenu: View {
    @Environment(\.screenNavigator) private var navigator
    @Environment(\.appRootEnvironment) private var appRoot
    @Environment(ServerConnection.self) private var connection
    @State private var dismissedModals = 0
    @State private var editingAgent: StoredAgentDefinition?
    @State private var editsSchedule = false
    @State private var saves = RouterRoutesSaves.shared

    var body: some View {
        List {
            Button("Quick Comments") {
                if let appRoot { navigator.push(QuickCommentsViewController(root: appRoot)) }
            }
            .accessibilityIdentifier("routerRoutes.quickComments")

            Button("Edit Agent") {
                editingAgent = RouterRoutesFixtures.agent
            }
            .accessibilityIdentifier("routerRoutes.editAgent")
            .routerModal(
                item: $editingAgent,
                presentation: .fullScreen.inNavigation(),
                onDismiss: { dismissedModals += 1 },
                screen: { [connection] agent in
                    .controller({
                        AgentNativeEditViewController(
                            agent: agent,
                            apiClient: RouterRoutesFixtures.api,
                            connection: connection,
                            serverName: "mac-studio"
                        ) { _ in }
                    })
                }
            )

            Button("Edit Schedule") {
                editsSchedule = true
            }
            .accessibilityIdentifier("routerRoutes.editSchedule")
            .routerScreenModal(
                isPresented: $editsSchedule,
                presentation: .fullScreen.inNavigation(),
                onDismiss: { dismissedModals += 1 },
                screen: { [connection] in
                    .controller {
                        ScheduleNativeEditViewController(
                            schedule: RouterRoutesFixtures.schedule,
                            apiClient: RouterRoutesFixtures.api,
                            connection: connection,
                            serverName: "mac-studio"
                        ) { _, _ in }
                    }
                }
            )

            Section("Last save sent") {
                Text(saves.lastSave)
                    .accessibilityIdentifier("routerRoutes.lastSave")
            }
        }
        .navigationTitle("Router Routes")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Text("Dismissed \(dismissedModals)")
                    .accessibilityIdentifier("routerRoutes.dismissedModals")
            }
        }
    }
}

/// What the editors last sent to the stub server, so a save is visible.
@MainActor @Observable
private final class RouterRoutesSaves {
    static let shared = RouterRoutesSaves()
    var lastSave = "none"
}

private enum RouterRoutesFixtures {
    static let agent = StoredAgentDefinition(
        id: "agent-router-routes",
        name: "Design Reviewer",
        icon: .defaultValue,
        description: nil,
        status: .active,
        version: 1,
        definition: AgentDefinition(
            name: "Design Reviewer",
            icon: .defaultValue,
            sessionDefaults: AgentSessionDefaults(tools: ["read"])
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        archivedAt: nil
    )

    static let scheduleSummary = AgentScheduleSummary(
        id: "schedule-router-routes",
        name: "Nightly digest",
        status: .active,
        trigger: .every(intervalMs: 3_600_000, timeZone: "America/Los_Angeles"),
        action: AgentScheduleActionSummary(
            type: .newSession,
            workspaceId: "ws-router-routes",
            sessionId: nil,
            agentId: nil,
            promptChars: 31
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        archivedAt: nil
    )

    /// A client whose requests the stub below answers in-process.
    static let api: APIClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterRoutesURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://router-routes.oppi") ?? URL(fileURLWithPath: "/"),
            token: "preview-token",
            configuration: config
        )
    }()

    static let schedule = AgentSchedule(
        id: "schedule-router-routes",
        name: "Nightly digest",
        status: .active,
        trigger: .every(intervalMs: 3_600_000, timeZone: "America/Los_Angeles"),
        action: .newSession(
            workspaceId: "ws-router-routes",
            prompt: "Summarize yesterday's sessions.",
            agentId: nil,
            model: nil,
            thinkingLevel: nil,
            worktreeId: nil,
            name: nil
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        archivedAt: nil
    )
}

/// Answers the editors' saves with the fixtures and records what they sent:
/// the agent's tool policy and the schedule's time zone.
private final class RouterRoutesURLProtocol: URLProtocol {
    private struct AgentBody: Encodable { let agent: StoredAgentDefinition }
    private struct ScheduleBody: Encodable { let schedule: AgentScheduleSummary }
    private struct AgentsBody: Encodable { let agents: [String] }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "router-routes.oppi"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let sent = Self.jsonBody(of: request)
        let response: Data?
        switch (request.httpMethod, path) {
        case ("PATCH", "/agents/\(RouterRoutesFixtures.agent.id)"):
            let defaults = sent?["sessionDefaults"] as? [String: Any]
            let tools = (defaults?["tools"] as? [String])?.joined(separator: ",") ?? "inherit"
            Self.record("agent tools=\(tools)")
            response = try? JSONEncoder().encode(AgentBody(agent: RouterRoutesFixtures.agent))
        case ("PATCH", "/schedules/\(RouterRoutesFixtures.scheduleSummary.id)"):
            let trigger = sent?["trigger"] as? [String: Any]
            Self.record("schedule timeZone=\(trigger?["timeZone"] as? String ?? "none")")
            response = try? JSONEncoder().encode(ScheduleBody(schedule: RouterRoutesFixtures.scheduleSummary))
        case ("GET", "/agents"):
            response = try? JSONEncoder().encode(AgentsBody(agents: []))
        default:
            response = nil
        }
        guard let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response == nil ? 404 : 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func record(_ summary: String) {
        Task { @MainActor in RouterRoutesSaves.shared.lastSave = summary }
    }

    /// URLSession hands a protocol its body as a stream.
    private static func jsonBody(of request: URLRequest) -> [String: Any]? {
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
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// `SCREENSHOT_SCREEN=chat-routes`: the production chat over
/// the `chat-routes` fixtures with Files, Git, Outline, and Context pinned in
/// the argument domain. These screens are about the panels the bar opens, not
/// the default bar (`chat-top-bar-default`), and a layout saved on this
/// simulator cannot change what they show.
private struct ChatRoutesHarnessPreview: View {
    init() {
        let layout = ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: [.files, .git, .outline, .context])
        ScreenshotVolatileDefaults.apply([
            AppPreferences.ChatTopBar.orderKey: layout.storedOrder,
            AppPreferences.ChatTopBar.shownKey: layout.storedShown,
        ])
    }

    var body: some View { ChatRoutesHarnessView() }
}

/// `SCREENSHOT_SCREEN=chat-top-bar-default`, `-terminal`, `-all`, `-none`, and
/// `-reordered`: the chat's bar over the `chat-routes` fixtures with a chosen
/// top bar. The layout goes in the volatile argument domain, so the simulator's
/// saved settings are untouched and a test's bar does not depend on what an
/// earlier run left behind.
private struct ChatTopBarScreenshotPreview: View {
    init(
        order: [ChatTopBarAction],
        shown: Set<ChatTopBarAction>
    ) {
        let layout = ChatTopBarLayout(order: order, shown: shown)
        ScreenshotVolatileDefaults.apply([
            AppPreferences.ChatTopBar.orderKey: layout.storedOrder,
            AppPreferences.ChatTopBar.shownKey: layout.storedShown,
        ])
    }

    var body: some View { ChatRoutesHarnessView() }
}

/// `SCREENSHOT_SCREEN=settings-chat` / `settings-chat-top-bar`: a UIKit settings page as the root of a router stack, over fixture services.
/// The page shares the app's `ThemeStore`. Nothing here calls a server.
private struct SettingsPageScreenshotPreview: View {
    let screen: String
    @Environment(\.appRootEnvironment) private var appRoot

    var body: some View {
        guard let appRoot else {
            preconditionFailure("SettingsPageScreenshotPreview needs appRootEnvironment(_:) above it")
        }
        // The page shares the app's own `ThemeStore`, the one that owns the
        // window: a theme chosen on the page then re-themes the window, as in
        // the app. A store of its own would change only itself.
        return SettingsPageScreenshotContent(screen: screen, themeStore: appRoot.themeStore)
    }
}

private struct SettingsPageScreenshotContent: View {
    let screen: String

    @State private var root: AppRootEnvironment

    init(screen: String, themeStore: ThemeStore) {
        self.screen = screen
        // Every settings page can be captured in an imported theme
        // (`SCREENSHOT_COLOR_SCHEME=custom:Paper`), not only Appearance.
        ScreenshotVolatileDefaults.applyImportedThemes()
        _root = State(initialValue: AppRootEnvironment(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            navigation: AppNavigation(),
            themeStore: themeStore,
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        ))
    }

    var body: some View {
        RouterPreviewControllerStack(root: root) {
            switch screen {
            case "settings-chat-top-bar": SettingsChatTopBarViewController()
            default: SettingsChatViewController(root: root)
            }
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("screenshot.ready")
    }

    /// Two imported themes, one light and one dark, as `CustomThemeStore` keeps
    /// them. Only the base colors differ; every other token follows from them.
    fileprivate static var importedThemes: Data {
        func theme(
            _ name: String, scheme: String,
            bg: String, bgDark: String, highlight: String, fg: String, dim: String, comment: String,
            blue: String, cyan: String, green: String, orange: String, purple: String, red: String, yellow: String
        ) -> [String: Any] {
            let colors: [String: String] = [
                "bg": bg, "bgDark": bgDark, "bgHighlight": highlight, "fg": fg, "fgDim": dim, "comment": comment,
                "blue": blue, "cyan": cyan, "green": green, "orange": orange, "purple": purple, "red": red, "yellow": yellow,
                "thinkingText": dim, "userMessageBg": highlight, "userMessageText": fg,
                "toolPendingBg": highlight, "toolSuccessBg": highlight, "toolErrorBg": highlight,
                "toolTitle": fg, "toolOutput": dim, "mdHeading": blue, "mdLink": cyan, "mdLinkUrl": comment,
                "mdCode": cyan, "mdCodeBlock": green, "mdCodeBlockBorder": highlight, "mdQuote": dim,
                "mdQuoteBorder": highlight, "mdHr": highlight, "mdListBullet": orange,
                "toolDiffAdded": green, "toolDiffRemoved": red, "toolDiffContext": comment,
                "syntaxComment": comment, "syntaxKeyword": purple, "syntaxFunction": blue, "syntaxVariable": fg,
                "syntaxString": green, "syntaxNumber": orange, "syntaxType": cyan, "syntaxOperator": fg,
                "syntaxPunctuation": dim, "thinkingOff": highlight, "thinkingMinimal": comment, "thinkingLow": blue,
                "thinkingMedium": cyan, "thinkingHigh": purple, "thinkingXhigh": red,
            ]
            return ["name": name, "colorScheme": scheme, "colors": colors]
        }
        let themes = [
            "Paper": theme(
                "Paper", scheme: "light",
                bg: "#F4EFE6", bgDark: "#E8E1D3", highlight: "#DDD3BF", fg: "#3B3226", dim: "#6A5E4C", comment: "#7F7360",
                blue: "#2F5D9C", cyan: "#1F7A80", green: "#4B7A2E", orange: "#B2661B", purple: "#7A4C9E", red: "#B03A3A", yellow: "#A68416"
            ),
            "Neon Harbor": theme(
                "Neon Harbor", scheme: "dark",
                bg: "#0B1020", bgDark: "#060914", highlight: "#1B2442", fg: "#E4ECFF", dim: "#9CB0DC", comment: "#8498C4",
                blue: "#4DA3FF", cyan: "#3DF0E0", green: "#5DF08A", orange: "#FFB454", purple: "#C08CFF", red: "#FF6B8A", yellow: "#FFE066"
            ),
        ]
        return (try? JSONSerialization.data(withJSONObject: themes)) ?? Data()
    }
}

// MARK: - Router modal sites

/// Real presenters whose modals the router owns, over fixture services and an
/// in-process stub server. `SCREENSHOT_MODAL_SITE` picks the presenter:
/// `root` (the app root's extension dialog, notice, and What's New, with
/// trigger buttons and what the dialog sent), `document` (the document viewer
/// modifier), `stash` (the staged-comment sheet), `inbox-now-playing` and
/// `workspace-now-playing` (the full-screen player over active playback),
/// `inbox-threads` and `workspace-threads` (the session lists over a launch tree that spans
/// two workspaces; tap `thread.nav.thread-root` to open it), and `quick-session` (its pickers, model sheet, and expanded composer). The
/// presenters and their modals share one app root over the fixture server, in
/// the dark theme. Quick Session starts on plain Pi: an Agent an earlier run
/// remembered would load its default from the stub server, which fails.
private struct RouterModalSitesPreview: View {
    private let site: String
    @State private var root: AppRootEnvironment

    init() {
        ScreenshotVolatileDefaults.applyDarkTheme(true)
        // The dark default holds unless the capture names a theme.
        ScreenshotVolatileDefaults.applyThemeScheme(ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"])
        // Quick Session starts on plain Pi: a remembered Agent would load its
        // default from the stub server, which fails.
        UserDefaults.standard.removeObject(forKey: "\(AppIdentifiers.subsystem).quickSession.lastAgentId")
        let site = ProcessInfo.processInfo.environment["SCREENSHOT_MODAL_SITE"] ?? "quick-session"
        self.site = site
        let navigation = AppNavigation()
        // A thread link's handoff, as the opener leaves it: the list opens this thread root in place.
        if let rootId = ProcessInfo.processInfo.environment["SCREENSHOT_THREAD_FOCUS"] {
            navigation.pendingThreadFocus = AppNavigation.ThreadFocus(
                serverId: RouterModalSitesFixtures.serverId, rootId: rootId
            )
        }
        _root = State(initialValue: AppRootEnvironment(
            coordinator: RouterModalSitesFixtures.makeCoordinator(
                playing: site.hasSuffix("now-playing"),
                threads: site.hasSuffix("-threads")
            ),
            navigation: navigation,
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        ))
    }

    var body: some View {
        page.appRootEnvironment(root)
    }

    @ViewBuilder
    private var page: some View {
        switch site {
        case "root":
            RouterModalSitesRootHost(root: root)
                .ignoresSafeArea()
        case "inbox-now-playing":
            RouterPreviewControllerStack(root: root) { SessionInboxViewController(root: root) }
                .ignoresSafeArea()
        case "inbox-threads":
            RouterPreviewControllerStack(root: root) { SessionInboxViewController(root: root) }
                .ignoresSafeArea()
        case "workspace-threads":
            RouterPreviewControllerStack(root: root) {
                WorkspaceDetailViewController(
                    root: root,
                    target: WorkspaceNavTarget(
                        serverId: RouterModalSitesFixtures.serverId,
                        workspace: RouterModalSitesFixtures.workspaces[0]
                    )
                )
            }
            .ignoresSafeArea()
        case "workspace-now-playing":
            RouterPreviewControllerStack(root: root) {
                WorkspaceDetailViewController(
                    root: root,
                    target: WorkspaceNavTarget(
                        serverId: RouterModalSitesFixtures.serverId,
                        workspace: RouterModalSitesFixtures.workspaces[0]
                    )
                )
            }
            .ignoresSafeArea()
        default:
            // The app puts the theme's appearance on its window.
            QuickSessionPreviewHost(root: root)
                .preferredColorScheme(root.themeStore.preferredColorScheme)
                .ignoresSafeArea()
        }
    }
}

/// Quick Session's controller over the window, the way the app root mounts it.
/// It handles the safe area and the keyboard itself.
private struct QuickSessionPreviewHost: UIViewControllerRepresentable {
    let root: AppRootEnvironment

    func makeUIViewController(context: Context) -> QuickSessionViewController {
        QuickSessionViewController(root: root, onDismiss: {})
    }

    func updateUIViewController(_ controller: QuickSessionViewController, context: Context) {}
}

/// A router screen at the root of a `RouterNavigationController`, the way the
/// router presents a modal with `.inNavigation()`. Previews and harnesses of
/// screens that rely on UIKit bars and the navigator host them here; the app
/// root comes from the window. `content` runs in the screen's own graph: put
/// its fixture environment on it, not on this view.
///
/// The app puts the theme's appearance on its window (`AppRootViewController`),
/// and system chrome that reads the window rather than the screen, such as the
/// Duo's vertical rail, follows it there. A harness's window keeps the system
/// appearance, which drew a light rail beside a dark chat, so this host
/// asks for the theme's color scheme the same way.
struct RouterPreviewNavigation<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.appRootEnvironment) private var root

    var body: some View {
        RouterPreviewNavigationHost(content: content)
            .preferredColorScheme(root?.themeStore.preferredColorScheme)
    }
}

/// `RouterPreviewNavigation` for a UIKit screen (the chat). A new `id`
/// replaces the root screen, the way the shell builds a new screen for
/// another session.
struct RouterPreviewControllerNavigation: View {
    let id: AnyHashable
    let screen: () -> UIViewController
    @Environment(\.appRootEnvironment) private var root

    var body: some View {
        RouterPreviewControllerNavigationHost(id: id, screen: screen)
            .preferredColorScheme(root?.themeStore.preferredColorScheme)
    }
}

private struct RouterPreviewControllerNavigationHost: UIViewControllerRepresentable {
    let id: AnyHashable
    let screen: () -> UIViewController
    @Environment(\.appRootEnvironment) private var root

    final class Coordinator {
        var id: AnyHashable?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> RouterNavigationController {
        guard let root else {
            preconditionFailure("RouterPreviewControllerNavigation needs appRootEnvironment(_:) above it")
        }
        let navigation = RouterNavigationController(rootViewController: screen())
        navigation.traitOverrides.appRootEnvironment = root
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        context.coordinator.id = id
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        navigation.setViewControllers([screen()], animated: false)
    }
}

private struct RouterPreviewNavigationHost<Content: View>: UIViewControllerRepresentable {
    let content: () -> Content
    @Environment(\.appRootEnvironment) private var root

    func makeUIViewController(context: Context) -> RouterNavigationController {
        guard let root else {
            preconditionFailure("RouterPreviewNavigation needs appRootEnvironment(_:) above it")
        }
        let navigation = RouterNavigationController(
            rootViewController: HostFactory.screen(root: root, content: content)
        )
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {}
}

/// A UIKit screen as the root of a router navigation controller, the way the
/// shell hosts SSH Terminal's host list.
struct RouterPreviewControllerStack: UIViewControllerRepresentable {
    let root: AppRootEnvironment
    let makeScreen: () -> UIViewController

    func makeUIViewController(context: Context) -> RouterNavigationController {
        let screen = makeScreen()
        screen.traitOverrides.appRootEnvironment = root
        let navigation = RouterNavigationController(rootViewController: screen)
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {}
}

/// The real workspace shell over fixture services: the stack or split
/// layout the window size picks, its drawer, and every route.
struct WorkspaceShellPreview: UIViewControllerRepresentable {
    let root: AppRootEnvironment

    func makeUIViewController(context: Context) -> WorkspaceShellController {
        WorkspaceShellController(root: root)
    }

    func updateUIViewController(_ shell: WorkspaceShellController, context: Context) {}
}

extension AppRootEnvironment {
    /// A preview's own services; the rest fresh.
    static func preview(
        coordinator: ConnectionCoordinator,
        navigation: AppNavigation = AppNavigation(),
        themeStore: ThemeStore = ThemeStore()
    ) -> Self {
        AppRootEnvironment(
            coordinator: coordinator,
            navigation: navigation,
            themeStore: themeStore,
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )
    }
}

/// The window root's app-wide modals (`AppRootModals`, which `AppRootViewController`
/// owns) over the fixture server's active connection. The dialog's responses go
/// to the connection's send hook, and the page shows the last one.
private struct RouterModalSitesRootHost: UIViewControllerRepresentable {
    let root: AppRootEnvironment

    func makeUIViewController(context: Context) -> RouterModalSitesRootViewController {
        RouterModalSitesRootViewController(root: root)
    }

    func updateUIViewController(_ controller: RouterModalSitesRootViewController, context: Context) {}
}

/// The last answer the connection's send hook saw.
@MainActor @Observable
private final class RouterModalSitesResponse {
    var summary = "none"
}

@MainActor
private final class RouterModalSitesRootViewController: UIViewController {
    private let root: AppRootEnvironment
    private let response = RouterModalSitesResponse()
    private lazy var modals = AppRootModals(root: root, anchor: self)
    private let lastResponseLabel = UILabel()
    private let noticeStateLabel = UILabel()
    private let whatsNewStateLabel = UILabel()
    private var connection: ServerConnection { root.coordinator.activeConnection }

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let connection = connection
        _ = connection.focusedSessionStore.focus(sessionId: "router-modal-sites-session")
        let response = response
        connection._sendMessageForTesting = { @MainActor message in
            guard case .extensionUIResponse(_, let value, _, let cancelled, _) = message else { return }
            response.summary = cancelled == true ? "cancelled" : "value=\(value ?? "")"
        }

        let buttons = [
            button("Extension Dialog", id: "routerModalSites.dialog") { [weak self] in
                self?.showDialog(method: "custom", title: "Pick a Plan")
            },
            button("Extension Editor", id: "routerModalSites.editor") { [weak self] in
                self?.showDialog(method: "editor", title: "Commit Message")
            },
            button("Notice", id: "routerModalSites.notice") { [weak self] in
                self?.connection.extensionToast = "Extension finished.\nDocs https://example.com/docs"
            },
            button("What's New", id: "routerModalSites.whatsNew") { [weak self] in
                self?.root.navigation.showWhatsNew = true
            },
        ]
        for (label, id) in [
            (lastResponseLabel, "routerModalSites.lastResponse"),
            (noticeStateLabel, "routerModalSites.noticeState"),
            (whatsNewStateLabel, "routerModalSites.whatsNewState"),
        ] {
            label.accessibilityIdentifier = id
            label.font = .preferredFont(forTextStyle: .body)
        }
        let stack = UIStackView(arrangedSubviews: buttons + [lastResponseLabel, noticeStateLabel, whatsNewStateLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 80),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        modals.anchorDidAppear()
    }

    override func updateProperties() {
        super.updateProperties()
        let themeStore = root.themeStore
        view.backgroundColor = themeStore.backgroundColor
        view.overrideUserInterfaceStyle = themeStore.userInterfaceStyle
        let palette = themeStore.activeThemeID.palette
        for label in [lastResponseLabel, noticeStateLabel, whatsNewStateLabel] {
            label.textColor = UIColor(palette.fg)
        }
        lastResponseLabel.text = response.summary
        noticeStateLabel.text = connection.extensionToast == nil ? "Notice cleared" : "Notice shown"
        whatsNewStateLabel.text = root.navigation.showWhatsNew ? "What's New shown" : "What's New cleared"
        modals.update()
    }

    private func button(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { _ in action() })
        button.configuration?.title = title
        button.accessibilityIdentifier = id
        return button
    }

    private func showDialog(method: String, title: String) {
        connection.activeExtensionDialog = ExtensionUIRequest(
            id: "router-modal-sites-\(method)",
            sessionId: "router-modal-sites-session",
            method: method,
            title: title,
            message: "The extension is waiting for an answer."
        )
    }
}

/// A fixture server whose stub answers models, worktrees, and Agents.
/// `playing` starts fixture playback, so the Now Playing pill shows.
@MainActor
private enum RouterModalSitesFixtures {
    static let workspaces = [workspace(id: "oppi", icon: "iphone"), workspace(id: "kypu", icon: "figure.run")]
    static let serverId = "sha256:router-modal-sites"

    static func makeCoordinator(playing: Bool, threads: Bool = false) -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        guard let server = PairedServer(from: ServerCredentials(
            host: "router-modal-sites.invalid",
            port: 7749,
            token: "sk_preview",
            name: "modal-sites",
            scheme: .https,
            serverFingerprint: serverId,
            tlsCertFingerprint: "sha256:router-modal-sites-leaf"
        )) else { return coordinator }
        coordinator.serverStore.replaceServersForPreview([server])
        guard coordinator.switchToServer(server),
              let connection = coordinator.connection(for: server.id) else { return coordinator }
        connection.setAPIClientForTesting(api)
        for workspace in workspaces {
            connection.workspaceStore.upsert(workspace, serverId: server.id)
        }
        connection.sessionStore.switchServer(to: server.id)
        if threads { connection.sessionStore.sessions = threadSessions }
        if playing {
            connection.audioPlayer._setPlaybackStateForTesting(playing: "router-modal-sites-audio", loading: nil)
            connection.audioPlayer._setNowPlayingItemTitleForTesting("Fixture narration")
        }
        return coordinator
    }

    /// One launch tree across two workspaces: an idle root with a working child, a finished
    /// child with its own child, and a child that runs in kypu, plus a plain session.
    /// `SCREENSHOT_THREAD_STOPPED_COUNT` adds that many day-old stopped workers to the tree, the
    /// shape of a big thread whose live members sit among stopped ones. `SCREENSHOT_LIST_FILLER`
    /// adds that many plain idle sessions, which list above the thread.
    /// `SCREENSHOT_THREAD_WORKING_COUNT` and `SCREENSHOT_THREAD_BLOCKED_COUNT` add that many more working
    /// children and children waiting on a question, so the strip's status dots have a crowd to draw.
    /// `SCREENSHOT_THREAD_AGENT_GROUPS` (up to 3) launches those added children from that many saved Agents in turn.
    /// `SCREENSHOT_THREAD_FOCUS=<root id>` (the inbox site) opens that thread as a thread link does.
    private static var threadSessions: [Session] {
        let now = Date()
        func session(
            _ id: String, _ name: String, workspace: String = "oppi", parent: String? = nil,
            status: SessionStatus, minutesAgo: Double, cost: Double
        ) -> Session {
            Session(
                id: id,
                workspaceId: workspace,
                workspaceName: workspace,
                name: name,
                status: status,
                createdAt: now.addingTimeInterval(-minutesAgo * 60),
                lastActivity: now.addingTimeInterval(-minutesAgo * 30),
                currentTurnStartedAt: status == .busy ? now.addingTimeInterval(-90) : nil,
                model: "anthropic/claude-opus-5-5",
                messageCount: 6,
                tokens: TokenUsage(input: 12_000, output: 2_400),
                cost: cost,
                parentSessionId: parent
            )
        }
        let extraStopped = (Int(ProcessInfo.processInfo.environment["SCREENSHOT_THREAD_STOPPED_COUNT"] ?? "") ?? 0)
        let oldWorkers = (0..<extraStopped).map { index in
            session(
                "old-worker-\(index)", "Stopped worker \(index + 1)", parent: "thread-root",
                status: .stopped, minutesAgo: 1_600 + Double(index), cost: 0.05
            )
        }
        let extraWorking = (0..<(Int(ProcessInfo.processInfo.environment["SCREENSHOT_THREAD_WORKING_COUNT"] ?? "") ?? 0)).map { index in
            session(
                "extra-working-\(index)", "Working agent \(index + 1)", parent: "thread-root",
                status: .busy, minutesAgo: 20 + Double(index), cost: 0.1
            )
        }
        let extraBlocked = (0..<(Int(ProcessInfo.processInfo.environment["SCREENSHOT_THREAD_BLOCKED_COUNT"] ?? "") ?? 0)).map { index -> Session in
            var blocked = session(
                "extra-blocked-\(index)", "Waiting agent \(index + 1)", parent: "thread-root",
                status: .ready, minutesAgo: 22 + Double(index), cost: 0.1
            )
            blocked.programStatus = ProgramStatus(state: .blocked, kind: .question, since: Date().addingTimeInterval(-120))
            return blocked
        }
        let fillerCount = Int(ProcessInfo.processInfo.environment["SCREENSHOT_LIST_FILLER"] ?? "") ?? 0
        let filler = (0..<fillerCount).map { index in
            session("filler-\(index)", "Filler session \(index + 1)", status: .ready, minutesAgo: 5 + Double(index), cost: 0.01)
        }
        let agents = [("worker", "\u{1F6E0}\u{FE0F}"), ("reviewer", "\u{1F52C}"), ("scout", "\u{1F9ED}")]
            .prefix(Int(ProcessInfo.processInfo.environment["SCREENSHOT_THREAD_AGENT_GROUPS"] ?? "") ?? 0)
        let added = (oldWorkers + extraWorking + extraBlocked).enumerated().map { index, child -> Session in
            guard !agents.isEmpty else { return child }
            var launched = child
            let agent = agents[agents.startIndex + index % agents.count]
            launched.launch = SessionLaunchMetadata(agentId: agent.0, agentIcon: .emoji(agent.1))
            return launched
        }
        return filler + added + [
            session("thread-root", "Plan the router migration", status: .ready, minutesAgo: 60, cost: 1.42),
            session("child-working", "Migrate the chat routes", parent: "thread-root", status: .busy, minutesAgo: 40, cost: 0.61),
            session("child-done", "Audit the old routes", parent: "thread-root", status: .stopped, minutesAgo: 35, cost: 0.33),
            session("grandchild", "Write the route table", parent: "child-done", status: .stopped, minutesAgo: 30, cost: 0.12),
            session("child-kypu", "Check the kypu client", workspace: "kypu", parent: "thread-root", status: .ready, minutesAgo: 25, cost: 0.2),
            session("plain", "Fix the flaky upload test", status: .ready, minutesAgo: 10, cost: 0.18),
        ]
    }

    private static let api: APIClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterModalSitesURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://router-modal-sites.oppi") ?? URL(fileURLWithPath: "/"),
            token: "preview-token",
            configuration: config
        )
    }()

    private static func workspace(id: String, icon: String) -> Workspace {
        Workspace(
            id: id,
            name: id,
            description: nil,
            icon: .symbol(icon),
            systemPrompt: nil,
            hostMount: "~/workspace/\(id)",
            gitStatusEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

/// Answers models, worktrees, and Agents; everything else is a 404.
private final class RouterModalSitesURLProtocol: URLProtocol {
    private struct Models: Encodable { let models: [ModelInfo] }
    private struct Worktrees: Encodable { let worktrees: [WorkspaceWorktree] }
    private struct Agents: Encodable { let agents: [AgentDefinitionSummary] }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "router-modal-sites.oppi"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let encoder = JSONEncoder()
        let response: Data? = switch (request.httpMethod, request.url?.path ?? "") {
        case ("GET", "/models"):
            try? encoder.encode(Models(models: [
                ModelInfo(id: "fixture-swift", name: "Fixture Swift", provider: "fixture", contextWindow: 200_000),
                ModelInfo(id: "fixture-steady", name: "Fixture Steady", provider: "fixture", contextWindow: 200_000),
            ]))
        case ("GET", "/workspaces/oppi/worktrees"):
            try? encoder.encode(Worktrees(worktrees: [
                WorkspaceWorktree(id: WorkspaceWorktree.mainId, name: "oppi", path: "~/workspace/oppi", branch: "main", headSha: nil, isMain: true, isGitRepo: true, sessionCount: nil),
                WorkspaceWorktree(id: "router-fix", name: "router-fix", path: "~/workspace/oppi-router-fix", branch: "router-fix", headSha: nil, isMain: false, isGitRepo: true, sessionCount: nil),
            ]))
        case ("GET", "/workspaces/oppi/git/status"):
            try? encoder.encode(GitStatus(
                isGitRepo: true, branch: "main", headSha: "7b42c0d", ahead: 3, behind: 0,
                dirtyCount: 3, untrackedCount: 0, stagedCount: 0,
                files: [
                    GitFileStatus(status: " M", path: "clients/apple/Oppi/App/Router.swift", addedLines: 96, removedLines: 4),
                    GitFileStatus(status: " M", path: "server/src/routes/workspaces.ts", addedLines: 12, removedLines: 3),
                    GitFileStatus(status: " M", path: "docs/usage.md", addedLines: 5, removedLines: 1),
                ],
                totalFiles: 3, addedLines: 113, removedLines: 8, stashCount: 0,
                lastCommitMessage: "Route fixture", lastCommitDate: nil, recentCommits: []
            ))
        case ("GET", "/agents"):
            try? encoder.encode(Agents(agents: [
                AgentDefinitionSummary(
                    id: "reviewer", name: "Reviewer", icon: .defaultValue, description: nil,
                    status: .active, version: 1,
                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), archivedAt: nil
                ),
            ]))
        default:
            nil
        }
        guard let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response == nil ? 404 : 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response ?? Data(#"{"error":"Not found"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
