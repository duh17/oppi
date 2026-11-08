import UIKit

/// What the base needs from a resource's catalog row: the name the page is
/// titled with, the facts the rows it shares with the other page draw from, and
/// what the "Enabled" switch shows and allows. A failed load leaves the switch
/// alone.
protocol ServerResourceDetailSummary {
    var detailName: String { get }
    var detailDescription: String { get }
    var detailLoadError: String? { get }
    var detailWarnings: [String] { get }
    /// The catalog's state, whatever its own type: the rows redraw on it.
    var detailState: AnyHashable { get }
    /// What the Status row says of the state: "Enabled", "Disabled", "Error".
    var detailStatusLabel: String { get }
    /// Pi listed the resource but could not read it (an error or a state the
    /// client does not know): the Status row warns, and the page gives a reason
    /// when the server sent none.
    var isUnreadable: Bool { get }
    var isServerDefaultOn: Bool { get }
    var canToggleServerDefault: Bool { get }
    /// What the Server Default section says instead of its usual footer, when
    /// this resource cannot follow it.
    var serverDefaultNote: String? { get }
}

extension ServerResourceDetailSummary {
    var serverDefaultNote: String? { nil }
}

extension ServerSkillSummary: ServerResourceDetailSummary {
    var detailName: String { name }
    var detailDescription: String { description }
    var detailLoadError: String? { loadError }
    var detailWarnings: [String] { warnings }
    var detailState: AnyHashable { AnyHashable(state) }
    /// A Skill that is on is "Loaded": Pi read it and puts it in new sessions.
    var detailStatusLabel: String {
        switch state {
        case .enabled: "Loaded"
        case .disabled: "Disabled"
        case .error, .unknown: "Error"
        }
    }
    var isUnreadable: Bool { state == .error || state == .unknown }
    var isServerDefaultOn: Bool { state == .enabled }
    var canToggleServerDefault: Bool { state != .error && state != .unknown }
}

extension ServerExtensionSummary: ServerResourceDetailSummary {
    var detailName: String { name }
    var detailDescription: String { description ?? "" }
    var detailLoadError: String? { loadError }
    var detailWarnings: [String] { warnings }
    var detailState: AnyHashable { AnyHashable(state) }
    var detailStatusLabel: String { ServerExtensionListPresentation.stateLabel(for: state) }
    var isUnreadable: Bool { state == .error || state == .unknown }
    var serverDefaultNote: String? {
        plugin?.required == true
            ? String(localized: "Part of the durable session runtime, so it’s always on in durable sessions.")
            : nil
    }
    /// A plugin whose reload failed but kept its previous code is on while that code runs: its
    /// row says `error`, its plugin `enabled`. A row being switched off shows off.
    var isServerDefaultOn: Bool { state == .on || (state == .error && isKeptRunning) }
    /// A kept plugin can still be turned off. A built-in the server needs stays on: its plugin
    /// says it is required.
    var canToggleServerDefault: Bool {
        (state == .on || state == .off || isKeptRunning) && plugin?.required != true
    }

    private var isKeptRunning: Bool { plugin?.kept == true && plugin?.enabled == true }
}

/// A row both pages have, drawn by the base. A page's item type holds one as
/// `.resource(row)`; its rows are scoped by the list's name
/// (`skills.detail.status`, `server.extension.status`).
enum ServerResourceRow: Hashable, Sendable {
    case title, enabled, mutationError, status
    /// Why Pi could not read the resource.
    case loadError(String)
    case warning(String)
}

/// A page's items: its own, and the rows it shares with the other page.
protocol ServerResourceDetailItem: Hashable, Sendable {
    static func resource(_ row: ServerResourceRow) -> Self
    var resourceRow: ServerResourceRow? { get }
}

/// A page's sections: its own, and the three the base builds for both pages.
protocol ServerResourceDetailSection: Hashable, Sendable {
    static var summary: Self { get }
    static var serverDefault: Self { get }
    static var loading: Self { get }
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
    /// Why Pi could not read the resource, when the server gave no reason of its own.
    var unreadableReason: String
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
    Section: ServerResourceDetailSection,
    Item: ServerResourceDetailItem
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

    override func loadConnection() -> ServerConnection? { connection }

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
        let apiClient = try requireAPIClient()
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

