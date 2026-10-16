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

// MARK: - Root Preview View

/// Launches a standalone screen with mock data for screenshot capture in UI tests.
struct ScreenshotPreviewView: View {
    var body: some View {
        switch ScreenshotPreviewConfig.screen {
        case "workspace-settings":
            WorkspaceSettingsScreenshotPreview()
        case "onboarding":
            OnboardingScreenshotPreview()
        case "tailscale-connection":
            TailscaleConnectionScreenshotPreview()
        case "ssh-terminal-settings", "settings":
            // Real Settings/setup surfaces, not a mocked SSH connection. This
            // makes enrollment/refusal QA reachable without pairing a server.
            SettingsScreenshotPreview()
        case "settings-appearance", "settings-chat-conversation":
            SettingsScreenshotPreview()
        case "chat-speaker-contrast-dark":
            ChatSpeakerContrastPreview(themeID: .dark)
        case "chat-speaker-contrast-oled":
            ChatSpeakerContrastPreview(themeID: .oled)
        case "chat-speaker-contrast-night":
            ChatSpeakerContrastPreview(themeID: .night)
        case "chat-speaker-contrast-light":
            ChatSpeakerContrastPreview(themeID: .light)
        case "chat-speaker-contrast-dark-increase-contrast":
            ChatSpeakerContrastPreview(themeID: .dark, increasedContrast: true)
        case "chat-speaker-contrast-light-increase-contrast":
            ChatSpeakerContrastPreview(themeID: .light, increasedContrast: true)
        case "chat-speaker-contrast-dark-differentiate-without-color":
            ChatSpeakerContrastPreview(themeID: .dark, differentiateWithoutColor: true)
        case "settings-sweep":
            SettingsSweepScreenshotPreview()
        case "ssh-terminal":
            SSHTerminalScreenshotPreview()
        case "ssh-terminal-status-working":
            SSHTerminalScreenshotPreview(status: .working)
        case "ssh-terminal-status-blocked":
            SSHTerminalScreenshotPreview(status: .blocked)
        case "ssh-terminal-status-done":
            SSHTerminalScreenshotPreview(status: .done)
        case "ssh-terminal-status-tree":
            SSHTerminalScreenshotPreview(status: .tree)
        case "ssh-terminal-status-sequence":
            SSHTerminalScreenshotPreview(status: .sequence)
        case "ssh-terminal-status-detail":
            SSHTerminalScreenshotPreview(status: .detail)
        case "ssh-terminal-notification":
            SSHTerminalScreenshotPreview(status: .notification)
        case "durable-sessions-settings":
            DurableSessionsScreenshotPreview(surface: .settings)
        case "durable-sessions-sidebar":
            DurableSessionsScreenshotPreview(surface: .sidebar)
        case "durable-sessions-sidebar-off":
            DurableSessionsScreenshotPreview(surface: .sidebar, experimentEnabled: false)
        case "durable-sessions-list":
            DurableSessionsScreenshotPreview(surface: .list)
        case "quick-session-overlay-durable-off":
            DurableSessionsScreenshotPreview(surface: .quickSession, experimentEnabled: false)
        case "durable-conversation":
            DurableConversationScreenshotPreview(themeID: .dark)
        case "durable-conversation-light":
            DurableConversationScreenshotPreview(themeID: .light)
        case "durable-conversation-running":
            DurableConversationScreenshotPreview(themeID: .dark, scenario: .running)
        case "durable-conversation-expanded":
            DurableConversationScreenshotPreview(themeID: .dark, scenario: .expanded)
        case "durable-conversation-pills":
            DurableConversationPillStatesPreview(themeID: .dark)
        case "durable-conversation-pills-light":
            DurableConversationPillStatesPreview(themeID: .light)
        case "scoped-locks":
            ScopedLocksScreenshotPreview()
        case "quick-session-overlay":
            DurableSessionsScreenshotPreview(surface: .quickSession)
        case "session-timeline-wide":
            SessionTimelineWideContentPreview()
        case "review-comment-inline-draft":
            ReviewCommentInlineDraftScreenshotPreview()
                .ignoresSafeArea()
        case "whats-new-build55-light", "whats-new-build54-light", "whats-new-build53-light", "whats-new-build52-light", "whats-new-build51-light", "whats-new-build50-light", "whats-new-build49-light":
            WhatsNewScreenshotPreview(themeID: .light)
        case "whats-new-build55-dark", "whats-new-build54-dark", "whats-new-build53-dark", "whats-new-build52-dark", "whats-new-build51-dark", "whats-new-build50-dark", "whats-new-build49-dark":
            WhatsNewScreenshotPreview(themeID: .dark)
        case "server-resources-skills":
            ServerResourcesScreenshotPreview(screen: .skills)
        case "server-resources-extensions":
            ServerResourcesScreenshotPreview(screen: .extensions)
        case "server-resources-cached-offline":
            ServerResourcesScreenshotPreview(screen: .cachedOffline)
        case "server-provider-navigation-regression":
            ServerProviderNavigationRegressionPreview()
        case "router-routes":
            RouterRoutesPreview()
        case "router-modal-sites":
            RouterModalSitesPreview()
        case "chat-routes":
            ChatRoutesHarnessView()
        case "model-providers-quota-inline":
            ModelProvidersQuotaPreview()
        case "inbox-provider-setup-empty":
            InboxProviderSetupPreview(showsSessions: false)
        case "inbox-provider-setup-with-sessions":
            InboxProviderSetupPreview(showsSessions: true)
        case "agent-icons":
            AgentIconProofPreview()
        case "agents-pi-row":
            AgentManagementPiProofPreview()
        case "agent-icon-title-bar-stress":
            AgentIconTitleBarStressPreview()
        case "agent-icons-save-failure":
            AgentIconProofPreview(failsFirstSave: true)
        case "workspace-sidebar-git-status":
            WorkspaceSidebarGitStatusPreview()
        case "tool-call-document":
            ToolCallDocumentPreview(direct: false)
        case "tool-call-document-mcp":
            ToolCallDocumentPreview(direct: true)
        case "session-timeline":
            SessionTimelinePreview()
        case "quiet-work-strip":
            QuietWorkStripPreview()
        case "input-card-disclosure":
            InputCardDisclosurePreview()
        case "old-server-bash":
            BuiltInToolFactsPreview(isEdit: false)
        case "old-server-edit":
            BuiltInToolFactsPreview(isEdit: true)
        case "chat-file-panel":
            ChatFileBrowserPanelPreview()
        case "side-panel-files":
            SidePanelScreenshotPreview(surface: .files)
        case "side-panel-commit":
            SidePanelScreenshotPreview(surface: .commit)
        case "side-panel-review":
            SidePanelScreenshotPreview(surface: .review)
        case "file-browser-motion":
            FileBrowserMotionPreview()
        case "file-editor-save-status":
            FileEditorSaveStatusScreenshotPreview()
        case "review-file-motion":
            ReviewFileMotionPreview()
        case "extension-widget":
            ExtensionSurfacePreview()
        case "chat-input-attachment-containment":
            ChatInputAttachmentContainmentPreview()
        case "extension-notify-chip-info":
            ExtensionNotifyChipScreenshotPreview(mode: .collapsedInfo)
        case "extension-notify-chip-error":
            ExtensionNotifyChipScreenshotPreview(mode: .collapsedError)
        case "extension-notify-chip-expanded":
            ExtensionNotifyChipScreenshotPreview(mode: .expandedMultiple)
        case "review-comment-strip-collapsed":
            ReviewCommentStripScreenshotPreview(isExpanded: false)
        case "review-comment-strip-expanded":
            ReviewCommentStripScreenshotPreview(isExpanded: true)
        case "review-comment-strip-expanded-one":
            ReviewCommentStripScreenshotPreview(
                isExpanded: true,
                comments: Array(ReviewCommentStripScreenshotPreview.fixtureComments.prefix(1))
            )
        case "quick-session-dictation-composer":
            QuickSessionDictationComposerPreview()
        case "dictation-non-wipe-composer":
            QuickSessionDictationComposerPreview(
                title: "Non-wipe dictation composer",
                subtitle: "Earlier utterances stay when a later short phrase arrives.",
                transcriptSteps: [
                    ("hello world this is a test", 0),
                    ("hello world this is a test testing now", 11),
                ],
                initialDelay: .milliseconds(400),
                stepDelay: .milliseconds(900)
            )
        case "ask-card-long-composer":
            AskCardLongComposerPreview()
        case "extension-dock-stress":
            ExtensionDockStressPreview()
        case "extension-dock-review-combined":
            ExtensionDockReviewCombinedPreview()
        case "extension-dock-scoped-agents":
            ExtensionDockScopedAgentsPreview()
        case "extension-dock-goal-detail":
            ExtensionDockGoalDetailStandalonePreview()
        case "streaming-flicker":
            StreamingFlickerPreviewView()
        case "latex-rendering":
            LatexRenderingPreview()
        case "syntax-languages-a":
            SyntaxLanguagesPreview(page: .webAndDynamic, engine: .treeSitter)
        case "syntax-languages-b":
            SyntaxLanguagesPreview(page: .systemsAndMarkup, engine: .treeSitter)
        case "syntax-languages-a-scanner":
            SyntaxLanguagesPreview(page: .webAndDynamic, engine: .scanner)
        case "syntax-languages-b-scanner":
            SyntaxLanguagesPreview(page: .systemsAndMarkup, engine: .scanner)
        case "mermaid-rendering":
            MermaidRenderingPreview()
        case "geojson-mount-rainier":
            GeoJSONMountRainierPreview()
        case "usdz-rendering":
            USDZRenderingPreview()
        case "mermaid-consistency-inline":
            MermaidConsistencyPreview(expanded: false)
        case "mermaid-consistency-expanded":
            MermaidConsistencyPreview(expanded: true)
        case "mermaid-fullscreen":
            MermaidFullscreenPreview()
        case "mermaid-responsive-routing":
            MermaidResponsiveRoutingPreview()
        case "fullscreen-mermaid":
            FullscreenMermaidChromePreview()
        case "fullscreen-image":
            FullscreenImageChromePreview()
        case "fullscreen-html":
            FullscreenHTMLChromePreview()
        case "fullscreen-svg":
            FullscreenSVGChromePreview()
        case "ask-card":
            AskCardPreview()
        case "ask-card-multiselect-long":
            AskCardMultiSelectLongOptionsPreview()
        case "ask-card-long-unfocused":
            AskCardLongUnfocusedComposerPreview()
        case "ask-card-expanded-sheet":
            AskCardExpandedSheetPreview()
        case "ask-card-expanded-custom":
            AskCardExpandedCustomPreview()
        case "ask-card-intent-regression":
            AskCardIntentRegressionPreview()
        case "oppi-command-approval-inline":
            OppiCommandApprovalInlinePreview()
        case "context-bar-overlap":
            ContextBarOverlapPreview()
        case "feature-tips":
            FeatureEducationTipsPreview()
        case "feature-tip-p0":
            FeatureEducationP0TipPreview()
        case "voice-message-expanded":
            VoiceMessageExpandedPreview()
        case "global-audio-banner":
            GlobalAudioBannerPreview()
        case "audio-file-player":
            AudioFilePlayerScreenshotPreview()
        case "audio-script-reader":
            AudioScriptReaderPreview()
        case "share-redaction-report":
            ShareRedactionReportPreview()
        case "share-redaction-settings":
            ShareRedactionSettingsPreview()
        case "split-file-navigation-regression":
            SplitFileNavigationRegressionPreview()
        case "live-activity-working":
            LiveActivityPreviewScreen(
                title: "Live Activity — Working",
                state: .workingPreview,
                isStale: false
            )
        case "session-status-inbox":
            SessionStatusScreenshotPreview(screen: .inbox)
        case "session-status-thread":
            SessionStatusScreenshotPreview(screen: .thread)
        case "live-activity-blocked":
            LiveActivityPreviewScreen(
                title: "Live Activity — Needs Approval",
                state: .blockedPreview,
                isStale: false
            )
        case "live-activity-awaiting":
            LiveActivityPreviewScreen(
                title: "Live Activity — Awaiting Reply",
                state: .awaitingReplyPreview,
                isStale: false
            )
        case "live-activity-stale-awaiting":
            LiveActivityPreviewScreen(
                title: "Live Activity — Stale Awaiting Reply",
                state: .awaitingReplyPreview,
                isStale: true
            )
        case "live-activity-done":
            LiveActivityPreviewScreen(
                title: "Live Activity — Done",
                state: .donePreview,
                isStale: false
            )
        case "metal-orbs":
            MetalOrbScreenshotPreview()
        case let screen where RailToolbarScreenshotPreview.screens.contains(screen):
            RailToolbarScreenshotPreviewView(screen: screen)
        default:
            Text("Unknown screen: \(ScreenshotPreviewConfig.screen)")
        }
    }
}

