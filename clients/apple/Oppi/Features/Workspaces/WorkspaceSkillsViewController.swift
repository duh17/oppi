import UIKit

/// Pi skills for one workspace, one toggle each. A toggle writes Pi settings at
/// once; the list shows the server's answer after the write. A row's info
/// button opens the skill's detail on this workspace's server and folder.
///
/// Pushed from Workspace Settings, which already made the workspace's server
/// the active one and bound `model` to it; this page only reads the model.
@MainActor
final class WorkspaceSkillsViewController: SettingsListViewController<
    WorkspaceSkillsViewController.Section,
    WorkspaceSkillsViewController.Item
> {
    enum Section: Hashable, Sendable { case skills }

    enum Item: Hashable, Sendable {
        case loading
        case empty
        case skill(String)
        case error
    }

    private let model: WorkspaceSettingsModel
    private let connection: ServerConnection
    private let root: AppRootEnvironment
    private var loadTask: Task<Void, Never>?
    /// Bumped when a toggle's write ends, so its switch is redrawn from the
    /// stored value even where that value did not change (a failed write).
    private var toggleRevision = 0

    init(model: WorkspaceSettingsModel, connection: ServerConnection, root: AppRootEnvironment) {
        self.model = model
        self.connection = connection
        self.root = root
        super.init(
            title: String(localized: "Skills"),
            listIdentifier: "workspace.edit.skills.list",
            footers: true
        )
        traitOverrides.appRootEnvironment = root
    }

    deinit {
        loadTask?.cancel()
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        let model = model
        loadTask?.cancel()
        loadTask = Task { await model.loadPiResourcesIfNeeded() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Rows

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        // Read the theme so a change re-runs this pass.
        _ = (root.themeStore.mode, root.themeStore.manualThemeID)
        var items: [Item] = []
        if model.isLoadingSkills && model.skills.isEmpty {
            items.append(.loading)
        } else if model.skills.isEmpty {
            items.append(.empty)
        } else {
            items.append(contentsOf: model.skills.map { .skill($0.name) })
        }
        if model.skillsError != nil { items.append(.error) }
        return [SettingsSectionModel(.skills, footer: model.piResourceFooter, items: items)]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .loading, .empty:
            return AnyHashable(0)
        case .skill(let name):
            guard let skill = skill(named: name) else { return AnyHashable(0) }
            return AnyHashable([
                AnyHashable(skill.name),
                AnyHashable(skill.description),
                AnyHashable(isEnabled(skill)),
                AnyHashable(model.isPending(.skills, path: skill.path)),
                AnyHashable(model.canTogglePiResources),
                AnyHashable(toggleRevision),
            ])
        case .error:
            return AnyHashable(model.skillsError)
        }
    }

    private func skill(named name: String) -> SkillInfo? {
        model.skills.first { $0.name == name }
    }

    private func isEnabled(_ skill: SkillInfo) -> Bool {
        model.displayedEnabled(.skills, path: skill.path, server: skill.enabled)
    }

    private lazy var skillRow = UICollectionView.CellRegistration<WorkspaceSkillRowCell, Item> { [weak self] cell, _, item in
        guard let self, case .skill(let name) = item, let skill = skill(named: name) else { return }
        configureSkill(cell, skill: skill)
    }

    override func prepareRegistrations() {
        _ = skillRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        if case .skill = item {
            return collectionView.dequeueConfiguredReusableCell(using: skillRow, for: indexPath, item: item)
        }
        return super.dequeue(item, at: indexPath)
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        configureMessage(cell, item: item)
    }

    /// Loading, empty, and the inline error: read-only rows.
    private func configureMessage(_ cell: UICollectionViewListCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        var content = UIListContentConfiguration.cell()
        content.textProperties.numberOfLines = 0
        cell.isAccessibilityElement = true
        switch item {
        case .loading:
            content.text = String(localized: "Loading skills\u{2026}")
            content.textProperties.color = UIColor(palette.comment)
        case .error:
            content.text = model.skillsError
            content.textProperties.font = .preferredFont(forTextStyle: .caption2)
            content.textProperties.color = UIColor(palette.orange)
            cell.accessibilityIdentifier = "workspace.edit.skills.error"
        default:
            content.text = String(localized: "No Pi skills discovered for this folder yet.")
            content.textProperties.color = UIColor(palette.comment)
        }
        cell.accessibilityLabel = content.text
        cell.contentConfiguration = content
    }

    private func configureSkill(_ cell: WorkspaceSkillRowCell, skill: SkillInfo) {
        let path = skill.path
        let name = skill.name
        cell.configure(
            skill: skill,
            isEnabled: isEnabled(skill),
            isPending: model.isPending(.skills, path: path),
            canToggle: model.canTogglePiResources,
            palette: ThemeRuntimeState.currentPalette(),
            onToggle: { [weak self] enabled in
                guard let self else { return }
                let model = model
                Task { [weak self] in
                    await model.setPiResource(.skills, path: path, enabled: enabled)
                    // A refused or failed write leaves the stored value as it
                    // was, so redraw the switch from it.
                    self?.toggleRevision += 1
                    self?.setNeedsUpdateProperties()
                }
            },
            onShowDetail: { [weak self] in self?.showDetail(skillName: name) }
        )
    }

    // MARK: - Actions

    /// The skill's detail, on this workspace's server and folder.
    private func showDetail(skillName: String) {
        let detail = SkillDetailViewController(
            skillName: skillName,
            cwd: model.savedFolder,
            connection: connection,
            root: root,
            reviewCommentSelectionScope: nil
        )
        Router.push(detail, from: self)
    }
}

