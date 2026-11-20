import UIKit

/// Edit Sidebar: the shared Customize screen (`BarCustomizeViewController`)
/// over this device's sidebar layout (`WorkspaceSidebarPlaces.layoutPreference`).
/// One row per place the window's server offers, with a switch that shows or
/// hides it in this device's sidebar and a handle that drags it into place;
/// All Sessions is always first and not listed. The sidebar redraws as each
/// switch flips or row drops.
///
/// A switch never turns a feature off: a feature off on the server has no
/// place here at all, and the Features row under the list opens that server's
/// Features page (`ServerFeaturesViewController`), which turns features on or
/// off for every device. The row shows while the server has feature switches,
/// as Server Settings' does.
///
/// The sidebar's Edit opens it as a popover beside the sidebar on a wide
/// window and a sheet over the drawer on a compact one (`present(from:source:)`).
final class WorkspaceSidebarEditViewController: BarCustomizeViewController<
    WorkspaceSidebarPlaceID, WorkspaceSidebarEditViewController.Extra
> {
    enum Extra: Hashable, Sendable {
        case features
    }

    private let root: AppRootEnvironment

    init(root: AppRootEnvironment, defaults: UserDefaults = .standard) {
        self.root = root
        let preference = WorkspaceSidebarPlaces.layoutPreference
        // Read on every pass: a feature turned on or off from the Features
        // row adds or removes its place while the screen is up.
        let offered = { Self.offeredPlaces(root: root) }
        let ids = { WorkspaceSidebarPlaces.layoutIDs(offered()) }
        super.init(surface: BarSurface(
            title: String(localized: "Edit Sidebar"),
            footer: String(localized: "Places turned off leave this device's sidebar and still open from links. All Sessions is always first."),
            // Under the Edit button's own id (`workspace.sidebar.edit`).
            identifierPrefix: "workspace.sidebar.edit",
            layout: { preference.layout(in: defaults).placingUnseen(ids()) },
            defaultLayout: { WorkspaceSidebarLayout.defaultValue.placingUnseen(ids()) },
            save: { preference.save($0, in: defaults) },
            reset: { preference.reset(in: defaults) },
            row: { id in Self.row(offered().first { WorkspaceSidebarPlaceID($0.place) == id }) },
            isListed: { ids().contains($0) }
        ))
        // A popover's size; a sheet takes its detents.
        preferredContentSize = CGSize(width: 375, height: 620)
    }

    /// Opens Edit Sidebar from the sidebar's Edit button: a popover to the
    /// button's right, so the sidebar stays in view, and a sheet at half
    /// height over the drawer when the window is compact.
    func present(from presenter: UIViewController, source: UIView) {
        presentWithDone(
            from: presenter,
            presentation: .popoverOrSheet(detents: [.medium(), .large()]).arrowDirections(.left).inNavigation(),
            sourceView: source
        )
    }

    /// Done, which `present(from:source:)` installs, held while a popover
    /// leaves it out.
    private var doneItem: UIBarButtonItem?

    /// Done only in the sheet: a popover closes with a tap outside it, and its
    /// bar clips the glass Done button at the popover's edge. Read on each
    /// layout, since a window resized to compact turns the popover into a
    /// sheet; a popover that adapted has no arrow.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if doneItem == nil { doneItem = navigationItem.rightBarButtonItem }
        let isPopover = (navigationController?.popoverPresentationController?.arrowDirection ?? .unknown) != .unknown
        let item = isPopover ? nil : doneItem
        if navigationItem.rightBarButtonItem !== item { navigationItem.rightBarButtonItem = item }
    }

    private static func offeredPlaces(root: AppRootEnvironment) -> [WorkspaceSidebarPlace] {
        let connection = root.windowConnection
        return WorkspaceSidebarPlaces.offered(
            plugins: connection?.serverCapabilities?.pluginSidebar ?? [],
            pinsAvailable: connection?.pinsAvailable == true
        ) { connection?.offers($0) ?? true }
    }

    private static func row(_ place: WorkspaceSidebarPlace?) -> BarSurface<WorkspaceSidebarPlaceID>.Row {
        guard let place else { return .init(title: "") }
        let symbol = UIImage.SymbolConfiguration(textStyle: .body)
        let image = place.logo.flatMap {
            SymbolSizedLogo.image(named: $0, reference: place.systemImage, configuration: symbol, fallbackSide: 17)
        } ?? UIImage(systemName: place.systemImage, withConfiguration: symbol)
        return .init(title: place.title, image: image)
    }

    // MARK: - Features

    /// The window's server, while it has feature switches to open.
    private var featuresServer: PairedServer? {
        guard let id = root.windowServerId, root.coordinator.serverHasFeatureSwitches(id) else { return nil }
        return root.coordinator.serverStore.server(for: id)
    }

    /// Reads the server's switches each time the screen shows, for the
    /// Features row's summary ("All On", "8 of 10 On").
    override var loadPolicy: LoadPolicy { .eachAppearance }

    override var offersPullToRefresh: Bool { false }

    override func load() async throws {
        guard let server = featuresServer else { return }
        // One read brings every switch: they share the route's document.
        _ = await root.coordinator.settings(for: server.id).reload(SettingsCatalog.feature(.agents))
    }

    override func extraSections() -> [BarCustomizeExtraSection<Extra>] {
        guard let server = featuresServer else { return [] }
        return [BarCustomizeExtraSection(
            footer: String(localized: "Turns features on or off for every device that uses \(server.name). A feature that's off has no place above."),
            rows: [.features]
        )]
    }

    private var featuresSummary: String? {
        featuresServer.flatMap { ServerFeaturesViewController.summary(root.coordinator.settings(for: $0.id)) }
    }

    override func inputs(ofExtra extra: Extra) -> AnyHashable {
        AnyHashable([featuresServer?.name, featuresSummary])
    }

    private lazy var featuresRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Extra> { [weak self] cell, _, _ in
        guard let self, let server = featuresServer else { return }
        cell.configure(
            title: String(localized: "Features on \(server.name)"),
            image: .symbol("switch.2"),
            value: featuresSummary,
            identifier: "workspace.sidebar.edit.features"
        ) { [weak self] in self?.openFeatures() }
    }

    override func prepareRegistrations() {
        super.prepareRegistrations()
        _ = featuresRow
    }

    override func dequeue(extra: Extra, at indexPath: IndexPath) -> UICollectionViewCell? {
        collectionView.dequeueConfiguredReusableCell(using: featuresRow, for: indexPath, item: extra)
    }

    private func openFeatures() {
        guard let server = featuresServer else { return }
        Router.push(ServerFeaturesViewController(server: server, settings: root.coordinator.settings(for: server.id)), from: self)
    }
}
