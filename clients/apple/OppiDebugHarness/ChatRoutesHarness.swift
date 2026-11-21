#if DEBUG
import Observation
import UIKit

// MARK: - Chat routes harness

/// Every router modal and side panel chat owns, on the production `ChatViewController`
/// with fixture services and an in-process stub server
/// (`SCREENSHOT_SCREEN=chat-routes`). The chat is a router screen at the root
/// of a `RouterNavigationController`. The timeline carries a user message with
/// a commit pill and a file pill; the context bar has a changed file and a
/// commit; one review comment is staged; Share is enabled.
/// `CHAT_ROUTES_STATUS=busy` makes the session busy (busy send mode picker);
/// `CHAT_ROUTES_ASK=1` puts a two-question ask in the composer (`single`: one question).
/// The `chatRoutes.raiseAsk` control raises the one-question ask later, over what is already open.
/// `CHAT_ROUTES_QUEUE=long` queues a report taller than the screen.
/// `CHAT_ROUTES_SURFACE=tall` publishes a composable surface (a long table
/// card, then an Actions card with Run again) whose drawer is taller than the
/// space above the composer. `chatRoutes.surfaceActions` lists the surface
/// actions the chat sent over its socket. `CHAT_ROUTES_SURFACE=jobs` publishes the Background jobs
/// surface with one running job and a long output block (`ChatRoutesJobsSurface`).
/// `CHAT_ROUTES_SURFACE=panel` publishes a surface placed as a panel, with pane hints (the shape
/// of `protocol/surfaces/panel-hints.json`), whose pill opens its pane with no drawer.
/// `CHAT_ROUTES_NATIVE_WIDGET_FILE=<path>` publishes a version 1 native widget read from that file
/// (`ChatRoutesNativeWidget`); `CHAT_ROUTES_SURFACE=subagents` publishes the Subagents widget.
/// `CHAT_ROUTES_INTERNAL_URL_FILE=<path>` serves `proc://` views from that file (`ChatRoutesInternalURL`).
/// `CHAT_ROUTES_SURFACE_FILE=<path>[,<path>...]` publishes the
/// surface JSON in those files instead (a server's rendered `ExtensionUISurface`, so a panel is shown
/// as the phone receives it). `CHAT_ROUTES_REVIEW_COMMENT=none` stages no review comment, leaving
/// the strip to the surfaces. `CHAT_ROUTES_WARNINGS=N` gives the session N launch warnings, and
/// `CHAT_ROUTES_WARNINGS=launch` one long MCP-drop warning as the server writes it; both show on
/// the notice chip above the composer, the text only in the drawer a tap opens.
/// `SCREENSHOT_COLOR_SCHEME=light` shows the chat in the light theme.
/// `CHAT_ROUTES_SESSION_TITLE=<title>` names the chat (a long-title check).
/// `CHAT_ROUTES_LONG_FILE=1` serves a long file with wide lines;
/// `CHAT_ROUTES_LONG_FILE=<n>` serves n lines of wrapping code.
/// `CHAT_ROUTES_PANE_RESIZE=1` adds the live divider resize readout
/// (`PaneResizeReadout`).
/// `CHAT_ROUTES_TRACE_FILE=<path>` appends the trace events in that file (a JSON array, the
/// `trace` of `oppi session trace --json`) after the fixture rows, so the chat shows a real session.
/// `CHAT_ROUTES_THEME_FILE=<path>` imports that theme JSON and shows the chat in it.
/// `CHAT_ROUTES_CHAT_STYLE=chat|full|compact` picks the Chat style.
/// `CHAT_ROUTES_QUEUE=followup` queues one follow-up; the `chatRoutes.queueFollowUp` control queues
/// one later, as a busy-time send does (the chat never connects, so the composer cannot send).
/// `CHAT_ROUTES_LIVE_WORK=1` ends the timeline on a running tool call (with `CHAT_ROUTES_STATUS=busy`,
/// a turn in progress); the `chatRoutes.endTurn` control ends the turn. The
/// `chatRoutes.narrowWindow` control makes the window compact, as Split View does.
/// `chatRoutes.createdSessions` counts the new sessions the stub received.
/// Leading controls open the timeline's commit and file viewers through the
/// production presenter (a test tap on a timeline pill did not reach the pill
/// control).
///
/// `topBar` goes in the argument domain before the chat is built, so the
/// simulator's saved layout is untouched and a test's bar does not depend on
/// what an earlier run left behind: `chat-routes` pins Files, Git, Outline, and
/// Context (its screens are about the panels the bar opens), and the
/// `chat-top-bar-*` screens pin the bar under test.
final class ChatRoutesPreviewController: PreviewRootController {
    private let root: AppRootEnvironment
    private let connection: ServerConnection
    private let navigation: SceneNavigation
    /// The chat's own timeline, which the harness keeps seeded (`keepTimelineSeeded`).
    private let reducer: TimelineReducer
    /// The chat's scroll owner, for `chatRoutes.queueFollowUp`.
    private let scrollController: ChatScrollController
    private let landingProbe = ChatRoutesPreviewController.probeLabel("chatRoutes.landing")
    private let createdSessionsProbe = ChatRoutesPreviewController.probeLabel("chatRoutes.createdSessions")
    private let surfaceActionsProbe = ChatRoutesPreviewController.probeLabel("chatRoutes.surfaceActions")
    private var loops: [Task<Void, Never>] = []
    /// The reader last pushed for app navigation, so each new one pushes once.
    private var pushedReader: ChatReaderNavTarget?
    private let paneResizeReadout = ProcessInfo.processInfo.environment["CHAT_ROUTES_PANE_RESIZE"] == "1"
        ? PaneResizeReadout() : nil

