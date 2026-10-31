#if DEBUG
import UIKit

/// The UIKit router with real screens and fixture services, no network
/// (`SCREENSHOT_SCREEN=router-routes`): a `RouterNavigationController` whose
/// root is the route list. Quick Comments is pushed
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
/// and the two editors in their own `RouterModalPresenter` slots. The two rows
/// under "Last save sent" show what the stub server received and how many
/// modals closed, with the identifiers `RouterRoutesUITests` reads.
final class RouterRoutesMenuViewController: ListScreenController<RouterRoutesMenuViewController.Section, RouterRoutesMenuViewController.Item> {
    enum Section: Hashable, Sendable { case routes, lastSave }
    enum Item: Hashable, Sendable { case quickComments, editAgent, editSchedule, lastSave, dismissedModals }

    private let root: AppRootEnvironment
    private let agentEditor = RouterModalPresenter()
    private let scheduleEditor = RouterModalPresenter()
    private var editingAgent: StoredAgentDefinition?
    private var editsSchedule = false
    /// What the modals closed: the SwiftUI `routerModal` slots bumped it on
    /// every dismissal, swipe-down included.
    private var dismissedModals = 0

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(title: "Router Routes", listIdentifier: "routerRoutes.list", headers: true, largeTitle: true)
        traitOverrides.appRootEnvironment = root
        for presenter in [agentEditor, scheduleEditor] { presenter.anchor = self }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for presenter in [agentEditor, scheduleEditor] { presenter.sync() }
    }

    override func updateProperties() {
        super.updateProperties()
        updateEditors()
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        [
            ListSection(.routes, items: [.quickComments, .editAgent, .editSchedule]),
            ListSection(.lastSave, header: "Last save sent", items: [.lastSave, .dismissedModals]),
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
        case .dismissedModals: AnyHashable(dismissedModals)
        case .quickComments, .editAgent, .editSchedule: AnyHashable(0)
        }
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, item in
        self?.configure(cell, item: item)
    }

    override func prepareRegistrations() {
        _ = actionRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .quickComments, .editAgent, .editSchedule:
            collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .lastSave, .dismissedModals:
            super.dequeue(item, at: indexPath)
        }
    }

    /// The route rows act; the two under "Last save sent" only show a value.
    private func configure(_ cell: SettingsActionRowCell, item: Item) {
        switch item {
        case .quickComments:
            cell.configure(title: "Quick Comments", identifier: "routerRoutes.quickComments") { [weak self] in
                self?.run(item)
            }
        case .editAgent:
            cell.configure(title: "Edit Agent", identifier: "routerRoutes.editAgent") { [weak self] in
                self?.run(item)
            }
        case .editSchedule:
            cell.configure(title: "Edit Schedule", identifier: "routerRoutes.editSchedule") { [weak self] in
                self?.run(item)
            }
        case .lastSave, .dismissedModals:
            break
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .lastSave:
            statusRow(cell, text: RouterRoutesSaves.shared.lastSave, identifier: "routerRoutes.lastSave")
        case .dismissedModals:
            statusRow(cell, text: "Dismissed \(dismissedModals)", identifier: "routerRoutes.dismissedModals")
        case .quickComments, .editAgent, .editSchedule:
            break
        }
    }

    /// A value the harness saw, under the identifier a capture reads: the
    /// SwiftUI `Text` rows it replaces were static texts.
    private func statusRow(_ cell: UICollectionViewListCell, text: String, identifier: String) {
        let palette = palette
        cell.contentConfiguration = ControlViewContent {
            let label = UILabel()
            label.text = text
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = UIColor(palette.fg)
            label.numberOfLines = 0
            label.accessibilityIdentifier = identifier
            return label
        }
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
        case .lastSave, .dismissedModals:
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
    /// Two saved Agents with the artwork a row and a menu draw: an emoji and a
    /// symbol, so the Schedule editor's Agent row and its choices show both.
    static let savedAgents = [
        AgentDefinitionSummary(
            id: "agent-digest",
            name: "Digest Writer",
            icon: .emoji("\u{1F98A}"),
            status: .active,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        ),
        AgentDefinitionSummary(
            id: "agent-audit",
            name: "Release Auditor",
            icon: .symbol("wand.and.stars"),
            status: .active,
            version: 2,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        ),
    ]

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
            // A model, so the editor's Model row draws its provider's mark.
            sessionDefaults: AgentSessionDefaults(model: "anthropic/claude-sonnet-5", tools: ["read"])
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
            model: "anthropic/claude-sonnet-5",
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
    private struct AgentsBody: Encodable { let agents: [AgentDefinitionSummary] }

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
            response = try? JSONEncoder().encode(AgentsBody(agents: RouterRoutesFixtures.savedAgents))
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
