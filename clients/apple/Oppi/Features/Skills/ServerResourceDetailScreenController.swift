import UIKit

/// What the base needs from a resource's catalog row: the name the page is
/// titled with, the facts the rows it shares with the other page draw from, and
/// what the "Enabled" switch shows and allows. A failed load leaves the switch
/// alone.
protocol ServerResourceDetailSummary {
    var detailName: String { get }
    var detailDescription: String { get }
    var detailLoadError: String? { get }
    /// The catalog's state, whatever its own type: the rows redraw on it.
    var detailState: AnyHashable { get }
    var isServerDefaultOn: Bool { get }
    var canToggleServerDefault: Bool { get }
}

extension ServerSkillSummary: ServerResourceDetailSummary {
    var detailName: String { name }
    var detailDescription: String { description }
    var detailLoadError: String? { loadError }
    var detailState: AnyHashable { AnyHashable(state) }
    var isServerDefaultOn: Bool { state == .enabled }
    var canToggleServerDefault: Bool { state != .error && state != .unknown }
}

extension ServerExtensionSummary: ServerResourceDetailSummary {
    var detailName: String { name }
    var detailDescription: String { description ?? "" }
    var detailLoadError: String? { loadError }
    var detailState: AnyHashable { AnyHashable(state) }
    var isServerDefaultOn: Bool { state == .on }
    /// A built-in the server needs stays on: its plugin says it is required.
    var canToggleServerDefault: Bool { state != .error && state != .unknown && plugin?.required != true }
}

/// A detail response carries its own newer copy of the catalog's row.
protocol ServerResourceDetailAnswer {
    associatedtype Summary
    var summary: Summary { get }
}

extension ServerSkillDetail: ServerResourceDetailAnswer {}
extension ServerExtensionDetail: ServerResourceDetailAnswer {}

/// What a detail page reads from the route, its server's store, and the detail
/// load, taken once in `updateProperties()` so observation tracks it and a
/// reconfigured row sees one consistent copy.
struct ServerResourceDetailState<Summary, Detail> {
    var summary: Summary
    var detail: Detail?
    var isLoading: Bool
    var isPending: Bool
    var mutationError: String?
    var mutationsAllowed: Bool
    var serverName: String
}

/// One resource-detail page's own half: the copy of its failure, where its
/// resource is kept, and how it is asked for and saved.
struct ServerResourceDetailPage<Detail: ServerResourceDetailAnswer> {
    /// The title before the catalog row arrives.
    var title: String
    var listIdentifier: String
    var loadingCaption: String
    /// The title of a failed load: "Couldn't Load Skill", over the request's reason.
    var failureTitle: String
    /// Whether the page says "Connecting…" until it has its server; a page that
    /// shows its catalog row first says what it is loading instead.
    var showsConnecting = false
    /// Where the resource is kept, for the switch's pending and failure state.
    var catalog: ServerResourceCatalogKind
    /// The catalog's row for the page's resource: what the page shows until a
    /// detail response answers (and again after a save, until the reload does).
    var catalogRow: @MainActor (ServerResourceStore) -> Detail.Summary?
    var mutationKey: ServerResourceMutationKey
    /// The detail request. The store comes in rather than being read off the
    /// page, so the closure the loader holds does not hold the page.
    var fetch: @MainActor (APIClient, ServerResourceStore) async throws -> Detail
    /// Saves the server default through the store.
    var sendEnabled: @MainActor (Bool, APIClient, ServerResourceStore) async -> Void
}

/// One Skill or one extension on one server (route `.serverResourceDetail`):
/// what the two pages do the same. It owns the route's server switch, the
/// detail load, the server default's save, the switch row, and the whole-screen
/// state; a page says only what its own rows are.
///
/// The route makes the resource's server the active one on every appearance
/// ("Connecting…" until it is ready). The catalog row shows at once; the detail
/// request adds the rest, and a newer detail summary wins over a stale catalog
/// row until a mutation settles.
@MainActor
class ServerResourceDetailScreenController<
    Summary: ServerResourceDetailSummary,
    Detail: ServerResourceDetailAnswer,
    Section: Hashable & Sendable,
    Item: Hashable & Sendable
