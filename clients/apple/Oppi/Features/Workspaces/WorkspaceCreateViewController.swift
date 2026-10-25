import UIKit

/// New Workspace: pick a project on a server (or enter a folder path), then
/// confirm name, folder, icon, and options. "Create with Oppi" opens the guided
/// composer for the same server instead.
///
/// Presented by the router as a sheet in its own navigation controller
/// (`.sheet.inNavigation()`). The form's state is `WorkspaceCreateModel`.
@MainActor
final class WorkspaceCreateViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable {
        case intro, oppi, sandbox, entry, scan, projects
        case name, folder, appearance, skills, options, advanced, error, submit
    }

    private enum Item: Hashable {
        case intro, createWithOppi, sandbox, manual, blank
        case scanning, scanError, noProjects, project(String)
        case name, folderFixed, folderField, folderCheck, suggestionsLabel, suggestion(String)
        case icon, noSkills, skill(String)
        case gitStatus, showAdvanced, description, error, submit
    }

    let model: WorkspaceCreateModel
    private let root: AppRootEnvironment
    private let onCreate: ((Workspace) -> Void)?
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var changedRows = ChangedRows<Item>()
    private var appliedStep: WorkspaceCreateStep?
    private let iconPicker = RouterModalPresenter()
    private var showsIconPicker = false {
        didSet { setNeedsUpdateProperties() }
    }
    private weak var guidedSheet: GuidedControlSessionViewController?
    private var createTask: Task<Void, Never>?

    private lazy var cancelItem: UIBarButtonItem = {
        let close = UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        }
        guard model.isGuidedFirstWorkspace else {
            return UIBarButtonItem(systemItem: .cancel, primaryAction: close)
        }
        let item = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: close)
        item.accessibilityLabel = "Not Now"
        return item
    }()

    private lazy var createItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.create() })
        item.accessibilityLabel = "Create"
        item.accessibilityIdentifier = "workspace.create.submit"
        return item
    }()

    private lazy var creatingItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.accessibilityLabel = "Creating"
        return UIBarButtonItem(customView: spinner)
    }()

    init(
        root: AppRootEnvironment,
        server: PairedServer,
        presentation: WorkspaceCreatePresentation = .standard,
        prefillName: String? = nil,
        prefillPath: String? = nil,
        onCreate: ((Workspace) -> Void)? = nil
    ) {
        self.root = root
        self.onCreate = onCreate
        model = WorkspaceCreateModel(
            server: server,
            coordinator: root.coordinator,
            presentation: presentation,
            prefillName: prefillName,
            prefillPath: prefillPath
        )
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        super.init(nibName: nil, bundle: nil)
        traitOverrides.appRootEnvironment = root
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        createTask?.cancel()
        model.stop()
    }

    private var palette: ThemePalette { root.themeStore.activeThemeID.palette }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        // A row that rearranges (the folder check) re-measures.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.accessibilityIdentifier = "workspace.create.list"
        pinCollectionViewAboveKeyboard()
        installDataSource()
        navigationItem.leftBarButtonItem = cancelItem
        iconPicker.anchor = self
        // The icon picker's style follows the size classes.
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (screen: Self, _) in
            screen.setNeedsUpdateProperties()
        }
        setNeedsUpdateProperties()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        iconPicker.sync()
    }

    /// The form ends at the keyboard, so a field stays above it.
    private func pinCollectionViewAboveKeyboard() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let maxWidth = collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: IPadReadableContentWidth.form)
        let fillWidth = collectionView.widthAnchor.constraint(equalTo: view.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            maxWidth,
            fillWidth,
        ])
    }

    override func updateProperties() {
        super.updateProperties()
        let theme = root.themeStore
        view.overrideUserInterfaceStyle = theme.userInterfaceStyle
        view.backgroundColor = theme.backgroundColor
        collectionView.backgroundColor = theme.backgroundColor
        title = model.navigationTitle
        ControlScreenList.setBarItems(trailing: trailingItems(), leading: [cancelItem], on: navigationItem)
        createItem.isEnabled = model.canCreate
        applySnapshot()
        updateIconPicker()
    }

    private func trailingItems() -> [UIBarButtonItem] {
        guard model.step == .configure else { return [] }
        return [model.isCreating ? creatingItem : createItem]
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        func add(_ section: Section, _ items: [Item]) {
            guard !items.isEmpty else { return }
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }

        if model.isGuidedFirstWorkspace { add(.intro, [.intro]) }
        if model.oppiConnection != nil { add(.oppi, [.createWithOppi]) }
        add(.sandbox, [.sandbox])
        switch model.step {
        case .pickProject:
            add(.entry, model.sandboxMode ? [.manual] : [.manual, .blank])
            if model.isLoadingDirectories {
                add(.scan, [.scanning])
            } else if model.directoriesError != nil {
                add(.scan, [.scanError])
            } else if model.directories.isEmpty {
                add(.scan, [.noProjects])
            } else {
                add(.projects, Self.unique(model.directories.map(\.id)).map(Item.project))
            }
        case .configure:
            add(.name, [.name])
            var folder: [Item] = [model.isHostMountFromProjectPicker ? .folderFixed : .folderField]
            if model.folderCheck != .none { folder.append(.folderCheck) }
            if !model.isHostMountFromProjectPicker, !model.hostMountCompletions.isEmpty {
                folder.append(.suggestionsLabel)
                folder += Self.unique(model.hostMountCompletions.map(\.id)).map(Item.suggestion)
            }
            add(.folder, folder)
            add(.appearance, [.icon])
            let skills = model.skills
            add(.skills, skills.isEmpty ? [.noSkills] : Self.unique(skills.map(\.id)).map(Item.skill))
            add(.options, [.gitStatus])
            add(.advanced, [model.showAdvanced ? .description : .showAdvanced])
            if model.error != nil { add(.error, [.error]) }
            add(.submit, [.submit])
        }

        let shown = Set(dataSource.snapshot().itemIdentifiers)
        let themeID = root.themeStore.activeThemeID
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { item in
            AnyHashable([AnyHashable(themeID), inputs(of: item)])
        }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        let stepChanged = appliedStep != model.step
        let hadItems = dataSource.snapshot().numberOfItems > 0
        appliedStep = model.step
        dataSource.apply(snapshot, animatingDifferences: hadItems) { [weak self] in
            guard let self, stepChanged, hadItems else { return }
            // The other step opens at its top, not where this one was scrolled.
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
                animated: false
            )
        }
        refreshVisibleSupplementaries()
    }

    /// A snapshot traps on a repeated item identifier, so a response that
    /// repeats an id shows its first.
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Every value a row is drawn from, so a change re-draws only that row.
    private func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .intro: AnyHashable(model.step == .pickProject)
        case .sandbox: AnyHashable(model.sandboxMode)
        case .scanError: AnyHashable(model.directoriesError)
        // The folder mode picks Name's Return target (next field or done).
        case .name: AnyHashable([AnyHashable(model.name), AnyHashable(model.isHostMountFromProjectPicker)])
        case .folderFixed, .folderField: AnyHashable(model.hostMount)
        case .folderCheck:
            AnyHashable([
                AnyHashable(model.folderCheck),
                AnyHashable(model.hostPathPendingCreation == model.trimmedHostMount),
                AnyHashable(model.isCreatingHostDirectory),
            ])
        case .icon: AnyHashable(model.icon)
        case .skill(let id): AnyHashable(model.skills.first { $0.id == id }.map { [$0.name, $0.description] })
        case .gitStatus: AnyHashable(model.gitStatusEnabled)
        case .description: AnyHashable(model.description)
        case .error: AnyHashable(model.error)
        case .submit: AnyHashable([AnyHashable(model.canCreate), AnyHashable(model.isCreating)])
        case .createWithOppi, .manual, .blank, .scanning, .noProjects, .project, .suggestionsLabel,
             .suggestion, .noSkills, .showAdvanced:
            AnyHashable(0)
        }
    }

    // MARK: - Headers and footers

    private func header(_ section: Section) -> String? {
        switch section {
        case .projects: "Projects on \(model.server.name)"
        case .folder: "Workspace Folder"
        case .appearance: "Appearance"
        case .skills: "Pi Skills"
        case .advanced: model.showAdvanced ? "Optional" : nil
        case .intro, .oppi, .sandbox, .entry, .scan, .name, .options, .error, .submit: nil
        }
    }

    private func footer(_ section: Section) -> String? {
        switch section {
        case .sandbox:
            guard model.sandboxMode else { return nil }
            return model.step == .pickProject
                ? "Isolated micro-VM. Pick a project to mount."
                : "Runs in an isolated micro-VM. Secrets and network are controlled by the host."
        case .scan:
            guard model.isGuidedFirstWorkspace else {
                return model.directoriesError == nil && !model.isLoadingDirectories
                    ? "Checked: ~/workspace, ~/projects, ~/src, ~/code, ~/Developer"
                    : nil
            }
            if model.isLoadingDirectories { return nil }
            if model.directoriesError != nil {
                return "You can still enter an existing folder path or leave the folder empty and Oppi creates one."
            }
            return "Checked: ~/workspace, ~/projects, ~/src, ~/code, ~/Developer\nThat’s okay. Enter an existing folder path or leave the folder empty and Oppi creates one."
        case .folder:
            return model.folderFooter
        case .skills:
            return "New sessions load skills, extensions, prompts, and themes from Pi user and project settings for this folder."
        case .options:
            return "Shows branch, changed files, and line stats above the chat."
        case .intro, .oppi, .entry, .projects, .name, .appearance, .advanced, .error, .submit:
            return nil
        }
    }

    private func configureHeader(_ view: UICollectionViewListCell, at indexPath: IndexPath) {
        var content = UIListContentConfiguration.groupedHeader()
        content.text = dataSource?.sectionIdentifier(for: indexPath.section).flatMap(header)
        view.contentConfiguration = content
    }

    private func configureFooter(_ view: UICollectionViewListCell, at indexPath: IndexPath) {
        var content = UIListContentConfiguration.groupedFooter()
        content.text = dataSource?.sectionIdentifier(for: indexPath.section).flatMap(footer)
        content.textProperties.numberOfLines = 0
        view.contentConfiguration = content
    }

    /// Diffable updates keep a section's header and footer views, so their
    /// text is rewritten here when the state it describes changes.
    private func refreshVisibleSupplementaries() {
        let kinds: [(String, (UICollectionViewListCell, IndexPath) -> Void)] = [
            (UICollectionView.elementKindSectionHeader, self.configureHeader),
            (UICollectionView.elementKindSectionFooter, self.configureFooter),
        ]
        for (kind, configure) in kinds {
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
                guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                    as? UICollectionViewListCell else { continue }
                configure(view, indexPath)
            }
        }
    }

    // MARK: - Data source

    private func installDataSource() {
        let row = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureStatic(cell, item: item)
        }
        let button = UICollectionView.CellRegistration<SidebarListCell, Item> { [weak self] cell, _, item in
            self?.configureButton(cell, item: item)
        }
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
            self?.configureField(cell, item: item)
        }
        let check = UICollectionView.CellRegistration<WorkspaceFolderCheckCell, Item> { [weak self] cell, _, _ in
            self?.configureFolderCheck(cell)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            self?.configureHeader(view, at: indexPath)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            self?.configureFooter(view, at: indexPath)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .createWithOppi, .manual, .blank, .project, .suggestion, .icon, .showAdvanced, .submit:
                collectionView.dequeueConfiguredReusableCell(using: button, for: indexPath, item: item)
            case .name, .folderField, .description:
                collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            case .folderCheck:
                collectionView.dequeueConfiguredReusableCell(using: check, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    // MARK: - Rows

    /// Rows that do nothing on tap: text, switches, and the fixed folder.
    private func configureStatic(_ cell: UICollectionViewListCell, item: Item) {
        let palette = palette
        var content = UIListContentConfiguration.cell()
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        switch item {
        case .intro:
            content = .subtitleCell()
            let guidedPick = model.step == .pickProject
            content.text = guidedPick ? "Create your first workspace" : "Almost there"
            content.textProperties.font = .scaled(.headline)
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = guidedPick
                ? "A workspace tells Oppi which folder to work in. Pick a project on \(model.server.name), enter a folder path manually, or leave the folder empty and Oppi creates one if you just want to explore the app."
                : "Review the workspace settings, then create it. Oppi will open the workspace next so you can start your first session."
            content.secondaryTextProperties.font = .scaled(.subheadline)
            content.secondaryTextProperties.color = UIColor(palette.comment)
        case .sandbox:
            content.text = "Sandbox"
            content.textProperties.color = UIColor(palette.fg)
            cell.accessories = [.settingsToggle(model.sandboxMode, identifier: "workspace.create.sandbox", label: "Sandbox") { [weak self] in
                self?.model.sandboxMode = $0
            }]
        case .scanning:
            content.text = "Scanning projects on server…"
            content.textProperties.color = UIColor(palette.comment)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
        case .scanError:
            content.text = model.directoriesError
            content.textProperties.color = UIColor(palette.orange)
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = UIColor(palette.orange)
        case .noProjects:
            content.text = "No projects found in default locations."
            content.textProperties.color = UIColor(palette.comment)
        case .folderFixed:
            content = .valueCell()
            content.text = "Folder"
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = model.hostMount
            content.secondaryTextProperties.font = .scaledMonospaced(.body)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            content.secondaryTextProperties.numberOfLines = 0
            let change = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = "Change"
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 0)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.scaled(.caption1)
                return outgoing
            }
            change.configuration = config
            change.accessibilityIdentifier = "workspace.create.changeFolder"
            change.addAction(UIAction { [weak self] _ in self?.model.changeProject() }, for: .touchUpInside)
            cell.accessories = [.customView(configuration: .init(customView: change, placement: .trailing()))]
        case .suggestionsLabel:
            content.text = "Suggestions"
            content.textProperties.font = .scaled(.caption1, .semibold)
            content.textProperties.color = UIColor(palette.comment)
        case .noSkills:
            content.text = "No Pi skills discovered for this folder yet."
            content.textProperties.color = UIColor(palette.comment)
        case .skill(let id):
            guard let skill = model.skills.first(where: { $0.id == id }) else { break }
            content = .subtitleCell()
            content.text = skill.name
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = skill.description
            content.secondaryTextProperties.font = .scaled(.caption1)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            content.secondaryTextProperties.numberOfLines = 2
        case .gitStatus:
            content.text = "Show Changes in Chat"
            content.textProperties.color = UIColor(palette.fg)
            cell.accessories = [.settingsToggle(model.gitStatusEnabled, identifier: "workspace.create.gitStatus", label: "Show Changes in Chat") { [weak self] in
                self?.model.gitStatusEnabled = $0
            }]
        case .error:
            content.text = model.error
            content.textProperties.font = .scaled(.caption1)
            content.textProperties.color = UIColor(palette.red)
            cell.accessibilityIdentifier = "workspace.create.error"
        case .createWithOppi, .manual, .blank, .project, .name, .folderField, .folderCheck, .suggestion,
             .icon, .showAdvanced, .description, .submit:
            break
        }
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
    }

    /// Rows whose one accessibility element is a button.
    private func configureButton(_ cell: SidebarListCell, item: Item) {
        let palette = palette
        var content = UIListContentConfiguration.cell()
        var identifier = ""
        var label: String?
        var value: String?
        var hint: String?
        var enabled = true
        var accessories: [UICellAccessory] = []
        var action: () -> Void = {}
        switch item {
        case .createWithOppi:
            content = .subtitleCell()
            content.image = UIImage(systemName: "text.bubble")
            content.imageProperties.tintColor = UIColor(palette.blue)
            content.text = "Create with Oppi"
            content.textProperties.color = UIColor(palette.fg)
            content.secondaryText = "Describe it and Oppi sets it up."
            content.secondaryTextProperties.font = .scaled(.subheadline)
            content.secondaryTextProperties.color = UIColor(palette.comment)
            identifier = "workspace.create.createWithOppi"
            label = "Create with Oppi"
            hint = "Describe it and Oppi sets it up."
            action = { [weak self] in self?.createWithOppi() }
        case .manual:
            content.image = UIImage(systemName: "keyboard")
            content.text = "Enter Folder Path"
            content.textProperties.color = UIColor(palette.blue)
            identifier = "workspace.create.manual"
            label = "Enter Folder Path"
            action = { [weak self] in self?.model.selectManual() }
        case .blank:
            content.image = UIImage(systemName: "folder.badge.plus")
            content.text = "Let Oppi Create a Folder"
            content.textProperties.color = UIColor(palette.comment)
            content.imageProperties.tintColor = UIColor(palette.comment)
            identifier = "workspace.create.blank"
            label = "Let Oppi Create a Folder"
            action = { [weak self] in self?.model.selectBlank() }
        case .project(let path):
            guard let directory = model.directories.first(where: { $0.id == path }) else { break }
            configureProject(&content, &accessories, directory: directory)
            identifier = "workspace.create.project.\(directory.path)"
            label = Self.accessibilityLabel(for: directory)
            hint = "Select project"
            action = { [weak self] in self?.model.selectProject(directory) }
        case .suggestion(let path):
            guard let completion = model.hostMountCompletions.first(where: { $0.id == path }) else { break }
            content.image = UIImage(systemName: "folder")
            content.imageProperties.tintColor = UIColor(palette.comment)
            content.text = completion.path
            content.textProperties.font = .scaledMonospaced(.caption1)
            content.textProperties.color = UIColor(palette.fg)
            identifier = "workspace.create.suggestion.\(completion.path)"
            label = completion.path
            hint = "Use this folder"
            action = { [weak self] in
                // The field takes the completion's path; one still being edited
                // would keep showing the prefix the user typed.
                self?.view.endEditing(true)
                self?.model.applyHostMountCompletion(completion)
            }
        case .icon:
            content.text = "Icon"
            content.textProperties.color = UIColor(palette.fg)
            // The picker opens as a sheet, so the row carries no disclosure chevron.
            let icon = IconChoiceUIView(size: 22, frameSize: 32)
            icon.apply(
                .choice(model.icon, purpose: .workspace, sandbox: false),
                colors: ComposerThemeColors(palette: palette),
                assetCache: model.oppiConnection?.iconAssetCache
            )
            accessories = [.customView(configuration: .init(customView: icon, placement: .trailing()))]
            identifier = "workspace.create.icon"
            label = "Workspace icon"
            value = WorkspaceIconPickerView.description(model.icon)
            hint = "Opens the icon picker"
            action = { [weak self] in self?.showsIconPicker = true }
        case .showAdvanced:
            content.text = "Show Advanced Options"
            content.textProperties.font = .scaled(.subheadline)
            content.textProperties.color = UIColor(palette.blue)
            identifier = "workspace.create.showAdvanced"
            label = "Show Advanced Options"
            action = { [weak self] in self?.model.showAdvancedOptions() }
        case .submit:
            content.textProperties.alignment = .center
            enabled = model.canCreate
            content.textProperties.color = UIColor(enabled ? palette.blue : palette.comment)
            if model.isCreating {
                content.text = "Creating…"
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                accessories = [.customView(configuration: .init(customView: spinner, placement: .leading()))]
                label = "Creating"
            } else {
                content.text = "Create Workspace"
                content.textProperties.font = .scaled(.body, .semibold)
                label = "Create Workspace"
            }
            identifier = "workspace.create.submit.form"
            action = { [weak self] in self?.create() }
        default:
            break
        }
        content.textProperties.numberOfLines = 0
        ControlScreenList.buttonRow(
            cell,
            identifier: identifier,
            label: label,
            value: value,
            hint: hint,
            enabled: enabled,
            action: action
        )
        ControlScreenList.background(cell, grouped: true, palette: palette)
        cell.accessories = accessories
        cell.contentConfiguration = content
    }

    private func configureProject(
        _ content: inout UIListContentConfiguration,
        _ accessories: inout [UICellAccessory],
        directory: HostDirectory
    ) {
        let palette = palette
        content = .subtitleCell()
        content.image = UIImage(systemName: directory.projectTypeIcon)
        content.imageProperties.tintColor = UIColor(palette.blue)
        content.text = directory.name
        content.textProperties.font = .scaled(.body, .medium)
        content.textProperties.color = UIColor(palette.fg)
        content.secondaryText = [directory.path, directory.language].compactMap { $0 }.joined(separator: " · ")
        content.secondaryTextProperties.font = .scaled(.caption1)
        content.secondaryTextProperties.color = UIColor(palette.comment)
        func badge(_ symbol: String, _ color: UIColor) -> UICellAccessory {
            let image = UIImageView(image: UIImage(systemName: symbol))
            image.tintColor = color
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2)
            return .customView(configuration: .init(customView: image, placement: .trailing()))
        }
        if directory.isGitRepo { accessories.append(badge("arrow.triangle.branch", UIColor(palette.green))) }
        if directory.hasAgentsMd { accessories.append(badge("doc.text", UIColor(palette.orange))) }
    }

    static func accessibilityLabel(for directory: HostDirectory) -> String {
        var parts = [directory.name]
        if let language = directory.language {
            parts.append(language)
        }
        if directory.isGitRepo {
            parts.append("Git repository")
        }
        if directory.hasAgentsMd {
            parts.append("Has agent configuration")
        }
        parts.append(directory.path)
        return parts.joined(separator: ", ")
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, item: Item) {
        let fg = UIColor(palette.fg)
        switch item {
        case .name:
            let goesToFolder = !model.isHostMountFromProjectPicker
            cell.configure(
                text: model.name,
                placeholder: "Required",
                identifier: "workspace.create.name",
                label: "Name",
                autocapitalization: .sentences,
                textColor: fg,
                labelColor: fg,
                returnKey: goesToFolder ? .next : .done,
                onReturn: { [weak self] in
                    if goesToFolder { self?.focusFolderField() } else { self?.view.endEditing(true) }
                }
            ) { [weak self] in self?.model.name = $0 }
            cell.textField.accessibilityLabel = "Name"
        case .folderField:
            cell.configure(
                text: model.hostMount,
                placeholder: "~/workspace/project (must exist)",
                identifier: "workspace.create.hostMount",
                label: "Folder",
                monospaced: true,
                textColor: fg,
                labelColor: fg,
                returnKey: .done,
                onReturn: { [weak self] in self?.view.endEditing(true) }
            ) { [weak self] in self?.model.setHostMount($0) }
            cell.textField.accessibilityLabel = "Folder"
        case .description:
            cell.configure(
                text: model.description,
                placeholder: "Description",
                identifier: "workspace.create.description",
                autocapitalization: .sentences,
                autocorrection: .default,
                textColor: fg,
                returnKey: .done,
                onReturn: { [weak self] in self?.view.endEditing(true) }
            ) { [weak self] in self?.model.description = $0 }
            cell.textField.accessibilityLabel = "Description"
        default:
            break
        }
    }

    /// Return in Name moves on to the folder field, where there is one.
    private func focusFolderField() {
        guard let path = dataSource?.indexPath(for: .folderField),
              let cell = collectionView.cellForItem(at: path) as? SSHTerminalTextFieldCell else { return }
        // After a long test run in one process, UIKit has been seen to refuse this first
        // call after already resigning Name, so giving up would close the keyboard. An
        // immediate second call succeeds. Root cause unknown.
        if !cell.textField.becomeFirstResponder() {
            cell.textField.becomeFirstResponder()
        }
    }

    private func configureFolderCheck(_ cell: WorkspaceFolderCheckCell) {
        let folder = model.trimmedHostMount
        cell.configure(
            check: model.folderCheck,
            isConfirming: model.hostPathPendingCreation == folder,
            isCreating: model.isCreatingHostDirectory,
            serverName: model.server.name,
            palette: palette,
            identifierPrefix: "workspace.create",
            onRequestCreate: { [weak self] in self?.model.hostPathPendingCreation = folder },
            onConfirm: { [weak self] in
                guard let self else { return }
                // The server's resolved path replaces the typed one; a field still
                // being edited would keep showing the old text.
                view.endEditing(true)
                let model = model
                Task { await model.createHostDirectoryFromPendingPath() }
            },
            onCancel: { [weak self] in self?.model.hostPathPendingCreation = nil }
        )
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    // MARK: - Actions

    private func create() {
        guard createTask == nil, model.canCreate else { return }
        createTask = Task { [weak self] in
            guard let self else { return }
            defer { createTask = nil }
            guard let workspace = await model.create() else { return }
            onCreate?(workspace)
            Router.finish(self)
        }
    }

    /// Opens the guided composer for the server this sheet creates on, not the
    /// active one. A prepared session closes both sheets and opens the session.
    private func createWithOppi() {
        guard guidedSheet == nil, let connection = model.oppiConnection else { return }
        let sheet = GuidedControlSessionViewController(
            configuration: GuidedControlComposerConfiguration(
                domain: .workspaces,
                intent: .create,
                placeholder: "Describe the workspace you want…"
            ),
            root: root,
            connection: { connection },
            onSessionPrepared: { [weak self] target in self?.guidedSessionPrepared(target) }
        )
        guidedSheet = sheet
        Router.present(sheet, presentation: .sheet.inNavigation(), from: self, theme: root.themeStore)
    }

    /// Closes this sheet with the guided sheet above it, then opens the session
    /// once the dismissal has started.
    private func guidedSessionPrepared(_ target: WorkspaceSessionNavTarget) {
        let navigation = root.navigation
        Router.finish(self)
        Task { @MainActor in
            await Task.yield()
            navigation.openWorkspaceSession(target)
        }
    }

    // MARK: - Icon picker

    private func updateIconPicker() {
        let model = model
        iconPicker.update(
            id: showsIconPicker ? "icon-picker" : nil,
            presentation: WorkspaceIconPickerView.presentation(traitCollection),
            root: root,
            clear: { [weak self] in self?.showsIconPicker = false },
            screen: { WorkspaceIconPickerView.screen(editing: model) }
        )
    }
}