    /// Fills the rows both pages share; a page's own rows call `super` for
    /// `.resource` and draw the rest themselves. The cell arrives as a themed card.
    override func configureCard(_ cell: SidebarListCell, item: Item) {
        guard let row = item.resourceRow, let state else { return }
        let palette = palette
        let summary = state.summary
        switch row {
        case .title:
            ListScreen.staticRow(cell, identifier: "\(listName).title")
            let description = summary.detailDescription
            cell.contentConfiguration = ControlViewContent(insets: .init(top: 12, leading: 0, bottom: 12, trailing: 0)) {
                var views = [ControlRowViews.label(
                    summary.detailName, style: .title2, weight: .bold, color: palette.ui.fg
                )]
                if !description.isEmpty {
                    views.append(ControlRowViews.label(description, style: .body, color: palette.ui.comment))
                }
                return ControlRowViews.stack(views, spacing: 6)
            }
        case .enabled:
            serverDefaultRow(cell, state: state)
        case .mutationError:
            ListScreen.staticRow(cell, identifier: "\(listName).mutationError")
            let message = mutationFailureMessage
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    message,
                    systemImage: "exclamationmark.triangle.fill",
                    style: .footnote,
                    color: palette.ui.orange
                )
            }
        case .status:
            ListScreen.staticRow(cell, identifier: "\(listName).status")
            // A resource that is on shows a check, one that is off a minus.
            let icon = summary.isUnreadable
                ? "exclamationmark.triangle.fill"
                : (summary.isServerDefaultOn ? "checkmark.circle" : "minus.circle")
            let label = summary.detailStatusLabel
            cell.contentConfiguration = ControlViewContent {
                let row = ControlRowViews.symbolLabel(label, systemImage: icon, style: .body, color: palette.ui.fg)
                row.accessibilityLabel = label
                return row
            }
        case .loadError(let reason):
            ListScreen.staticRow(cell, identifier: "\(listName).loadError")
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.label(reason, style: .footnote, color: palette.ui.orange)
            }
        case .warning(let warning):
            ListScreen.staticRow(cell)
            cell.contentConfiguration = ControlViewContent {
                ControlRowViews.symbolLabel(
                    warning,
                    systemImage: "exclamationmark.circle",
                    style: .footnote,
                    color: palette.ui.fg
                )
            }
        }
    }

    /// A fact about the resource: its title and value side by side with the
    /// value selectable, and under them, for a long one, its path.
    func resourceFactRow(
        _ cell: SidebarListCell,
        identifier: String,
        title: String,
        value: String,
        path: String? = nil
    ) {
        ListScreen.staticRow(cell, identifier: identifier)
        let palette = palette
        cell.contentConfiguration = ControlViewContent(insets: .init(top: 11, leading: 0, bottom: 11, trailing: 0)) {
            let valueRow = ControlRowViews.valueRow(title, value, palette: palette, style: .body)
            guard let path, !path.isEmpty else { return valueRow }
            // The path under the label: long, so it wraps the row's width.
            let pathText = ControlRowViews.selectableText(path, style: .footnote, color: palette.ui.comment)
            pathText.accessibilityLabel = String(localized: "Path")
            pathText.accessibilityValue = path
            return ControlRowViews.stack([valueRow, pathText], spacing: 4)
        }
    }

    /// What a shared row draws from, besides its own identity: a replaced switch
    /// would drop a save in flight. A page's own rows add their own.
    override func inputs(of item: Item) -> AnyHashable {
        guard let state else { return AnyHashable(0) }
        guard let row = item.resourceRow else { return super.inputs(of: item) }
        let summary = state.summary
        return switch row {
        case .title:
            AnyHashable([AnyHashable(summary.detailName), AnyHashable(summary.detailDescription)])
        case .enabled:
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
        case .loadError(let reason):
            AnyHashable(reason)
        // A warning holds nothing a reconfigure would disturb, so the kit's
        // default draws it again.
        case .warning:
            super.inputs(of: item)
        }
    }

    // MARK: - Sections

    /// The page's title and description.
    func summarySection() -> ListSection<Section, Item> {
        ListSection(.summary, items: [.resource(.title)])
    }

    /// The Server Default section: the switch and, after a failed save, why.
    func serverDefaultSection() -> ListSection<Section, Item> {
        ListSection(
            .serverDefault,
            header: "Server Default",
            footer: state?.summary.serverDefaultNote
                ?? "New sessions use this setting. Reload an active session to apply it now.",
            items: state?.mutationError == nil ? [.resource(.enabled)] : [.resource(.enabled), .resource(.mutationError)]
        )
    }

    /// What Pi makes of the resource — its state, why it could not read it, the
    /// page's own findings (`extra`), and each warning once (a diffable list traps
    /// on a repeated row). These are facts about the resource, not a failed request.
    func statusItems(extra: [Item] = []) -> [Item] {
        guard let summary = state?.summary else { return [] }
        var items: [Item] = [.resource(.status)]
        if let reason = summary.detailLoadError ?? (summary.isUnreadable ? page.unreadableReason : nil) {
            items.append(.resource(.loadError(reason)))
        }
        return items + extra + Self.unique(summary.detailWarnings).map { .resource(.warning($0)) }
    }

    /// The contents' place: the kit's compact loading row until the detail
    /// arrives, and its one failed row with Retry when the request failed.
    func loadingSection() -> ListSection<Section, Item>? {
        guard let state,
              let row = stateRow(hasContent: state.detail != nil, isLoading: isLoading, failure: loadFailure)
        else { return nil }
        return ListSection(.loading, items: [], state: row)
    }

    /// The contents are what the detail request fetches: until they are here the
    /// list shows the compact loading row in the contents' place.
    override func hasContent() -> Bool { state?.detail != nil }

    /// The group headings are the ones the page wrote, so only the sections
    /// with one show it.
    override func showsHeader(for section: Section) -> Bool {
        section != .summary && section != .loading
    }

    /// The repeated words a row of either page shows.
    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// "Couldn’t enable release on mac-studio. <reason>": the row that says a
    /// save failed.
    private var mutationFailureMessage: String {
        guard let state else { return "" }
        return "Couldn’t \(mutationVerb ?? "update") \(state.summary.detailName) on \(state.serverName). \(state.mutationError ?? "")"
    }

    /// The server default's row: its switch, a spinner while a save is in
    /// flight, and the save itself.
    private func serverDefaultRow(_ cell: SidebarListCell, state: ServerResourceDetailState<Summary, Detail>) {
        ListScreen.staticRow(cell)
        var content = UIListContentConfiguration.cell()
        content.text = "Enabled"
        content.textProperties.color = palette.ui.fg
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = state.summary.isServerDefaultOn
        toggle.isEnabled = !state.isPending && state.mutationsAllowed && state.summary.canToggleServerDefault
        toggle.accessibilityIdentifier = "\(listName).enabled"
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
            spinner.accessibilityIdentifier = "\(listName).saving"
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