    init(root: AppRootEnvironment, topBar: ChatTopBarLayout) {
        let environment = ProcessInfo.processInfo.environment
        if environment["SCREENSHOT_COLOR_SCHEME"] == "light" {
            root.themeStore.mode = .manual
            root.themeStore.manualThemeID = .light
        }
        if let path = environment["CHAT_ROUTES_THEME_FILE"],
           let data = FileManager.default.contents(atPath: path),
           let theme = try? JSONDecoder().decode(RemoteTheme.self, from: data) {
            CustomThemeStore.save(theme)
            root.themeStore.mode = .manual
            root.themeStore.manualThemeID = .custom(theme.name)
        }
        var defaults: [String: Any] = [
            AppPreferences.ChatTopBar.orderKey: topBar.storedOrder,
            AppPreferences.ChatTopBar.shownKey: topBar.storedShown,
        ]
        if let style = environment["CHAT_ROUTES_CHAT_STYLE"] {
            defaults[AppPreferences.ChatDisplay.styleKey] = style
        }
        ScreenshotVolatileDefaults.apply(defaults)
        let connection = ChatRoutesFixture.connection
        let navigation = SceneNavigation()
        let chat = ChatViewController(
            sessionId: ChatRoutesFixture.sessionId,
            connection: connection,
            navigation: navigation,
            workspaceIdHint: ChatRoutesFixture.workspace.id
        )
        self.root = root
        self.connection = connection
        self.navigation = navigation
        reducer = chat.reducer
        scrollController = chat.scrollController
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) { chat }
        )
        keepTimelineSeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        for loop in loops { loop.cancel() }
    }

    /// The fixture rows, and again on the next turn after anything drops them:
    /// the chat's connect resets its reducer, and the connect never reaches a
    /// server to load the rows back. Outline is on the bar only while the
    /// timeline has rows, so a timeline that sat empty for a while (a 200 ms poll
    /// did this) inserts Outline before the ring and moves Files and Git one slot
    /// left under a test's tap: a Git tap opened the outline.
    private func keepTimelineSeeded() {
        ChatRoutesFixture.seedTimelineIfNeeded(into: reducer)
        withObservationTracking {
            _ = reducer.items
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.keepTimelineSeeded() }
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let controls = UIStackView(arrangedSubviews: [
            control("chatRoutes.openCommitViewer") {
                ChatRoutesFixture.openFromTimeline(.commitDetail(sha: ChatRoutesFixture.commitSha))
            },
            control("chatRoutes.narrowWindow") { [weak self] in
                self?.view.window?.traitOverrides.horizontalSizeClass = .compact
            },
            control("chatRoutes.raiseAsk") {
                let connection = ChatRoutesFixture.connection
                connection.askRequestStore.switchServer(to: ChatRoutesFixture.serverId)
                _ = connection.askRequestStore.set(ChatRoutesFixture.singleQuestionAsk, for: ChatRoutesFixture.sessionId)
            },
            control("chatRoutes.openFileViewer") {
                ChatRoutesFixture.openFromTimeline(
                    .workspaceFile(UserMessagePathPill(kind: .repoFile, path: ChatRoutesFixture.changedPath))
                )
            },
            // A PDF pill, with the chat's review-comment scope as a tapped pill has it.
            control("chatRoutes.openPDF") {
                ChatRoutesFixture.openFromTimeline(
                    .workspaceFile(UserMessagePathPill(kind: .repoFile, path: ChatRoutesPDF.path)),
                    reviewCommentSelectionScope: ReviewCommentSelectionActiveRouter
                        .router(for: ChatRoutesFixture.sessionId).map { .activeSession($0) }
                )
            },
            // What a busy-time send does to the chat (`ChatActionHandler.sendPrompt`): the chat
            // scrolls to its bottom, and the queue pill lands while that scroll is still moving.
            control("chatRoutes.queueFollowUp") { [scrollController] in
                scrollController.requestScrollToBottom()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    ChatRoutesFixture.queue(
                        "When the table work lands, rerun the iPad captures.",
                        as: .followUp,
                        on: ChatRoutesFixture.connection
                    )
                }
            },
            control("chatRoutes.endTurn") {
                let connection = ChatRoutesFixture.connection
                _ = connection.sessionStore.upsert(
                    ChatRoutesFixture.session(id: ChatRoutesFixture.sessionId, status: .ready)
                )
            },
        ])
        controls.axis = .vertical
        controls.spacing = 2
        paneResizeReadout?.install(in: view)
        for subview in [controls, landingProbe, createdSessionsProbe, surfaceActionsProbe] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let safeArea = view.safeAreaLayoutGuide
        // Below the middle of the leading edge, clear of the bar and the composer.
        let belowMiddle = controls.topAnchor.constraint(equalTo: safeArea.centerYAnchor, constant: 107)
        belowMiddle.priority = .defaultHigh
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            belowMiddle,
            // A docked software keyboard covers that spot on an iPad (a tap on the control missed at
            // hit point -1,-1), so the stack rides up to stay above the keyboard and the composer
            // that sits on it. With no keyboard the guide is the safe area's bottom and this holds.
            controls.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -Self.composerClearance),
            landingProbe.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            landingProbe.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            createdSessionsProbe.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            createdSessionsProbe.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            surfaceActionsProbe.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            surfaceActionsProbe.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard loops.isEmpty else { return }
        navigation.app.launchPhase = .ready
        navigation.app.showOnboarding = false
        loops = [
            Task { @MainActor [weak self] in
                // Holds the controller only for the write: a reference across the
                // sleep would keep a reset's previous root alive.
                while !Task.isCancelled {
                    guard let probe = self?.landingProbe else { return }
                    self?.setProbe(probe, ChatRoutesFixture.landingProbe())
                    try? await Task.sleep(for: .milliseconds(100))
                }
            },
            // The connect loop has no server to stream from, and it resets the
            // chat's state; keep Share and the queued report loaded.
            Task { @MainActor [connection] in
                while !Task.isCancelled {
                    ChatRoutesFixture.enableShare(on: connection)
                    ChatRoutesFixture.seedQueueIfNeeded(on: connection)
                    ChatRoutesFixture.seedSurfaceIfNeeded(on: connection)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            },
            // A busy session's store updates all the time, and each one repaints the footer
            // and the drawer in it (`CHAT_ROUTES_SURFACE=tall`).
            Task { @MainActor [connection] in
                var tick = 0
                while !Task.isCancelled, ChatRoutesFixture.ticksSession {
                    tick += 1
                    _ = connection.sessionStore.upsert(
                        ChatRoutesFixture.session(id: ChatRoutesFixture.sessionId, status: .ready, activityTick: tick)
                    )
                    try? await Task.sleep(for: .milliseconds(50))
                }
            },
        ]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        for loop in loops { loop.cancel() }
        loops = []
    }

    /// Observation re-runs this when the stub records a session or the chat
    /// asks app navigation for a reader.
    override func updateProperties() {
        super.updateProperties()
        setProbe(createdSessionsProbe, "\(ChatRoutesStubRecord.shared.createdSessions)")
        setProbe(surfaceActionsProbe, ChatRoutesStubRecord.shared.surfaceActions.joined(separator: ","))
        let target = openedChatReader
        guard target != pushedReader else { return }
        pushedReader = target
        // The chat opens its reader through app navigation; the shell that
        // pushes it is not here, so the harness does, after this update pass.
        guard let target else { return }
        let root = root
        DispatchQueue.main.async {
            ChatRoutesFixture.push(ChatReaderViewController(target: target, root: root))
        }
    }

    /// The reader the chat last asked app navigation to open.
    private var openedChatReader: ChatReaderNavTarget? {
        guard case .chatReader(let target)? = navigation.workspaceStackRouteElements.last else { return nil }
        return target
    }

    /// Room kept between the controls and the keyboard for the composer, which grows with its text.
    private static let composerClearance: CGFloat = 140

    /// A 12-point control a test taps by identifier.
    private func control(_ identifier: String, action: @escaping @MainActor () -> Void) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.01)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = identifier
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 12),
            button.heightAnchor.constraint(equalToConstant: 12),
        ])
        return button
    }

    /// A near-invisible text a test reads by identifier; it takes no touches.
    private static func probeLabel(_ identifier: String) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 8)
        label.alpha = 0.02
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = identifier
        return label
    }

    private func setProbe(_ label: UILabel?, _ value: String) {
        guard let label, label.text != value else { return }
        label.text = value
        label.accessibilityValue = value
    }
}

