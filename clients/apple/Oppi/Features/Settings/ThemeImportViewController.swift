import UIKit

/// Custom Themes: the server's themes. Tap one to import and apply it, edit
/// one with an Oppi control session (swipe or touch and hold), or describe a
/// new one in the guided composer, as Agents and Schedules do. An import is a
/// copy saved on this device.
///
/// A `ListScreenController`: the base runs the load (`themes.list`) on every
/// appearance, on pull to refresh, and for its Retry, and draws the page's
/// one loading, empty, or failed row in its state section.
@MainActor
final class ThemeImportViewController: ListScreenController<ThemeImportViewController.Section, ThemeImportViewController.Item> {
    enum Section: Hashable, Sendable { case state, themes }
    enum Item: Hashable, Sendable { case theme(String) }

    private let root: AppRootEnvironment
    private let composer: GuidedControlComposerController
    private let revisionSheet = RouterModalPresenter()

    private var remoteThemes: [RemoteThemeSummary] = [] {
        didSet { setNeedsUpdateProperties() }
    }
    private var importingName: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private var revisingTheme: RemoteThemeSummary? {
        didSet { setNeedsUpdateProperties() }
    }

    init(root: AppRootEnvironment) {
        self.root = root
        composer = GuidedControlComposerController(
            configuration: GuidedControlComposerConfiguration(
                domain: .themes,
                intent: .create,
                placeholder: "Describe a new theme…"
            ),
            root: root
        )
        super.init(
            title: "Custom Themes", listIdentifier: "themes.list", scope: .device, footers: true,
            dismissesKeyboardOnDrag: true
        )
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    private var palette: ThemePalette { ThemeRuntimeState.currentPalette() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        composer.install(in: self)
        revisionSheet.anchor = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        revisionSheet.sync()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        composer.insetContent(of: collectionView)
    }

    override func updateProperties() {
        super.updateProperties()
        // With themes listed the list has no room for the load's failure: the
        // composer says it, under the list.
        composer.setScreenError(remoteThemes.isEmpty ? nil : loadFailure.map { $0.reason ?? $0.title }, identifier: "themes.error")
        let revising = revisingTheme
        revisionSheet.update(
            id: revising.map { AnyHashable($0.id) },
            presentation: .sheet.inNavigation(),
            root: root,
            clear: { [weak self] in self?.revisingTheme = nil },
            screen: { [root] in
                .controller {
                    GuidedControlSessionViewController(
                        configuration: GuidedControlComposerConfiguration(
                            domain: .themes,
                            intent: .revise,
                            targetId: revising?.filename,
                            targetName: revising?.name,
                            targetPath: revising?.path,
                            allowsEmptyRequest: true,
                            placeholder: "Describe how this theme should change…"
                        ),
                        root: root
                    )
                }
            }
        )
    }

    // MARK: - Load

    /// The server's themes, each time the page shows: an import or an edit on
    /// another device changes the list.
    override var loadPolicy: LoadPolicy { .eachAppearance }

    /// The active server's connection: the base reloads the page by itself when it
    /// installs an API client again after a rebuild.
    override func loadConnection() -> ServerConnection? { root.coordinator.activeConnection }

    override func load() async throws {
        let api = try requireAPIClient()
        let themes = try await api.listThemes()
        guard !Task.isCancelled else { return }
        remoteThemes = themes
    }

    // MARK: - List

    override func sections() -> [ListSection<Section, Item>] {
        guard !remoteThemes.isEmpty else { return [ListSection(.state, items: [])] }
        return [ListSection(
            .themes,
            footer: "Tap a theme to import and apply it. Swipe or touch and hold to edit it with Oppi.",
            items: remoteThemes.map { .theme($0.filename) }
        )]
    }

    /// The list's own state: its one row is the base's, in `.state`.
    override func stateSection() -> Section? { .state }

    override func hasContent() -> Bool { !remoteThemes.isEmpty }

    override func loadingCaption() -> String? { String(localized: "Fetching themes…") }

    override func failureTitle() -> String? { String(localized: "Couldn't Load Themes") }

    override func emptyState() -> LoadState? {
        .empty(
            title: String(localized: "No custom themes yet. Describe a theme below and Oppi writes it to your server."),
            systemImage: "paintpalette"
        )
    }

    override var rowStyle: ListRowStyle { .card }

    override func inputs(of item: Item) -> AnyHashable {
        guard case .theme(let filename) = item,
              let summary = remoteThemes.first(where: { $0.filename == filename }) else { return AnyHashable(0) }
        return AnyHashable([
            AnyHashable(summary.name),
            AnyHashable(summary.colorScheme),
            AnyHashable(importingName == filename),
            AnyHashable(CustomThemeStore.load(name: summary.name) != nil),
        ])
    }

    override func configureCard(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        guard case .theme(let filename) = item,
              let summary = remoteThemes.first(where: { $0.filename == filename }) else { return }
        let isImported = CustomThemeStore.load(name: summary.name) != nil
        ListScreen.buttonRow(
            cell,
            identifier: "themes.row.\(summary.filename)",
            label: summary.name,
            value: importingName == filename ? "Importing" : (isImported ? "Imported" : summary.colorScheme),
            contextMenu: contextMenu(summary, isImported: isImported)
        ) { [weak self] in
            self?.startImport(summary)
        }
        var content = content(.subtitle)
        content.text = summary.name
        content.secondaryText = summary.colorScheme
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.textToSecondaryTextVerticalPadding = 2
        cell.contentConfiguration = content
        if importingName == filename {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        } else if isImported {
            let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            check.tintColor = palette.ui.green
            cell.accessories = [.customView(configuration: .init(customView: check, placement: .trailing()))]
        }
    }

    override func trailingSwipeActions(for item: Item) -> UISwipeActionsConfiguration? {
        guard case .theme(let filename) = item,
              let summary = remoteThemes.first(where: { $0.filename == filename }) else { return nil }
        var actions: [UIContextualAction] = []
        if CustomThemeStore.load(name: summary.name) != nil {
            let delete = UIContextualAction(style: .destructive, title: "Delete from Device") { [weak self] _, _, done in
                self?.confirmRemoval(summary)
                done(true)
            }
            delete.image = UIImage(systemName: "trash")
            actions.append(delete)
        }
        let edit = UIContextualAction(style: .normal, title: "Edit with Session") { [weak self] _, _, done in
            self?.revisingTheme = summary
            done(true)
        }
        edit.image = UIImage(systemName: "text.bubble")
        edit.backgroundColor = palette.ui.blue
        actions.append(edit)
        let config = UISwipeActionsConfiguration(actions: actions)
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    /// Touch and hold: Edit with Session, and Delete from Device once imported.
    private func contextMenu(_ summary: RemoteThemeSummary, isImported: Bool) -> UIMenu {
        let edit = UIAction(title: "Edit with Session", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
            self?.revisingTheme = summary
        }
        edit.accessibilityIdentifier = "themes.row.\(summary.filename).edit"
        var children: [UIMenuElement] = [edit]
        if isImported {
            children.append(UIAction(
                title: "Delete from Device",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.confirmRemoval(summary) })
        }
        return UIMenu(children: children)
    }

    // MARK: - Actions

    private func confirmRemoval(_ summary: RemoteThemeSummary) {
        Confirmation(
            title: "Delete \(summary.name) from this device?",
            message: "The imported copy is removed. You can import it again from the server.",
            actionTitle: "Delete Theme"
        ).present(from: self, anchor: nil) { [weak self] in
            self?.root.themeStore.removeImportedTheme(named: summary.name)
            self?.setNeedsUpdateProperties()
        }
    }

    private func startImport(_ summary: RemoteThemeSummary) {
        Task { await importTheme(summary) }
    }

    private func importTheme(_ summary: RemoteThemeSummary) async {
        guard let api = root.coordinator.activeConnection.apiClient else { return }
        importingName = summary.filename
        defer { importingName = nil }
        do {
            let theme = try await api.getTheme(name: summary.filename)
            guard theme.toPalette() != nil else { return }
            CustomThemeStore.save(theme)
            root.themeStore.selectedThemeID = .custom(theme.name)
            AppHaptics.success()
        } catch {}
    }
}