/// One skill: its name and description, and its controls (a spinner while a
/// write is pending, the switch, and the info button). Laid out by hand so the
/// controls keep their size and sit at the trailing edge; at accessibility
/// sizes they stack, so the text keeps the row's width.
private final class WorkspaceSkillRowCell: UICollectionViewListCell {
    private let nameLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let toggle = UISwitch()
    private let infoButton = UIButton(type: .system)
    private let controls = UIStackView()
    private var onToggle: ((Bool) -> Void)?
    private var onShowDetail: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let text = UIStackView(arrangedSubviews: [nameLabel, descriptionLabel])
        text.axis = .vertical
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alignment = .center
        controls.spacing = 4
        for view in [spinner, toggle, infoButton] { controls.addArrangedSubview(view) }
        contentView.addSubview(text)
        contentView.addSubview(controls)

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        descriptionLabel.font = .preferredFont(forTextStyle: .caption1)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.numberOfLines = 2
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        // The controls keep their own size: the switch and the info button
        // never take the row's spare width, so the text does.
        for control in [toggle, infoButton] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .vertical)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        descriptionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.hidesWhenStopped = true
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onToggle?(toggle.isOn)
        }, for: .valueChanged)
        infoButton.addAction(UIAction { [weak self] _ in self?.onShowDetail?() }, for: .touchUpInside)
        var info = UIButton.Configuration.plain()
        // A fixed-size glyph: the button's 44-point target is the control, and
        // a glyph that scales with the text would take the text's room.
        info.image = UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))
        infoButton.configuration = info
        NSLayoutConstraint.activate([
            infoButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            infoButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            text.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            // An inequality: the controls keep their own width at the trailing
            // edge and the text takes the rest, never the other way around.
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            controls.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            controls.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // The controls are the row's accessible elements: the switch carries
        // the skill's name and description, the button opens its detail.
        isAccessibilityElement = false
        accessibilityElements = [toggle, infoButton]
        arrangeForTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.arrangeForTextSize()
        }
    }

    /// At accessibility sizes the controls stack, so the text keeps the row's
    /// width. A live text-size change restacks them.
    private func arrangeForTextSize() {
        controls.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        skill: SkillInfo,
        isEnabled: Bool,
        isPending: Bool,
        canToggle: Bool,
        palette: ThemePalette,
        onToggle: @escaping (Bool) -> Void,
        onShowDetail: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onShowDetail = onShowDetail
        nameLabel.text = skill.name
        nameLabel.textColor = UIColor(isEnabled ? palette.fg : palette.comment)
        descriptionLabel.text = skill.description
        descriptionLabel.textColor = UIColor(palette.comment)
        if isPending { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !isPending
        toggle.isOn = isEnabled
        toggle.isEnabled = !isPending && canToggle
        toggle.accessibilityIdentifier = "workspace.edit.skill.\(skill.name)"
        toggle.accessibilityLabel = "\(skill.name), \(skill.description)"
        infoButton.tintColor = UIColor(palette.comment)
        infoButton.accessibilityLabel = String(localized: "View \(skill.name) details")
        infoButton.accessibilityIdentifier = "workspace.edit.skill.\(skill.name).detail"
    }
}