/// What the folder field's check says, in the folder section: checking,
/// missing (with the confirm-before-create flow), invalid, or valid. Draws the
/// same states as `WorkspaceFolderValidationView`.
final class WorkspaceFolderCheckCell: UICollectionViewListCell {
    private let statusImage = UIImageView()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let spinnerLabel = UILabel()
    private let createButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let statusRow: UIStackView
    private let creatingRow: UIStackView
    private let buttonRow: UIStackView
    private var actions: [(UIButton, UIAction)] = []

    override init(frame: CGRect) {
        statusRow = UIStackView(arrangedSubviews: [statusImage, statusLabel])
        creatingRow = UIStackView(arrangedSubviews: [spinner, spinnerLabel])
        buttonRow = UIStackView(arrangedSubviews: [createButton, confirmButton, cancelButton, UIView()])
        super.init(frame: frame)
        for row in [statusRow, creatingRow, buttonRow] {
            row.axis = .horizontal
            row.spacing = 8
        }
        statusRow.alignment = .firstBaseline
        creatingRow.alignment = .center
        buttonRow.alignment = .center
        for label in [statusLabel, detailLabel, spinnerLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.font = .scaled(.caption1)
        }
        statusImage.setContentHuggingPriority(.required, for: .horizontal)
        statusImage.setContentCompressionResistancePriority(.required, for: .horizontal)
        let column = UIStackView(arrangedSubviews: [statusRow, detailLabel, creatingRow, buttonRow])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            // Centered, so a row the list holds at its 44 pt minimum does not
            // stretch the status text taller than itself and push it down.
            column.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: column.heightAnchor, constant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        setActions([])
    }