/// The production inline review-comment composer opened over text near the
/// bottom of the screen, so the software keyboard has to push it up. Set
/// `SCREENSHOT_ORIENTATION=landscape` for the Duo vertical-rail pose.
private struct ReviewCommentInlineDraftScreenshotPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InlineDraftPreviewController {
        InlineDraftPreviewController()
    }

    func updateUIViewController(_ uiViewController: InlineDraftPreviewController, context: Context) {}

    final class InlineDraftPreviewController: UIViewController {
        private let textView = UITextView()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = UIColor(ThemeID.dark.palette.bgDark)
            view.accessibilityIdentifier = "screenshot.ready"
            textView.isEditable = false
            textView.backgroundColor = .clear
            textView.textColor = UIColor(ThemeID.dark.palette.fg)
            textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            textView.text = (1...40).map { "line \($0): let value = compute(\($0)) // review target" }
                .joined(separator: "\n")
            textView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
                textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            ScreenshotPreviewOrientation.applyRequested()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.presentDraft()
            }
        }

        private func presentDraft() {
            view.layoutIfNeeded()
            let anchor = CGRect(x: 40, y: textView.bounds.height - 90, width: 120, height: 22)
            ReviewCommentInlineDraftPresenter.present(
                sourceView: textView,
                anchorRect: anchor,
                request: ReviewCommentSelectionRequest(
                    selectedText: "let value = compute(40)",
                    source: ReviewCommentSourceContext(sessionId: "preview", surface: .fullScreenCode)
                ),
                router: ReviewCommentSelectionRouter(
                    dispatch: { _ in },
                    inlineSave: { _, _ in true },
                    inlineQuickComments: [.fix]
                )
            )
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
            sessionRowDisplay: SessionRowDisplay()
        )
    }

    var body: some View {
        RouterRoutesStack(root: root)
            .ignoresSafeArea()
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
    @State private var dismissedModals = 0
    @State private var saves = RouterRoutesSaves.shared

    var body: some View {
        List {
            Button("Quick Comments") {
                navigator.push { QuickCommentsSettingsView() }
            }
            .accessibilityIdentifier("routerRoutes.quickComments")

            Button("Edit Agent") {
                navigator.present(
                    .fullScreen.inNavigation(),
                    onDismiss: { dismissedModals += 1 },
                    content: {
                        AgentNativeEditView(agent: RouterRoutesFixtures.agent) { _ in }
                            .environment(\.apiClient, RouterRoutesFixtures.api)
                    }
                )
            }
            .accessibilityIdentifier("routerRoutes.editAgent")

            Button("Edit Schedule") {
                navigator.present(
                    .fullScreen.inNavigation(),
                    onDismiss: { dismissedModals += 1 },
                    content: {
                        ScheduleNativeEditView(schedule: RouterRoutesFixtures.schedule) { _, _ in }
                            .environment(\.apiClient, RouterRoutesFixtures.api)
                    }
                )
            }
            .accessibilityIdentifier("routerRoutes.editSchedule")

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

/// First-run pairing choices, including Connect through Tailscale.
private struct OnboardingScreenshotPreview: View {
    private let coordinator = ConnectionCoordinator(serverStore: ServerStore())

    var body: some View {
        OnboardingView(previewCanScan: true)
            .environment(coordinator)
            .environment(coordinator.serverStore)
            .environment(coordinator.activeConnection)
            .environment(AppNavigation())
            .environment(ThemeStore())
            .accessibilityIdentifier("screenshot.ready")
    }
}

/// Connected in-app Tailscale screen: one Mac ready to pair. The node snapshot
/// is a preview fixture; it does not start TailscaleKit or dial the tailnet.
private struct TailscaleConnectionScreenshotPreview: View {
    private let coordinator = ConnectionCoordinator(serverStore: ServerStore())
    private let studioID = "n-mac-studio"

    init() {
        TailnetNodeController.shared.applyPreviewSnapshot(
            TailnetStatusSnapshot(
                backendState: .running,
                authURL: nil,
                selfDNSName: "oppi-ios.tail1234.ts.net",
                tailnetName: "chen@example.com",
                peers: [
                    TailnetPeer(
                        id: studioID,
                        hostName: "mac-studio",
                        dnsName: "mac-studio.tail1234.ts.net",
                        os: "macOS",
                        tailscaleIPs: ["100.64.1.2"],
                        isOnline: true
                    ),
                    TailnetPeer(
                        id: "n-iphone",
                        hostName: "iphone",
                        dnsName: "iphone.tail1234.ts.net",
                        os: "iOS",
                        tailscaleIPs: ["100.64.1.3"],
                        isOnline: true
                    ),
                ]
            )
        )
    }

    var body: some View {
        NavigationStack {
            TailnetSettingsView(previewProbes: [studioID: .ready])
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {}
                    }
                }
        }
        .environment(coordinator)
        .environment(coordinator.serverStore)
        .environment(coordinator.activeConnection)
        .environment(AppNavigation())
        .environment(ThemeStore())
        .accessibilityIdentifier("screenshot.ready")
    }
}

/// Isolated editor chrome: production save-state glyph, fixed spacer, Preview, Done.
private struct FileEditorSaveStatusScreenshotPreview: View {
    var body: some View {
        NavigationStack {
            Color.themeBg
                .ignoresSafeArea()
                .navigationTitle("AGENTS.md — workspace deltas and a long filename")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        WorkspaceFileEditStatusIndicator(status: .saved)
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "Preview")) {}
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "Done")) {}
                            .fontWeight(.semibold)
                    }
                }
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct AudioFilePlayerScreenshotPreview: View {
    @State private var audioPlayer = AudioPlayerService()

    var body: some View {
        AudioLyricsPlayerView(
            title: "xiaoge-story.wav",
            lyrics: nil,
            itemID: "audio-file-preview",
            audioPlayer: audioPlayer,
            play: { _ in },
            openFile: {},
            shareFileData: { Data("preview audio".utf8) },
            autoplayOnAppear: false,
            showsCloseButton: false,
            usesNavigationBackButton: true
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screenshot.ready")
    }
}

private extension PiSessionAttributes.ContentState {
    static let workingPreview = Self(
        primaryPhase: .working,
        primarySessionId: "session-working",
        primarySessionName: "Refactor Timeline",
        primaryTool: "Edit",
        primaryLastActivity: "Running Edit",
        totalActiveSessions: 2,
        sessionsAwaitingReply: 0,
        sessionsWorking: 2,
        primaryMutatingToolCalls: 3,
        primaryFilesChanged: 2,
        primaryAddedLines: 48,
        primaryRemovedLines: 12,
        sessionStartDate: Date().addingTimeInterval(-97)
    )

    static let blockedPreview = Self(
        primaryPhase: .blocked,
        primarySessionId: "session-blocked",
        primarySessionName: "Migrate Database",
        primaryTool: nil,
        primaryLastActivity: "Needs approval",
        totalActiveSessions: 3,
        sessionsAwaitingReply: 0,
        sessionsWorking: 2,
        sessionsBlocked: 1,
        primaryBlockedKind: "permission",
        sessionStartDate: nil
    )

    static let awaitingReplyPreview = Self(
        primaryPhase: .awaitingReply,
        primarySessionId: "session-awaiting",
        primarySessionName: "Deploy Server",
        primaryTool: nil,
        primaryLastActivity: "Waiting for your next instruction",
        totalActiveSessions: 1,
        sessionsAwaitingReply: 1,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        sessionStartDate: nil
    )

    static let donePreview = Self(
        primaryPhase: .ended,
        primarySessionId: "session-done",
        primarySessionName: "Review Release Notes",
        primaryTool: nil,
        primaryLastActivity: "Session ended",
        totalActiveSessions: 0,
        sessionsAwaitingReply: 0,
        sessionsWorking: 0,
        primaryMutatingToolCalls: nil,
        primaryFilesChanged: nil,
        primaryAddedLines: nil,
        primaryRemovedLines: nil,
        sessionStartDate: nil
    )
}

// MARK: - Router modal sites

/// Real presenters whose modals the router owns, over fixture services and an
/// in-process stub server. `SCREENSHOT_MODAL_SITE` picks the presenter:
/// `root` (the app root's extension dialog, notice, and What's New, with
/// trigger buttons and what the dialog sent), `document` (the document viewer
/// modifier), `stash` (the staged-comment sheet), `inbox-now-playing` and
/// `workspace-now-playing` (the full-screen player over active playback), and
/// `quick-session` (its pickers, model sheet, and expanded composer). The
/// presenters and their modals share one app root over the fixture server, in
/// the dark theme.
private struct RouterModalSitesPreview: View {
    private let site: String
    @State private var root: AppRootEnvironment

    init() {
        ScreenshotVolatileDefaults.applyDarkTheme(true)
        let site = ProcessInfo.processInfo.environment["SCREENSHOT_MODAL_SITE"] ?? "quick-session"
        self.site = site
        _root = State(initialValue: AppRootEnvironment(
            coordinator: RouterModalSitesFixtures.makeCoordinator(playing: site.hasSuffix("now-playing")),
            navigation: AppNavigation(),
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRowDisplay: SessionRowDisplay()
        ))
    }

    var body: some View {
        page.appRootEnvironment(root)
    }

    @ViewBuilder
    private var page: some View {
        switch site {
        case "root":
            RouterModalSitesRootPage()
        case "document":
            RouterModalSitesDocumentPage()
        case "stash":
            RouterModalSitesStashPage()
        case "inbox-now-playing":
            RouterModalSitesStack(root: root) { SessionInboxView() }
                .ignoresSafeArea()
        case "workspace-now-playing":
            RouterModalSitesStack(root: root) { WorkspaceDetailView(workspace: RouterModalSitesFixtures.workspaces[0]) }
                .ignoresSafeArea()
        default:
            QuickSessionOverlay {}
        }
    }
}

/// A session list as the root of a router navigation controller, with its
/// toolbar shown so the Now Playing pill appears.
private struct RouterModalSitesStack<Content: View>: UIViewControllerRepresentable {
    let root: AppRootEnvironment
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> RouterNavigationController {
        let screen = HostFactory.screen(root: root, bars: ScreenBars(showsToolbar: true), content: content)
        let navigation = RouterNavigationController(rootViewController: screen)
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {}
}

/// `ContentView` over a fixture connection. The dialog's responses go to the
/// connection's send hook, and the page shows the last one.
private struct RouterModalSitesRootPage: View {
    @State private var connection: ServerConnection
    @State private var navigation = AppNavigation()
    @State private var lastResponse = RouterModalSitesResponse()

    init() {
        let connection = ServerConnection()
        connection.setPreviewServerId("router-modal-sites")
        _ = connection.focusedSessionStore.focus(sessionId: "router-modal-sites-session")
        _connection = State(initialValue: connection)
    }

    var body: some View {
        ContentView()
            .overlay(alignment: .top) {
                VStack(spacing: 12) {
                    Button("Extension Dialog") { showDialog(method: "custom", title: "Pick a Plan") }
                        .accessibilityIdentifier("routerModalSites.dialog")
                    Button("Extension Editor") { showDialog(method: "editor", title: "Commit Message") }
                        .accessibilityIdentifier("routerModalSites.editor")
                    Button("Notice") { connection.extensionToast = "Extension finished.\nDocs https://example.com/docs" }
                        .accessibilityIdentifier("routerModalSites.notice")
                    Button("What's New") { navigation.showWhatsNew = true }
                        .accessibilityIdentifier("routerModalSites.whatsNew")
                    Text(lastResponse.summary)
                        .accessibilityIdentifier("routerModalSites.lastResponse")
                    Text(connection.extensionToast == nil ? "Notice cleared" : "Notice shown")
                        .accessibilityIdentifier("routerModalSites.noticeState")
                    Text(navigation.showWhatsNew ? "What's New shown" : "What's New cleared")
                        .accessibilityIdentifier("routerModalSites.whatsNewState")
                }
                .padding(.top, 80)
            }
            .withServerScopedEnvironment(connection)
            .environment(navigation)
            .task {
                let response = lastResponse
                connection._sendMessageForTesting = { @MainActor message in
                    guard case .extensionUIResponse(_, let value, _, let cancelled, _) = message else { return }
                    response.summary = cancelled == true ? "cancelled" : "value=\(value ?? "")"
                }
            }
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

@MainActor @Observable
private final class RouterModalSitesResponse {
    var summary = "none"
}

/// The document viewer modifier on a plain button; the page counts closes, so
/// a dismissal that left the binding set shows.
private struct RouterModalSitesDocumentPage: View {
    @State private var isPresented = false
    @State private var closes = 0

    var body: some View {
        VStack(spacing: 16) {
            Button("Open Document") { isPresented = true }
                .accessibilityIdentifier("routerModalSites.openDocument")
            Text("Viewer closed \(closes)")
                .accessibilityIdentifier("routerModalSites.documentCloses")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.themeBg)
        .fullScreenViewer(
            isPresented: $isPresented,
            content: .code(content: "let answer = 42\nprint(answer)\n", language: "swift", filePath: "Fixture.swift", startLine: 1)
        )
        .onChange(of: isPresented) { wasPresented, presented in
            if wasPresented, !presented { closes += 1 }
        }
    }
}

/// The staged-comment control and sheet over two staged comments.
private struct RouterModalSitesStashPage: View {
    @State private var comments: ChatReviewCommentsController
    @State private var router: ReviewCommentSelectionRouter

    init() {
        let suite = "router-modal-sites-stash"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let comments = ChatReviewCommentsController(store: ReviewCommentStore(defaults: defaults, keyPrefix: suite))
        comments.load(localScopeId: "workspace", sessionId: "session")
        let source = ReviewCommentSourceContext(sessionId: "session", surface: .fullScreenSource, filePath: "Fixture.swift")
        for body in ["Rename this.", "Explain this."] {
            _ = comments.save(
                body: body,
                request: ReviewCommentSelectionRequest(selectedText: "let answer = 42", source: source),
                localScopeId: "workspace",
                sessionId: "session"
            )
        }
        _comments = State(initialValue: comments)
        _router = State(initialValue: ReviewCommentSelectionRouter(dispatch: { _ in }, stash: comments))
    }

    var body: some View {
        Text("Staged \(comments.stagedCount)")
            .accessibilityIdentifier("routerModalSites.staged")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.themeBg)
            .fullScreenReviewCommentStashOverlay(scope: .activeSession(router))
    }
}

/// A fixture server whose stub answers models, worktrees, and Agents.
/// `playing` starts fixture playback, so the Now Playing pill shows.
@MainActor
private enum RouterModalSitesFixtures {
    static let workspaces = [workspace(id: "oppi", icon: "iphone"), workspace(id: "kypu", icon: "figure.run")]

    static func makeCoordinator(playing: Bool) -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        guard let server = PairedServer(from: ServerCredentials(
            host: "router-modal-sites.invalid",
            port: 7749,
            token: "sk_preview",
            name: "modal-sites",
            scheme: .https,
            serverFingerprint: "sha256:router-modal-sites",
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
        if playing {
            connection.audioPlayer._setPlaybackStateForTesting(playing: "router-modal-sites-audio", loading: nil)
            connection.audioPlayer._setNowPlayingItemTitleForTesting("Fixture narration")
        }
        return coordinator
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
