#if DEBUG
import UIKit

/// The UIKit router with real screens and fixture services, no network
/// (`SCREENSHOT_SCREEN=router-routes`): a `RouterNavigationController` whose
/// root is the route list (large title, bottom bar). Quick Comments is pushed
/// and opens its editor sheet (detents, navigation) and the icon popover; Edit
/// Agent is a full-screen modal that pushes its Tools page; Edit Schedule opens
/// the time zone search sheet; both editors open the model picker. The editors
/// save to an in-process stub server, and "Last save sent" shows what reached
/// it. `SCREENSHOT_COLOR_SCHEME=light|dark` pins the theme.
final class RouterRoutesPreviewController: PreviewRootController {
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
        let root = AppRootEnvironment(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            navigation: AppNavigation(),
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )
        super.init(
            root: root,
            themeStore: root.themeStore,
            content: PreviewHost.screenStack(root: root) { RouterRoutesMenuViewController(root: root) }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The routes the router owns, as a list screen: a push through `Router.push`,
/// and the two editors in their own `RouterModalPresenter` slots. The SwiftUI
/// list's `.bottomBar` text ("Dismissed 0") is the toolbar's own label, and its
/// "Last save sent" section reads the stub server's last write; both keep the
/// identifiers `RouterRoutesUITests` reads.
final class RouterRoutesMenuViewController: ListScreenController<RouterRoutesMenuViewController.Section, RouterRoutesMenuViewController.Item> {
    enum Section: Hashable, Sendable { case routes, lastSave }
    enum Item: Hashable, Sendable { case quickComments, editAgent, editSchedule, lastSave }

    private let root: AppRootEnvironment
    private let agentEditor = RouterModalPresenter()
    private let scheduleEditor = RouterModalPresenter()
    private var editingAgent: StoredAgentDefinition?
    private var editsSchedule = false
    /// What the modals closed: the SwiftUI `routerModal` slots bumped it on
    /// every dismissal, swipe-down included.
    private var dismissedModals = 0
    private let dismissedLabel = UILabel()

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(title: "Router Routes", listIdentifier: "routerRoutes.list", headers: true, largeTitle: true)
        traitOverrides.appRootEnvironment = root
        for presenter in [agentEditor, scheduleEditor] { presenter.anchor = self }
        dismissedLabel.accessibilityIdentifier = "routerRoutes.dismissedModals"
        dismissedLabel.font = .preferredFont(forTextStyle: .body)
        setToolbarItems([
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(customView: dismissedLabel),
            UIBarButtonItem(systemItem: .flexibleSpace),
        ], animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyTitleDisplayMode()
        // The SwiftUI bar's `.showsToolbar` kept the toolbar up for the menu;
        // a screen pushed above it takes it back.
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in [agentEditor, scheduleEditor] { presenter.sync() }
    }

    override func updateProperties() {
        super.updateProperties()
        applyTitleDisplayMode()
        let dismissed = "Dismissed \(dismissedModals)"
        if dismissedLabel.text != dismissed {
            dismissedLabel.text = dismissed
            dismissedLabel.accessibilityLabel = dismissed
            dismissedLabel.sizeToFit()
        }
        dismissedLabel.textColor = UIColor(palette.fg)
        updateEditors()
    }

    /// Same rule as `HostedScreenController.applyTitleDisplayMode`: a large
    /// title shows nothing where the system puts the bar on a vertical edge,
    /// so the title stays inline there.
    private func applyTitleDisplayMode() {
        let large = !SystemVerticalBar.traitIsActive(traitCollection)
        // The bar's own flag, not the item's mode, is what makes a large title
        // draw.
        if large { navigationController?.navigationBar.prefersLargeTitles = true }
        let mode: UINavigationItem.LargeTitleDisplayMode = large ? .always : .never
        guard navigationItem.largeTitleDisplayMode != mode else { return }
        navigationItem.largeTitleDisplayMode = mode
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(.routes, items: [.quickComments, .editAgent, .editSchedule]),
            ListSection(.lastSave, header: "Last save sent", items: [.lastSave]),
        ]
    }

    override func showsHeader(for section: Section) -> Bool {
        section == .lastSave
    }

    /// A row redraws when the value it reads moved: the last write, or the
    /// count the modal slots changed.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .lastSave: AnyHashable(RouterRoutesSaves.shared.lastSave)
        case .quickComments, .editAgent, .editSchedule: AnyHashable(0)
        }
    }

    private lazy var row = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
        self?.configure(cell, item: item)
    }

    override func prepareRegistrations() {
        _ = row
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
    }

    private func configure(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        ListScreen.background(cell, grouped: true, palette: palette, settingsCard: true)
        switch item {
        case .quickComments:
            action(cell, item: item, title: "Quick Comments", identifier: "routerRoutes.quickComments")
        case .editAgent:
            action(cell, item: item, title: "Edit Agent", identifier: "routerRoutes.editAgent")
        case .editSchedule:
            action(cell, item: item, title: "Edit Schedule", identifier: "routerRoutes.editSchedule")
        case .lastSave:
            ListScreen.staticRow(cell)
            // The value the stub server last received, under the identifier a
            // capture reads: the SwiftUI `Text` it replaces was a static text.
            let value = RouterRoutesSaves.shared.lastSave
            cell.contentConfiguration = ControlViewContent { [palette] in
                let label = UILabel()
                label.text = value
                label.font = .preferredFont(forTextStyle: .body)
                label.textColor = UIColor(palette.fg)
                label.numberOfLines = 0
                label.accessibilityIdentifier = "routerRoutes.lastSave"
                return label
            }
        }
    }

    private func action(_ cell: SidebarListCell, item: Item, title: String, identifier: String) {
        ListScreen.buttonRow(cell, identifier: identifier, label: title) { [weak self] in
            self?.run(item)
        }
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.color = UIColor(palette.blue)
        cell.contentConfiguration = content
    }

    // MARK: - Routes

    private func run(_ item: Item) {
        switch item {
        case .quickComments:
            Router.push(QuickCommentsViewController(root: root), from: self)
        case .editAgent:
            editingAgent = RouterRoutesFixtures.agent
            setNeedsUpdateProperties()
        case .editSchedule:
            editsSchedule = true
            setNeedsUpdateProperties()
        case .lastSave:
            break
        }
    }

    /// The two editor slots, from this screen's state: the SwiftUI list's
    /// `routerModal(item:)` and `routerScreenModal(isPresented:)`.
    private func updateEditors() {
        let connection = root.coordinator.activeConnection
        let editing = editingAgent
        let root = root
        agentEditor.update(
            id: editing.map { AnyHashable($0.id) },
            presentation: .fullScreen.inNavigation(),
            root: root,
            onDismiss: { [weak self] in self?.modalDidClose() },
            clear: { [weak self] in self?.editingAgent = nil },
            screen: {
                .controller({
                    guard let editing else { preconditionFailure("The editor presents only with its Agent") }
                    return AgentNativeEditViewController(
                        agent: editing,
                        apiClient: RouterRoutesFixtures.api,
                        connection: connection,
                        serverName: "mac-studio"
                    ) { _ in }
                })
            }
        )
        let showingSchedule = editsSchedule
        scheduleEditor.update(
            id: showingSchedule ? AnyHashable("schedule") : nil,
            presentation: .fullScreen.inNavigation(),
            root: root,
            onDismiss: { [weak self] in self?.modalDidClose() },
            clear: { [weak self] in self?.editsSchedule = false },
            screen: {
                .controller({
                    ScheduleNativeEditViewController(
                        schedule: RouterRoutesFixtures.schedule,
                        apiClient: RouterRoutesFixtures.api,
                        connection: connection,
                        serverName: "mac-studio"
                    ) { _, _ in }
                })
            }
        )
    }

    private func modalDidClose() {
        dismissedModals += 1
        setNeedsUpdateProperties()
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
#endif