/// What the stub server received, so a test sees a save land.
@MainActor @Observable
private final class ChatRoutesStubRecord {
    static let shared = ChatRoutesStubRecord()
    var createdSessions = 0
    /// `<surfaceId>/<compositeId>/<actionId>` of each surface action the chat sent.
    var surfaceActions: [String] = []
}

enum ChatRoutesFixture {
    static let serverId = "chat-routes-server"
    static let sessionId = "chat-routes-session"
    static let commitSha = "abc1234"
    static let changedPath = "Sources/App.swift"
    /// A PDF in the home folder, which `/files/current` serves as a few pages
    /// of prose, so a pane shows a real document.
    static let pdfName = "field-guide.pdf"
    static let pdfData: Data = {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let paragraph = "Panes split a window into a chat and what it works on: a file, a terminal, a page. "
            + "Drag the divider to give one more room, double-tap it to share the window evenly, "
            + "and drag it past a pane to fold that pane into a strip you tap to bring back."
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            for number in 1...3 {
                context.beginPage()
                ("Field guide, part \(number)" as NSString).draw(
                    at: CGPoint(x: 72, y: 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .semibold)]
                )
                let body = Array(repeating: paragraph, count: 6).joined(separator: "\n\n") as NSString
                body.draw(
                    in: CGRect(x: 72, y: 124, width: page.width - 144, height: page.height - 196),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 13)]
                )
            }
        }
    }()

    /// What `/files/current` serves. `CHAT_ROUTES_LONG_FILE=1`: 60 lines, some
    /// far wider than a 369 pt pane, to see how a document wraps beside the chat.
    static let fileText: String = {
        if let lines = environment["CHAT_ROUTES_LONG_FILE"].flatMap(Int.init), lines > 1 {
            // Lines of varied length, many wider than a pane, so the reader wraps.
            return (1...lines).map { line in
                "let route\(line) = Route(name: \"route-\(line)\", path: \"/workspaces/\(line)/files\")"
                    + String(repeating: " .with(\"segment\")", count: line % 7)
            }.joined(separator: "\n") + "\n"
        }
        guard environment["CHAT_ROUTES_LONG_FILE"] == "1" else { return "let route = \"chat\"\n" }
        let wide = "let routeTable = [\"chat\": ChatRoute.chat, \"files\": ChatRoute.files, \"git\": ChatRoute.git, \"outline\": ChatRoute.outline]"
        return (1...60).map { $0 % 5 == 0 ? "    \(wide) // \($0)" : "func route\($0)() -> Int { \($0) }" }
            .joined(separator: "\n") + "\n"
    }()
    /// A Git change from outside the session.
    static let otherChangePath = "README.md"
    /// A file the session wrote outside Git's changes: the Git panel's This
    /// session opens the session's copy instead of a diff.
    static let touchedPath = "Notes/plan.md"
    /// A file the server no longer has: reading it answers 404 (`pane-restore`).
    static let removedFileName = "Removed.swift"
    static let skillName = "route-skill"
    static let seedMarkerId = "chat-routes-user"

    static let workspace = Workspace(
        id: "chat-routes-ws",
        name: "routes-workspace",
        description: nil,
        icon: .symbol("square.grid.2x2"),
        systemPrompt: nil,
        hostMount: "/tmp/oppi-chat-routes",
        tools: nil,
        gitStatusEnabled: true,
        runtime: .host,
        sandboxConfig: nil,
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// Built once per launch, before the chat mounts, and again after an
    /// in-process reset (`resetForTesting`).
    @MainActor static var connection: ServerConnection {
        if let built { return built }
        resetLocalState()
        let connection = makeConnection()
        built = connection
        return connection
    }

    @MainActor private static var built: ServerConnection?

    /// Back to a fresh process's fixture (`HarnessLaunchReset`): the next chat
    /// gets a new connection and local state, and the probes start empty.
    @MainActor static func resetForTesting() {
        built = nil
        stubQueue = .empty
        lastArrival = ""
        ChatRoutesStubRecord.shared.createdSessions = 0
        ChatRoutesStubRecord.shared.surfaceActions = []
    }

    @MainActor private static func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.setPreviewServerId(serverId)
        connection.setAPIClientForTesting(api)
        if ChatRoutesInternalURL.isEnabled { connection.setInternalURLViewSchemesForTesting(["proc"]) }
        // Context's usage and loaded skills come over the session socket,
        // which the harness never opens: answer `get_session_stats`, and fail
        // every other send the way an unopened socket does.
        connection._sendMessageForTesting = { [weak connection] message in
            if case .extensionUIAction(let surfaceId, let compositeId, let actionId, _, _, _, _, _) = message {
                // A socket that took the action; the server's settle never comes.
                Task { @MainActor in
                    ChatRoutesStubRecord.shared.surfaceActions.append("\(surfaceId)/\(compositeId)/\(actionId)")
                }
                return
            }
            guard case .getSessionStats(let requestId?) = message else {
                throw WebSocketError.notConnected
            }
            Task { @MainActor in
                _ = connection?.commands.resolveCommandResult(
                    command: "get_session_stats",
                    requestId: requestId,
                    success: true,
                    data: sessionStats,
                    error: nil
                )
            }
        }
        connection.workspaceStore.workspacesByServer[serverId] = [workspace]
        connection.sessionStore.switchServer(to: serverId)
        connection.sessionStore.upsert(session(
            id: sessionId,
            status: environment["CHAT_ROUTES_STATUS"] == "busy" ? .busy : .ready
        ))
        enableShare(on: connection)
        connection.chatState.cachedModels = models
        if let mode = environment["CHAT_ROUTES_ASK"], mode == "1" || mode == "single" {
            connection.askRequestStore.switchServer(to: serverId)
            _ = connection.askRequestStore.set(mode == "single" ? singleQuestionAsk : ask, for: sessionId)
        }
        return connection
    }

    /// `CHAT_ROUTES_QUEUE=long`: a subagent-style report queued as steering,
    /// far taller than the screen, so the drawer has to keep its own controls
    /// reachable. Reseeded like Share, since the connect loop clears the queue.
    @MainActor static func seedQueueIfNeeded(on connection: ServerConnection) {
        if environment["CHAT_ROUTES_QUEUE"] == "followup", stubQueue.followUp.isEmpty {
            queue("When the table work lands, rerun the iPad captures.", as: .followUp, on: connection)
        }
        if !stubQueue.steering.isEmpty || !stubQueue.followUp.isEmpty {
            if connection.messageQueueStore.queue(for: sessionId) != stubQueue {
                connection.messageQueueStore.apply(stubQueue, for: sessionId)
            }
            return
        }
        guard environment["CHAT_ROUTES_QUEUE"] == "long",
              connection.messageQueueStore.queue(for: sessionId).steering.isEmpty else { return }
        let rows = (1...40).map { "| `routes/step-\($0).ts:\($0 * 10)` | Route step \($0) | Keep |" }
        let report = (["## Route review", "", "| Path | Finding | Action |", "|---|---|---|"] + rows
            + ["", "**Edits and writes:** I edited and wrote nothing."]).joined(separator: "\n")
        connection.messageQueueStore.apply(
            MessageQueueState(
                version: 1,
                steering: [MessageQueueItem(id: "routes-queued-report", message: report, createdAt: 0)],
                followUp: []
            ),
            for: sessionId
        )
    }

    /// What the stub server's queue holds (`CHAT_ROUTES_QUEUE=followup`, `chatRoutes.queueFollowUp`);
    /// the reseed loop keeps the chat's queue on it.
    @MainActor private static var stubQueue = MessageQueueState.empty

    /// Adds a message to the stub server's queue and reports the queue, as the server does once
    /// it holds a busy-time send.
    @MainActor static func queue(_ text: String, as behavior: StreamingBehavior, on connection: ServerConnection) {
        let item = MessageQueueItem(id: "routes-queued-\(stubQueue.version + 1)", message: text, createdAt: 0)
        stubQueue.version += 1
        switch behavior {
        case .steer: stubQueue.steering.append(item)
        case .followUp: stubQueue.followUp.append(item)
        }
        connection.messageQueueStore.apply(stubQueue, for: sessionId)
    }

    /// `CHAT_ROUTES_SURFACE=tall`: a table card of 14 rows, then an Actions card, in one
    /// surface above the composer. Reseeded like Share, since the connect loop clears surfaces.
    @MainActor static func seedSurfaceIfNeeded(on connection: ServerConnection) {
        let widget: [ExtensionUINotification]? = if let path = environment["CHAT_ROUTES_NATIVE_WIDGET_FILE"] {
            ChatRoutesNativeWidget.notifications(path: path)
        } else if environment["CHAT_ROUTES_SURFACE"] == "subagents" {
            ChatRoutesNativeWidget.notifications(data: ChatRoutesNativeWidget.subagentsJSON())
        } else if environment["CHAT_ROUTES_SURFACE"] == "subagents-many" {
            ChatRoutesNativeWidget.notifications(data: ChatRoutesNativeWidget.subagentsJSON(extraWorking: 6))
        } else {
            nil
        }
        if let widget {
            guard connection.extensionSurfaces.surface(for: sessionId).state.nativeSurfaces.isEmpty else { return }
            for notification in widget {
                connection.extensionSurfaces.apply(notification, sessionId: sessionId)
            }
            return
        }
        let documents: [Data] = if let paths = environment["CHAT_ROUTES_SURFACE_FILE"] {
            paths.split(separator: ",").compactMap { FileManager.default.contents(atPath: String($0)) }
        } else if environment["CHAT_ROUTES_SURFACE"] == "tall" {
            [Data(tallSurfaceJSON.utf8)]
        } else if environment["CHAT_ROUTES_SURFACE"] == "jobs" {
            [Data(ChatRoutesJobsSurface.json.utf8)]
        } else if environment["CHAT_ROUTES_SURFACE"] == "panel" {
            [Data(panelSurfaceJSON.utf8)]
        } else {
            []
        }
        guard !documents.isEmpty,
              connection.extensionSurfaces.surface(for: sessionId).state.composableSurfaces.isEmpty
        else { return }
        for json in documents {
            guard let surface = try? JSONDecoder().decode(ExtensionUISurface.self, from: json) else { continue }
            connection.extensionSurfaces.apply(surface, sessionId: sessionId)
        }
    }

    /// Whether the session's activity clock ticks, repainting the footer (`CHAT_ROUTES_SURFACE=tall`).
    static var ticksSession: Bool { ["tall", "jobs"].contains(environment["CHAT_ROUTES_SURFACE"] ?? "") }

    static let tallSurfaceId = "query"
    static let tallSurfaceActionsCardId = "actions"
    static let tallSurfaceActionId = "again"

    private static let panelSurfaceJSON = #"""
    {"version":2,"id":"jobs","title":"Jobs","placement":{"kind":"panel","preferred":"aboveComposer"},
     "panel":{"icon":"terminal","size":"wide"},"lifecycle":"persistent",
     "header":{"title":"Jobs","subtitle":"1 running · 2 finished"},
     "sections":[{"composite":"blocks","id":"list","state":{"kind":"content"},"actions":["refresh"],
       "fallback":{"text":"1 job running"},
       "body":{"type":"stack","children":[{"type":"text","text":"npm test · running"}]}}],
     "actions":{"refresh":{"title":"Refresh"}},"fallback":{"text":"1 job running"},"revision":7,
     "extensionScopeId":"npm:deploy-helper","extensionDisplayName":"Deploy Helper"}
    """#

    private static var tallSurfaceJSON: String {
        let rows = (1...14).map { index in
            #"{"id":"row\#(index)","cells":{"name":"table_\#(index)","rows":\#(index * 100)}}"#
        }.joined(separator: ",")
        return #"""
        {
          "version": 2, "id": "\#(tallSurfaceId)", "title": "Query",
          "placement": {"kind": "strip", "preferred": "aboveComposer"},
          "lifecycle": "persistent",
          "header": {"title": "telemetry.db", "subtitle": "14 rows"},
          "actions": {"\#(tallSurfaceActionId)": {"title": "Run again", "role": "primary"}},
          "fallback": {"text": "telemetry.db: 14 rows"},
          "revision": 1,
          "sections": [
            {"composite": "dataTable", "id": "rows", "header": {"title": "Schema objects"},
             "state": {"kind": "content"}, "fallback": {"text": "Schema objects"},
             "columns": [{"id": "name", "title": "Name"}, {"id": "rows", "title": "Rows", "kind": "number"}],
             "rows": [\#(rows)]},
            {"composite": "actionBar", "id": "\#(tallSurfaceActionsCardId)", "header": {"title": "Actions"},
             "state": {"kind": "content"}, "actions": ["\#(tallSurfaceActionId)"],
             "fallback": {"text": "Actions"}}
          ]
        }
        """#
    }

    @MainActor static func enableShare(on connection: ServerConnection) {
        guard connection.chatState.slashCommands.isEmpty else { return }
        connection.chatState.slashCommands = [
            SlashCommand(name: "share", description: "Share session", source: .builtin),
        ]
    }

    /// One staged review comment, the recommended share policy, and the Files
    /// panel on Changed on every launch.
    @MainActor private static func resetLocalState() {
        AppPreferences.Share.setRedactionPolicy(.recommended)
        let store = ReviewCommentStore()
        store.load(workspaceId: workspace.id, sessionId: sessionId)
        for comment in store.comments {
            store.delete(commentId: comment.id)
        }
        guard environment["CHAT_ROUTES_REVIEW_COMMENT"] != "none" else { return }
        _ = try? store.create(
            workspaceId: workspace.id,
            sessionId: sessionId,
            body: "Route comment",
            reference: ReviewCommentReference(
                source: .timelineText,
                label: "Timeline",
                path: nil,
                side: nil,
                startLine: nil,
                endLine: nil,
                selectedText: "Routes",
                languageHint: nil,
                toolCallId: nil,
                timelineItemId: seedMarkerId,
                url: nil
            )
        )
    }

    static func session(id: String, status: SessionStatus, activityTick: Int = 0) -> Session {
        Session(
            id: id,
            workspaceId: workspace.id,
            workspaceName: workspace.name,
            name: id == sessionId
                ? ProcessInfo.processInfo.environment["CHAT_ROUTES_SESSION_TITLE"] ?? "Routes"
                : "New routes session",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_770_000_010),
            lastActivity: Date(timeIntervalSince1970: 1_770_000_020 + TimeInterval(activityTick)),
            model: "anthropic/claude-routes",
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0, cacheRead: nil, cacheWrite: nil),
            cost: 0,
            changeStats: SessionChangeStats(
                mutatingToolCalls: 1,
                filesChanged: 2 + manyChangePaths.count,
                changedFiles: [changedPath, touchedPath] + manyChangePaths,
                changedFilesOverflow: nil
            ),
            contextTokens: 1_000,
            contextWindow: 128_000,
            firstMessage: nil,
            lastMessage: nil,
            thinkingLevel: "medium",
            warnings: id == sessionId ? warnings : nil
        )
    }

    /// `CHAT_ROUTES_WARNINGS=N`: N session launch warnings, on the notice chip above the
    /// composer. `CHAT_ROUTES_WARNINGS=launch`: the one long warning a classic Agent launch
    /// writes when the server drops every MCP tool its allowlist named.
    private static var warnings: [String]? {
        switch environment["CHAT_ROUTES_WARNINGS"] {
        case "launch":
            return [
                "Configured Agent tools are unavailable and was dropped from this session: "
                    + ["mcp__gmail__account", "mcp__gmail__search", "mcp__gmail__read", "mcp__gmail__thread",
                       "mcp__gmail__labels", "mcp__gmail__save_attachments", "mcp__gmail__modify",
                       "mcp__gmail__archive", "mcp__gmail__trash", "mcp__gmail__spam", "mcp__gmail__draft",
                       "mcp__gmail__send", "mcp__coros__queryDailyHealthData", "mcp__coros__querySleepOverview",
                       "mcp__coros__queryRecoveryStatus", "mcp__coros__queryTrainingLoadAssessment",
                       "mcp__coros__getActivityDetail", "mcp__coros__createScheduledWorkout"].joined(separator: ", ")
                    + ". The session continues with the remaining allowed tools. Edit the Agent's Allowed "
                    + "Tools or selected Extensions to stop this warning.",
            ]
        case let raw? where (Int(raw) ?? 0) > 0:
            let count = Int(raw) ?? 0
            return (1...count).map {
                "Routes warning \($0): the fixture session launched without this one configured tool."
            }
        default:
            return nil
        }
    }

    static let sessionStats: JSONValue = [
        "tokens": ["input": 800, "output": 200, "cacheRead": 0, "cacheWrite": 0, "total": 1_000],
        "cost": 0.01,
        "contextComposition": [
            "piSystemPromptTokens": 500,
            "agentsTokens": 100,
            "agentsFiles": [["path": "/tmp/oppi-chat-routes/AGENTS.md", "chars": 400, "tokens": 100]],
            "skillsListingTokens": 50,
            "compactionReserveTokens": 16_384,
            "tools": [
                ["name": "read", "tokens": 160, "inContext": true, "source": ["kind": "builtin", "name": ""]],
                ["name": "weather", "tokens": 120, "inContext": true, "source": ["kind": "extension", "name": "weather", "path": .string(extensionPath)]],
                ["name": "forecast", "tokens": 300, "inContext": false, "source": ["kind": "extension", "name": "weather", "path": .string(extensionPath)]],
                ["name": "mcp__docs__search", "tokens": 400, "inContext": false, "source": ["kind": "mcp", "name": "docs"]],
                ["name": "mcp__docs__fetch", "tokens": 250, "inContext": false, "source": ["kind": "mcp", "name": "docs"]],
            ],
        ],
        "loadedResources": [
            "skills": [["name": .string(skillName), "description": "Routes through the panel", "path": "/tmp/oppi-chat-routes/.pi/skills/route-skill"]],
            "extensions": [["name": "weather", "path": .string(extensionPath)]],
        ],
    ]

    static let extensionPath = "/tmp/oppi-chat-routes/.pi/extensions/weather.ts"

    static let models = [
        ModelInfo(id: "claude-routes", name: "Claude Routes", provider: "anthropic", contextWindow: 200_000),
        ModelInfo(id: "claude-sonnet-routes", name: "Claude Sonnet Routes", provider: "anthropic", contextWindow: 200_000),
        ModelInfo(id: "gpt-routes", name: "GPT Routes", provider: "openai", contextWindow: 200_000),
    ]

    /// `CHAT_ROUTES_ASK=single`: one question, so a typed answer sent from the composer submits
    /// the whole ask.
    static let singleQuestionAsk = AskRequest(
        id: "chat-routes-ask",
        sessionId: sessionId,
        questions: [ask.questions[0]],
        allowCustom: true,
        timeout: nil,
        workspaceId: workspace.id
    )

    static let ask = AskRequest(
        id: "chat-routes-ask",
        sessionId: sessionId,
        questions: [
            AskQuestion(
                id: "first",
                question: "Which route first?",
                options: [AskOption(value: "sheet", label: "Sheet"), AskOption(value: "popover", label: "Popover")],
                multiSelect: false
            ),
            AskQuestion(
                id: "second",
                question: "Which route next?",
                options: [AskOption(value: "push", label: "Push"), AskOption(value: "column", label: "Column")],
                multiSelect: false
            ),
        ],
        allowCustom: true,
        timeout: nil,
        workspaceId: workspace.id
    )

    /// `CHAT_ROUTES_MANY_CHANGES=1`: 120 more files the session changed, so
    /// the Git button's badge reads 99+ (`chat-top-bar-reordered`).
    static let manyChangePaths: [String] = environment["CHAT_ROUTES_MANY_CHANGES"] == "1"
        ? (1...120).map { "Sources/Generated/Route\($0).swift" }
        : []

    static let gitStatus = GitStatus(
        isGitRepo: true,
        branch: "main",
        headSha: commitSha,
        ahead: 0,
        behind: 0,
        dirtyCount: 2 + manyChangePaths.count,
        untrackedCount: 0,
        stagedCount: 0,
        // README.md is a change the session did not make: the Git panel's
        // This session lists App.swift alone, All changes both.
        files: [
            GitFileStatus(status: " M", path: changedPath, addedLines: 2, removedLines: 1),
            GitFileStatus(status: " M", path: otherChangePath, addedLines: 4, removedLines: 0),
        ] + manyChangePaths.map { GitFileStatus(status: " M", path: $0, addedLines: 1, removedLines: 0) },
        totalFiles: 2 + manyChangePaths.count,
        addedLines: 6 + manyChangePaths.count,
        removedLines: 1,
        stashCount: 0,
        lastCommitMessage: "Route commit",
        lastCommitDate: nil,
        recentCommits: [GitCommitSummary(sha: commitSha, message: "Route commit", date: "2026-10-15T18:00:00Z")]
    )

    /// A user message with a commit pill and a file pill, then filler turns so
    /// the outline has entries, into the chat's own reducer.
    @MainActor static func seedTimelineIfNeeded(into reducer: TimelineReducer) {
        guard !reducer.items.contains(where: { $0.id == seedMarkerId }) else { return }
        let userText = UserMessageAttachmentPresentation.makeDisplayText(
            text: "Review the routes",
            pendingAttachments: [],
            pendingRepoPointers: [
                PendingFileReference(path: commitSha, isDirectory: false, kind: .gitCommit, commitMessage: "Route commit"),
                PendingFileReference(path: changedPath, isDirectory: false),
            ]
        )
        var events = [traceEvent(id: seedMarkerId, type: .user, text: userText)]
        for turn in 1...4 {
            events.append(traceEvent(id: "chat-routes-assistant-\(turn)", type: .assistant, text: "ROUTES_FILL_\(turn) reply."))
        }
        // Two file links and a folder link, for the link menu's panes and
        // where a tapped link opens (`PaneLinkMenuUITests`).
        events.append(traceEvent(
            id: "chat-routes-assistant-links", type: .assistant,
            text: "The routes are in [[Route.md]], the first entry in [[Alpha.txt]].\n\nViews: [Sources](Sources/)."
        ))
        if let turns = environment["CHAT_ROUTES_LONG_TURNS"].flatMap(Int.init) {
            events += longSessionEvents(turns: turns)
        }
        if let path = environment["CHAT_ROUTES_TRACE_FILE"],
           let data = FileManager.default.contents(atPath: path),
           let trace = try? JSONDecoder().decode([TraceEvent].self, from: data) {
            events += trace
        }
        // `CHAT_ROUTES_WEB_LINK=<url>`: a reply linking a page (a UI test's own
        // server), by name and as a bare address long enough to wrap.
        if let link = environment["CHAT_ROUTES_WEB_LINK"] {
            let bare = "\(link)?ref=magic-keyboard-with-touch-id-for-mac-models-with-apple-silicon-usb-c-us-english"
            events.append(traceEvent(
                id: "chat-routes-web-link", type: .assistant,
                text: "The preview is up: [Open the preview](\(link)).\n\nThe same page:\n\(bare)"
            ))
        }
        // `CHAT_ROUTES_NOTEBOOK_LINK=1`: a reply linking the garden notebook
        // (an Org file several screens long), where a file a chat links to
        // opens and how wide it reads (`ReadingWidthUITests`).
        if environment["CHAT_ROUTES_NOTEBOOK_LINK"] == "1" {
            events.append(traceEvent(
                id: "chat-routes-notebook-link", type: .assistant,
                text: "I moved the spring planting into the season plan: peas along the trellis, lettuce once the nights "
                    + "stay above 5 °C, and the bed table now shows this year beside last. It's in "
                    + "[[garden.org]]."
            ))
        }
        if environment["CHAT_ROUTES_LIVE_WORK"] == "1" {
            events += liveWorkEvents
        }
        reducer.loadSession(events)
    }

    /// `CHAT_ROUTES_LIVE_WORK=1`: a prompt, then thinking and a tool call with no result yet.
    static let liveToolCallID = "chat-routes-live-tool"
    /// The prompt is a few seconds old at launch, so the turn's clock reads like a live one.
    private static var liveWorkEvents: [TraceEvent] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = { (secondsAgo: TimeInterval) in formatter.string(from: Date().addingTimeInterval(-secondsAgo)) }
        return [
            TraceEvent(id: "chat-routes-live-user", type: .user, timestamp: stamp(8), text: "Rerun the route checks."),
            TraceEvent(
                id: "chat-routes-live-thinking",
                type: .thinking,
                timestamp: stamp(7),
                thinking: "Run the route checks before answering."
            ),
            TraceEvent(
                id: liveToolCallID,
                type: .toolCall,
                timestamp: stamp(6),
                tool: "bash",
                args: ["command": .string("npm run check:routes")]
            ),
        ]
    }

    /// `CHAT_ROUTES_LONG_TURNS=N`: N agent turns of thinking, a bash call
    /// (`LONG_BASH_<n>`), and a reply of varying length, so rows far from
    /// the tail sit at estimated heights until a jump realizes them.
    private static func longSessionEvents(turns: Int) -> [TraceEvent] {
        var events: [TraceEvent] = []
        for turn in 0..<turns {
            if turn.isMultiple(of: 12) {
                events.append(traceEvent(id: "long-user-\(turn)", type: .user, text: "LONG_USER_\(turn) keep going."))
            }
            events.append(TraceEvent(
                id: "long-thinking-\(turn)",
                type: .thinking,
                timestamp: "2026-10-15T18:00:00.000Z",
                thinking: "LONG_THINK_\(turn) check the next step before running it. "
                    + String(repeating: "Weigh what the last output said and pick the next command. ", count: turn % 5)
            ))
            let command = "cd ~/workspace/oppi && echo LONG_BASH_\(turn)"
                + String(repeating: " && git status --short", count: turn % 4)
            events.append(TraceEvent(
                id: "long-bash-\(turn)",
                type: .toolCall,
                timestamp: "2026-10-15T18:00:00.000Z",
                tool: "bash",
                args: ["command": .string(command)]
            ))
            events.append(TraceEvent(
                id: "long-bash-result-\(turn)",
                type: .toolResult,
                timestamp: "2026-10-15T18:00:01.000Z",
                output: (0...(turn % 6)).map { "LONG_BASH_\(turn) line \($0)" }.joined(separator: "\n"),
                toolCallId: "long-bash-\(turn)",
                toolName: "bash",
                isError: false
            ))
            events.append(traceEvent(
                id: "long-assistant-\(turn)",
                type: .assistant,
                text: "LONG_REPLY_\(turn) " + String(repeating: "The step finished and the next one follows. ", count: 1 + (turn * 7) % 9)
                    + (turn.isMultiple(of: 3)
                        ? "\n\n## Notes \(turn)\n\n- first point with `code`\n- second point\n\n```swift\nlet turn = \(turn)\nprint(turn)\n```\n"
                        : "")
            ))
        }
        return events
    }

    /// The last row seen arriving, and whether a modal covered the chat then.
    /// Latched: UI tests wait for the app to idle, which outlasts the arrival.
    @MainActor private static var lastArrival = ""

    /// Where the timeline sits under its top chrome, for outline-jump tests:
    /// `top=<row id>@<y>`, the first row reaching below the top inset and its
    /// top edge relative to that inset; `arrived=<row id>/<open|covered>`, the
    /// last row seen arriving after a jump; `end=<0|1>`, whether the timeline
    /// sits at its scroll limit, where a row near the tail cannot reach the top
    /// edge because less than a viewport of content follows it.
    @MainActor static func landingProbe() -> String {
        guard let collection = timelineCollectionInWindows(),
              let controller = collection.delegate as? ChatTimelineController else { return "" }
        let insetTop = collection.adjustedContentInset.top
        var top = ""
        var topY = CGFloat.greatestFiniteMagnitude
        var lit = ""
        for indexPath in collection.indexPathsForVisibleItems where indexPath.item < controller.currentIDs.count {
            guard let attributes = collection.layoutAttributesForItem(at: indexPath) else { continue }
            let id = controller.currentIDs[indexPath.item]
            let relativeY = attributes.frame.minY - collection.contentOffset.y - insetTop
            if attributes.frame.maxY - collection.contentOffset.y > insetTop + 1, relativeY < topY {
                topY = relativeY
                top = id
            }
            if (collection.cellForItem(at: indexPath) as? SafeSizingCell)?.isShowingNavigationHighlightForTesting == true {
                lit = id
            }
        }
        if !lit.isEmpty {
            let covered = collection.window?.rootViewController?.presentedViewController != nil
            lastArrival = "\(lit)/\(covered ? "covered" : "open")"
        }
        let y = top.isEmpty ? "-" : String(Int(topY.rounded()))
        let atEnd = collection.contentOffset.y >= TimelineOffsetController.clampedOffsetY(.greatestFiniteMagnitude, in: collection) - 1
        return "top=\(top)@\(y) arrived=\(lastArrival) inset=\(Int(insetTop)) end=\(atEnd ? 1 : 0)"
    }

    private static func traceEvent(id: String, type: TraceEventType, text: String) -> TraceEvent {
        TraceEvent(
            id: id,
            type: type,
            timestamp: "2026-10-15T18:00:00.000Z",
            text: text,
            tool: nil,
            args: nil,
            output: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            thinking: nil
        )
    }

    /// What a timeline pill tap does: the destination action the chat gave its
    /// timeline (a modal or the attached leaf, by width).
    @MainActor static func openFromTimeline(
        _ destination: ChatTimelineDestination,
        reviewCommentSelectionScope: ReviewCommentSelectionScope? = nil
    ) {
        guard let timeline = timelineCollectionInWindows(),
              let open = (timeline.delegate as? ChatTimelineController)?.openDestination,
              let presenter = sequence(first: timeline as UIResponder, next: \.next)
                .lazy.compactMap({ $0 as? UIViewController }).first else { return }
        open(ChatTimelineDestinationRequest(
            destination: destination,
            serverId: serverId,
            workspaceId: workspace.id,
            sessionId: sessionId,
            reviewCommentSelectionScope: reviewCommentSelectionScope,
            sourceView: timeline,
            presenter: presenter
        ))
    }

    /// Pushes a screen onto the chat's navigation controller.
    @MainActor static func push(_ screen: UIViewController) {
        guard let timeline = timelineCollectionInWindows(),
              let navigation = sequence(first: timeline as UIResponder, next: \.next)
                .lazy.compactMap({ $0 as? UINavigationController }).first else { return }
        navigation.pushViewController(screen, animated: true)
    }

    @MainActor private static func timelineCollectionInWindows() -> UICollectionView? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let collection = timelineCollection(in: window) { return collection }
            }
        }
        return nil
    }

    @MainActor private static func timelineCollection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView, collection.accessibilityIdentifier == "chat.timeline" {
            return collection
        }
        for child in view.subviews {
            if let found = timelineCollection(in: child) { return found }
        }
        return nil
    }

    /// A client whose requests `ChatRoutesURLProtocol` answers in-process.
    @MainActor static let api: APIClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatRoutesURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(ChatRoutesURLProtocol.host)") ?? URL(fileURLWithPath: "/"),
            token: "preview-token",
            configuration: config
        )
    }()
}

/// The chat's server, for the requests the routes make: Git status, the
/// commit graph, a commit and its diff, a review diff, file text, the workspace root listing, a
/// skill and its file, models, session changes, and a new session (counted).
/// Everything else is a 404.
private final class ChatRoutesURLProtocol: URLProtocol {
    static let host = "chat-routes.oppi"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let workspace = "/workspaces/chat-routes-ws"
        let body: Data?
        var contentType = "application/json"
        if let view = ChatRoutesInternalURL.answer(request.httpMethod ?? "GET", url) {
            return respond(url, body: view, contentType: "application/json")
        }
        if let game = ChatRoutesGodot.answer(request.httpMethod ?? "GET", url.path) {
            if game.hangs { return }
            return respond(url, body: game.body, contentType: game.contentType)
        }
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "\(workspace)/git/status"):
            body = try? JSONEncoder().encode(ChatRoutesFixture.gitStatus)
        case ("GET", "\(workspace)/git/graph"):
            body = Self.json(Self.graph(url))
        case ("GET", "\(workspace)/git/commits/abc1234"):
            body = Self.json([
                "sha": "abc1234",
                "message": "Route commit",
                "date": "2026-10-15T18:00:00Z",
                "author": "Alex",
                "files": [["path": "Sources/App.swift", "status": "M", "addedLines": 2, "removedLines": 1]],
                "addedLines": 2,
                "removedLines": 1,
            ])
        case ("GET", "\(workspace)/git/commits/abc1234/diff"), ("GET", "\(workspace)/git/diff"):
            body = Self.json(Self.diff)
        case ("POST", "\(workspace)/sessions/chat-routes-session/command"):
            // The server took the command (an ask's answer) and settled it.
            body = Self.json(["messages": [Any]()])
        case ("GET", "\(workspace)/quick-actions"):
            body = Self.json(["actions": []])
        case ("GET", "\(workspace)/sessions/chat-routes-session/changes"):
            body = Self.json([
                "workspaceId": "chat-routes-ws",
                "sessionId": "chat-routes-session",
                // The full list matches the session's `changeStats`, as the server's does.
                "files": ([ChatRoutesFixture.changedPath, ChatRoutesFixture.touchedPath] + ChatRoutesFixture.manyChangePaths)
                    .map { ["path": $0] },
                "changedFileCount": 2 + ChatRoutesFixture.manyChangePaths.count,
                "changedFilesOverflow": 0,
            ])
        case ("GET", "\(workspace)/contents"):
            // Alpha.txt sorts before Route.md by name and after it by date,
            // so a re-sort visibly flips them. Sources/ holds Git's change.
            var entries: [[String: Any]] = [
                ["name": "Sources", "path": "Sources/", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "Alpha.txt", "path": "Alpha.txt", "type": "file", "size": 10, "modifiedAt": 1_700_000_000_000],
                ["name": "Route.md", "path": "Route.md", "type": "file", "size": 40, "modifiedAt": 1_900_000_000_000],
            ]
            if ProcessInfo.processInfo.environment["CHAT_ROUTES_NOTEBOOK_LINK"] == "1" {
                // The reply's [[garden.org]] resolves against this folder.
                entries.append(["name": "garden.org", "path": "garden.org", "type": "file", "size": 9_800, "modifiedAt": 1_900_000_000_000])
            }
            body = Self.json(["path": "", "entries": entries, "truncated": false])
        case ("GET", "\(workspace)/contents/Sources"):
            body = Self.json([
                "path": "Sources/",
                "entries": [
                    ["name": "App.swift", "path": "Sources/App.swift", "type": "file", "size": 20, "modifiedAt": 1_800_000_000_000],
                    ["name": "RouteView.swift", "path": "Sources/RouteView.swift", "type": "file", "size": 30, "modifiedAt": 1_800_000_000_000],
                ],
                "truncated": false,
            ])
        case ("GET", "/host/contents/notebook"):
            // The home folder's notebook, as a pinned folder opens it.
            let entries: [[String: Any]] = [
                ["name": "journal", "path": "notebook/journal/", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "notes", "path": "notebook/notes/", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "projects", "path": "notebook/projects/", "type": "directory", "size": 0, "modifiedAt": 1_800_000_000_000],
                ["name": "garden.org", "path": "notebook/garden.org", "type": "file", "size": 9_800, "modifiedAt": 1_900_000_000_000],
                ["name": "index.org", "path": "notebook/index.org", "type": "file", "size": 6_000, "modifiedAt": 1_900_000_000_000],
            ]
            body = Self.json(["path": "notebook/", "entries": entries, "truncated": false])
        case ("GET", "/files/current") where (url.query ?? "").contains(ChatRoutesPDF.fileName):
            contentType = "application/pdf"
            body = ChatRoutesPDF.data
        case ("GET", "/files/current") where (url.query ?? "").contains(ChatRoutesFixture.pdfName):
            contentType = "application/pdf"
            body = ChatRoutesFixture.pdfData
        case ("GET", "/files/current") where (url.query ?? "").contains(".org"):
            contentType = "text/plain"
            body = Data(FileBrowserColumnFixture.gardenOrg.utf8)
        case ("GET", "/pins"):
            // The fixture chat, the home folder's notebook, and the field
            // guide PDF, as the Pinned screen lists a server's pins.
            body = Data(#"""
            {"revision":3,"pins":[
            {"id":"pin_RouteChat001","target":{"kind":"session","id":"chat-routes-session"},"createdAt":1,"status":"ok"},
            {"id":"pin_Notebook0002","target":{"kind":"files","origin":"host","path":"~/notebook"},"createdAt":2,"status":"ok"},
            {"id":"pin_FieldGuide03","target":{"kind":"file","origin":"host","path":"~/field-guide.pdf","line":null},"createdAt":3,"status":"ok"}]}
            """#.utf8)
        case ("GET", "/skills/route-skill"):
            body = Self.json([
                "skill": ["name": "route-skill", "description": "Routes through the panel", "path": "/tmp/oppi-chat-routes/.pi/skills/route-skill"],
                "content": "# Route skill\n\nOpens inside the Context panel.",
                "files": ["SKILL.md", "notes.md"],
            ])
        case ("GET", "/skills/route-skill/file"):
            body = Self.json(["content": "Route skill notes\n"])
        case ("GET", "\(workspace)/paths"):
            // "route" matches Route.md at the root and RouteView.swift in
            // Sources/: a search there differs by scope.
            body = Self.json([
                "paths": ["Alpha.txt", "Route.md", "Sources/App.swift", "Sources/RouteView.swift"],
                "truncated": false,
            ])
        case ("GET", "/files/current") where !(url.query ?? "").contains(ChatRoutesFixture.removedFileName):
            contentType = "text/plain"
            body = Data(ChatRoutesFixture.fileText.utf8)
        case ("GET", "/models"):
            body = Self.json([
                "models": ChatRoutesFixture.models.map { model in
                    ["id": model.id, "name": model.name, "provider": model.provider, "contextWindow": model.contextWindow, "isDefault": false]
                },
            ])
        case ("POST", "\(workspace)/sessions"):
            struct Created: Encodable { let session: Session }
            body = try? JSONEncoder().encode(Created(
                session: ChatRoutesFixture.session(id: "chat-routes-new-session", status: .ready)
            ))
            Task { @MainActor in ChatRoutesStubRecord.shared.createdSessions += 1 }
        default:
            body = nil
        }
        respond(url, body: body, contentType: contentType)
    }

    private func respond(_ url: URL, body: Data?, contentType: String) {
        let payload = body ?? Data(#"{"error":"Not found"}"#.utf8)
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType, "Content-Length": String(payload.count)]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The Git panel's graph in two pages: the session's commit on main and a
    /// branch another worktree has out, then (offset 2) the tagged base both
    /// grew from.
    private static func graph(_ url: URL) -> [String: Any] {
        let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
        let commits = graphCommits.dropFirst(offset).prefix(2)
        var page: [String: Any] = ["commits": Array(commits), "hasMore": offset + commits.count < graphCommits.count]
        if offset == 0 { page["worktrees"] = graphWorktrees }
        return page
    }

    private static var graphCommits: [[String: Any]] { [
        [
            "sha": "abc1234" + String(repeating: "0", count: 33), "shortSha": "abc1234",
            "parents": ["def5678" + String(repeating: "0", count: 33)], "message": "Route commit",
            "date": "2026-10-15T18:00:00Z",
            "refs": [["kind": "branch", "name": "main", "isHead": true]],
        ],
        [
            "sha": "9a8b7c6" + String(repeating: "0", count: 33), "shortSha": "9a8b7c6",
            "parents": ["def5678" + String(repeating: "0", count: 33)], "message": "Side branch work",
            "date": "2026-10-15T17:00:00Z",
            "refs": [["kind": "branch", "name": "feat/routes"]],
        ],
        [
            "sha": "def5678" + String(repeating: "0", count: 33), "shortSha": "def5678",
            "parents": [String](), "message": "Base commit",
            "date": "2026-10-14T18:00:00Z",
            "refs": [["kind": "tag", "name": "v1"], ["kind": "remote", "name": "origin/main"]],
        ],
    ] }

    private static var graphWorktrees: [[String: Any]] { [
        [
            "id": "main", "name": "oppi", "path": "/tmp/oppi-chat-routes", "branch": "main",
            "headSha": "abc1234", "isMain": true, "isGitRepo": true,
        ],
        [
            "id": "wt_routes", "name": "wt_routes", "path": "/tmp/oppi-chat-routes-wt", "branch": "feat/routes",
            "headSha": "9a8b7c6", "isMain": false, "isGitRepo": true,
        ],
    ] }

    private static var diff: [String: Any] { [
        "workspaceId": "chat-routes-ws",
        "path": "Sources/App.swift",
        "baselineText": "let route = \"swiftui\"\n",
        "currentText": "let route = \"uikit\"\n",
        "addedLines": 1,
        "removedLines": 1,
        "hunks": [
            [
                "oldStart": 1,
                "oldCount": 1,
                "newStart": 1,
                "newCount": 1,
                "lines": [
                    ["kind": "removed", "text": "let route = \"swiftui\"", "oldLine": 1, "newLine": NSNull(), "spans": NSNull()],
                    ["kind": "added", "text": "let route = \"uikit\"", "oldLine": NSNull(), "newLine": 1, "spans": NSNull()],
                ],
            ],
        ],
    ] }

    private static func json(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}
#endif