>: ListScreenController<Section, Item> where Detail.Summary == Summary {
    let target: ServerResourceDetailNavTarget
    let root: AppRootEnvironment
    /// The page's own details and where its answers come from.
    private let page: ServerResourceDetailPage<Detail>
    /// The rows' state: nil until the catalog has the resource.
    private(set) var state: ServerResourceDetailState<Summary, Detail>?
    /// The verb of the save in flight, for the failure's wording.
    private(set) var mutationVerb: String?
    /// The resource's server once it is ready.
    private(set) var connection: ServerConnection? {
        didSet { setNeedsUpdateProperties() }
    }
    /// The detail the last request returned, and whether a request that
    /// succeeded makes it newer than the catalog row that opened the page. The
    /// detail itself stays as long as the page does (a failed reload keeps what
    /// it found); a successful catalog mutation is authoritative until a later
    /// detail request succeeds.
    private(set) var detail: Detail?
    private(set) var usesDetailSummary = false

    /// The route makes the resource's server the active one on every appearance.
    let switchesServer: Bool

    /// `connection`: the resource's server when the caller already has it ready;
    /// nil makes it the active server first.
    init(
        target: ServerResourceDetailNavTarget,
        root: AppRootEnvironment,
        connection: ServerConnection?,
        page: ServerResourceDetailPage<Detail>
    ) {
        self.target = target
        self.root = root
        self.connection = connection
        self.page = page
        switchesServer = connection == nil
        super.init(title: page.title, listIdentifier: page.listIdentifier, headers: true, footers: true, dismissesKeyboardOnDrag: true)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    var serverName: String {
        root.coordinator.serverStore.server(for: target.serverId)?.name ?? "this server"
    }

    /// The resource as the page's rows show it: the catalog's row, which a
    /// successful detail response (newer than the row that opened the page, so
    /// Retry clears a stale row error) replaces until a mutation settles.
    private func summary(in store: ServerResourceStore) -> Summary? {
        (usesDetailSummary ? detail?.summary : nil) ?? page.catalogRow(store)
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    // MARK: - Load

    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The route this page serves: another resource or another server is
    /// another page's rows.
    override func loadSubject() -> AnyHashable? { AnyHashable(target) }

    override func subjectDidChange() {
        detail = nil
        usesDetailSummary = false
    }

    /// Makes the resource's server the active one (when the route does), then
    /// asks it for the detail: the base runs it on every appearance and after a
    /// Retry.
    override func load() async throws {
        // A Retry starts from no failure: the rows show the load, not the last
        // one's reason.
        clearLoadFailure()
        if switchesServer {
            guard await root.coordinator.switchToServerReady(target.serverId), !Task.isCancelled else { return }
            connection = root.coordinator.connection(for: target.serverId)
        }
        guard let connection else { return }
        guard let apiClient = connection.apiClient else {
            throw ServerResourceDetailLoadError.notConnected(serverName)
        }
        let fetched = try await page.fetch(apiClient, connection.serverResourceStore)
        guard !Task.isCancelled else { return }
        detail = fetched
        usesDetailSummary = true
    }

    /// A load replaces the rows; they should not slide.
    override var animatesUpdates: Bool { false }

    override func updateProperties() {
        let store = connection?.serverResourceStore
        let summary = store.flatMap { summary(in: $0) }
        title = summary?.detailName ?? page.title
        if let summary, let store {
            state = ServerResourceDetailState(
                summary: summary,
                // What the request found, whatever the summary precedence says:
                // after a save the catalog's summary wins until the reload
                // lands, and the contents it found stay on screen meanwhile.
                detail: detail,
                isLoading: isLoading,
                isPending: store.isMutationPending(page.mutationKey, serverId: target.serverId),
                mutationError: store.mutationError(for: page.mutationKey, serverId: target.serverId),
                mutationsAllowed: store.mutationsAllowed(for: page.catalog, serverId: target.serverId),
                serverName: serverName
            )
        } else {
            state = nil
        }
        super.updateProperties()
    }

    /// Without the resource there is nothing to list, so the state has the
    /// whole screen; with it, the rows are the screen.
    override func wholeScreenState() -> LoadState? {
        guard state == nil else { return nil }
        guard connection != nil else {
            return page.showsConnecting ? .connecting : .loading(page.loadingCaption)
        }
        // Unavailable only after a load failed: a load that never finished
        // (cancelled as the screen left) is still loading when it returns.
        guard !isLoading, let loadFailure else {
            return .loading(page.loadingCaption)
        }
        return .failed(
            title: loadFailure.title,
            message: loadFailure.reason,
            retry: RetryAction { [weak self] in self?.setNeedsLoad() }
        )
    }

    /// The title of this page's failure row: "Couldn't Load Skill".
    override func failureTitle() -> String? { page.failureTitle }

    // MARK: - Rows

    /// The page's rows are the kit's theme cards, filled by
    /// `configureCard(_:item:)`; the handler also dims a pressed button row.
    override var rowStyle: ListRowStyle { .card }

    /// Fills one of the page's rows. The cell arrives as a themed card.
    override func configureCard(_ cell: SidebarListCell, item: Item) {}

    /// The rows a resource-detail page has, whose inputs are the same on both:
    /// the resource itself, a save in flight, and the load. A page's own rows
    /// add their own.
    enum ResourceRow {
        case title, serverDefault, mutationError, status
    }

    /// What one of the shared rows draws from.
    func resourceRowInputs(_ row: ResourceRow) -> AnyHashable {
        guard let state else { return AnyHashable(0) }
        let summary = state.summary
        return switch row {
        case .title:
            AnyHashable([AnyHashable(summary.detailName), AnyHashable(summary.detailDescription)])
        case .serverDefault:
            // A refused change sets only the mutation error; redraw so the switch snaps back.
            AnyHashable([
                AnyHashable(summary.detailName), summary.detailState, AnyHashable(state.isPending),
                AnyHashable(state.mutationsAllowed), AnyHashable(state.serverName),
                AnyHashable(state.mutationError),
            ])
        case .mutationError:
            AnyHashable([
                AnyHashable(summary.detailName), AnyHashable(state.serverName),
                AnyHashable(state.mutationError), AnyHashable(mutationVerb),
            ])
        case .status:
            AnyHashable([summary.detailState])
        }
    }

    /// The repeated words a row of either page shows.
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// "Couldn’t enable release on mac-studio. <reason>": the row that says a
    /// save failed.
    var mutationFailureMessage: String {
        guard let state else { return "" }
        return "Couldn’t \(mutationVerb ?? "update") \(state.summary.detailName) on \(state.serverName). \(state.mutationError ?? "")"
    }

    /// The server default's row: its switch, a spinner while a save is in
    /// flight, and the save itself.
    func serverDefaultRow(_ cell: SidebarListCell, identifier: String, savingIdentifier: String) {
        guard let state else { return }
        ListScreen.staticRow(cell)
        var content = UIListContentConfiguration.cell()
        content.text = "Enabled"
        content.textProperties.color = palette.ui.fg
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = state.summary.isServerDefaultOn
        toggle.isEnabled = !state.isPending && state.mutationsAllowed && state.summary.canToggleServerDefault
        toggle.accessibilityIdentifier = identifier
        toggle.accessibilityLabel = "Enable \(state.summary.detailName) on \(state.serverName)"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            // Offline: nothing will redraw the row, so put the switch back now.
            guard self.connection?.apiClient != nil else {
                toggle.setOn(!toggle.isOn, animated: true)
                return
            }
            self.setEnabled(toggle.isOn)
        }, for: .valueChanged)
        var accessories: [UICellAccessory] = []
        if state.isPending {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            spinner.accessibilityLabel = "Saving"
            spinner.accessibilityIdentifier = savingIdentifier
            accessories.append(.customView(configuration: .init(customView: spinner, placement: .trailing())))
        }
        accessories.append(.customView(configuration: .init(customView: toggle, placement: .trailing())))
        cell.accessories = accessories
    }

    // MARK: - Data

    private func setEnabled(_ enabled: Bool) {
        guard let connection, let api = connection.apiClient else { return }
        mutationVerb = enabled ? "enable" : "disable"
        let store = connection.serverResourceStore
        let target = target
        let send = page.sendEnabled
        Task { [weak self] in
            await send(enabled, api, store)
            guard let self, store.mutationError(for: page.mutationKey, serverId: target.serverId) == nil else {
                return
            }
            // The catalog's own answer is authoritative until the detail request
            // that follows it succeeds.
            usesDetailSummary = false
            setNeedsLoad()
        }
    }
}

enum ServerResourceDetailLoadError: LocalizedError {
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let serverName):
            "Not connected to \(serverName)."
        }
    }
}