    private func setActions(_ new: [(UIButton, UIAction)]) {
        for (button, action) in actions { button.removeAction(action, for: .touchUpInside) }
        actions = new
        for (button, action) in new { button.addAction(action, for: .touchUpInside) }
    }

    private func style(_ button: UIButton, title: String, image: String?, prominent: Bool, identifier: String) {
        var config = prominent ? UIButton.Configuration.borderedProminent() : UIButton.Configuration.bordered()
        config.buttonSize = .small
        config.title = title
        config.image = image.flatMap { UIImage(systemName: $0) }
        config.imagePadding = 4
        button.configuration = config
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
    }

    func configure(
        check: WorkspaceFolderCheck,
        isConfirming: Bool,
        isCreating: Bool,
        serverName: String,
        palette: ThemePalette,
        identifierPrefix: String,
        onRequestCreate: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let comment = UIColor(palette.comment)
        let status: (symbol: String, text: String, color: UIColor)?
        switch check {
        case .none: status = nil
        case .checking: status = ("clock", "Checking folder\u{2026}", comment)
        case .missing: status = ("folder.badge.plus", "Folder doesn\u{2019}t exist", comment)
        case .invalid(let message): status = ("exclamationmark.triangle.fill", message, UIColor(palette.red))
        case .valid: status = ("checkmark.circle", "Folder exists", UIColor(palette.green))
        }
        statusRow.isHidden = status == nil
        statusImage.image = status.flatMap { UIImage(systemName: $0.symbol) }
        statusImage.tintColor = status?.color
        statusImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        statusLabel.text = status?.text
        statusLabel.textColor = status?.color

        let isMissing = check == .missing
        detailLabel.isHidden = !(isMissing && isConfirming)
        detailLabel.text = "Create this one folder on \(serverName)? The parent folder must already exist."
        detailLabel.textColor = comment

        let showsSpinner = isMissing && isConfirming && isCreating
        creatingRow.isHidden = !showsSpinner
        spinnerLabel.text = "Creating folder\u{2026}"
        spinnerLabel.textColor = comment
        if showsSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }

        let asksToConfirm = isMissing && isConfirming && !isCreating
        createButton.isHidden = !(isMissing && !isConfirming)
        confirmButton.isHidden = !asksToConfirm
        cancelButton.isHidden = !asksToConfirm
        buttonRow.isHidden = createButton.isHidden && confirmButton.isHidden
        style(createButton, title: "Create This Folder", image: "plus", prominent: false, identifier: "\(identifierPrefix).createMissingFolder")
        style(confirmButton, title: "Create Folder", image: "plus", prominent: true, identifier: "\(identifierPrefix).confirmCreateFolder")
        style(cancelButton, title: "Cancel", image: nil, prominent: false, identifier: "\(identifierPrefix).cancelCreateFolder")
        createButton.isEnabled = !isCreating
        setActions([
            (createButton, UIAction { _ in onRequestCreate() }),
            (confirmButton, UIAction { _ in onConfirm() }),
            (cancelButton, UIAction { _ in onCancel() }),
        ])
    }
}
