import UIKit

/// Settings > Chat: the busy animation, the chat style and its work strip,
/// the Top Bar page, and Quick Comments. Values are
/// `AppPreferences.ChatDisplay` / `.ChatTopBar`, which open chats observe, so a
/// change reaches them without reopening the chat.
final class SettingsChatViewController: UIViewController, UICollectionViewDelegate {
    private let defaults: UserDefaults
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<Item>()

    private enum Section: Hashable { case busy, style, topBar, comments }
    private enum Item: Hashable {
        case spinnerStyle, spinnerPreview
        case chatStyle, workStripStyle, workStripPreview, conversationPreview
        case topBar
        case quickComments
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Chat")
        navigationItem.largeTitleDisplayMode = .inline
        navigationItem.backBarButtonItem = UIBarButtonItem(title: String(localized: "Chat"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "settings.chat.list"
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil)
        setNeedsUpdateProperties()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Read every value so any change re-runs this pass.
        _ = (AppPreferences.Appearance.spinnerStyle, AppPreferences.ChatDisplay.style)
        _ = (AppPreferences.ChatDisplay.workStripStyle, AppPreferences.ChatTopBar.layout)
        applySnapshot()
    }

    /// Two steps in nine seconds, so the conversation pill reads like a real
    /// finished turn.
    private static let conversationSample = QuietTimelineWorkLine(
        id: "settings-conversation-pill-preview",
        turnID: "settings-conversation-pill-preview",
        sourceItemIDs: [],
        buckets: [.init(kind: .read, count: 1), .init(kind: .tooling, count: 1)],
        displayStyle: .icons,
        isExpanded: false,
        isLive: false,
        liveStartedAt: Date(timeIntervalSince1970: 0),
        intervalEndedAt: Date(timeIntervalSince1970: 9)
    )

    private var chatStyle: AppPreferences.ChatDisplay.Style { AppPreferences.ChatDisplay.style }
    private var topBarLayout: ChatTopBarLayout { AppPreferences.ChatTopBar.layout }

    /// Which buttons the Top Bar page has on, in the bar's order.
    private var topBarSummary: String {
        let labels = topBarLayout.order.filter(topBarLayout.isShown).map(\.label)
        return labels.isEmpty
            ? String(localized: "Only the … menu")
            : labels.joined(separator: ", ")
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.busy, .style, .topBar, .comments])
        snapshot.appendItems([.spinnerStyle, .spinnerPreview], toSection: .busy)
        var style: [Item] = [.chatStyle]
        switch chatStyle {
        case .full: break
        case .compact: style.append(contentsOf: [.workStripStyle, .workStripPreview])
        case .chat: style.append(.conversationPreview)
        }
        snapshot.appendItems(style, toSection: .style)
        snapshot.appendItems([.topBar], toSection: .topBar)
        snapshot.appendItems([.quickComments], toSection: .comments)
        let themeID = ThemeRuntimeState.currentThemeID()
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { item in
            AnyHashable([AnyHashable(themeID), inputs(of: item)])
        }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
    }

    /// The preference values a row is drawn from.
    private func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .spinnerStyle, .spinnerPreview: AnyHashable(AppPreferences.Appearance.spinnerStyle.rawValue)
        case .chatStyle: AnyHashable(chatStyle.rawValue)
        case .workStripStyle, .workStripPreview: AnyHashable(AppPreferences.ChatDisplay.workStripStyle.rawValue)
        case .conversationPreview: AnyHashable(chatStyle.rawValue)
        case .topBar: AnyHashable(topBarLayout)
        case .quickComments: AnyHashable("")
        }
    }

    private func installDataSource() {
        let menu = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configureMenuRow(cell, item: item)
        }
        let segmented = UICollectionView.CellRegistration<SettingsSegmentedRowCell, Item> { [weak self] cell, _, item in
            self?.configureSegmentedRow(cell, item: item)
        }
        let preview = UICollectionView.CellRegistration<SettingsWorkPreviewCell, Item> { [weak self] cell, _, item in
            self?.configurePreview(cell, item: item)
        }
        let action = UICollectionView.CellRegistration<SettingsButtonRowCell, Item> { [weak self] cell, _, item in
            self?.configureButtonRow(cell, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.section(at: indexPath).flatMap(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = self?.section(at: indexPath).flatMap { self?.footer($0) }
            content.textProperties.numberOfLines = 0
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .chatStyle, .workStripStyle:
                collectionView.dequeueConfiguredReusableCell(using: segmented, for: indexPath, item: item)
            case .spinnerPreview, .workStripPreview, .conversationPreview:
                collectionView.dequeueConfiguredReusableCell(using: preview, for: indexPath, item: item)
            case .quickComments, .topBar:
                collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: item)
            default:
                collectionView.dequeueConfiguredReusableCell(using: menu, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func section(at indexPath: IndexPath) -> Section? {
        dataSource?.sectionIdentifier(for: indexPath.section)
    }

    private static func header(_ section: Section) -> String? {
        switch section {
        case .busy: nil
        case .style: String(localized: "Style")
        case .topBar: String(localized: "Top Bar")
        case .comments: nil
        }
    }

    private func footer(_ section: Section) -> String? {
        switch section {
        case .busy:
            String(localized: "The spinner shown while a turn is running.")
        case .style:
            Self.styleFooter(chatStyle)
        case .topBar:
            String(localized: "The buttons a chat shows beside the session title, in this order. A button turned off there moves into the … menu.")
        case .comments:
            String(localized: "Edit the quick comments shown after selecting text and choosing Comment.")
        }
    }

    /// What the chat style does, written for the style that is selected.
    static func styleFooter(_ style: AppPreferences.ChatDisplay.Style) -> String {
        switch style {
        case .full:
            String(localized: "Every tool call and thinking block stays in the transcript.")
        case .compact:
            String(localized: "Each turn's tool calls and thinking fold into one strip you tap to expand. Messages, asks, system events, cache misses, and audio stay visible.")
        case .chat:
            String(localized: "Your messages are bubbles and replies are cards. Each turn's tool calls and thinking fold into a pill you tap to expand.")
        }
    }

    // MARK: - Cells

    /// The spinner and the style: a title and a pop-up menu of the choices,
    /// like the rest of Settings.
    private func configureMenuRow(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.valueCell()
        cell.contentConfiguration = nil
        cell.accessories = []
        cell.accessibilityIdentifier = nil
        switch item {
        case .spinnerStyle:
            content.text = String(localized: "Busy Animation")
            cell.accessories = [.settingsPopUpMenu(
                identifier: "settings.spinnerStyle",
                options: SpinnerStyle.allCases.map { style in
                    (style.displayName, style == AppPreferences.Appearance.spinnerStyle, { [weak self] in
                        AppPreferences.Appearance.setSpinnerStyle(style)
                        self?.setNeedsUpdateProperties()
                    })
                }
            )]
        default:
            break
        }
        cell.contentConfiguration = content
    }

    private func configureSegmentedRow(_ cell: SettingsSegmentedRowCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        switch item {
        case .chatStyle:
            cell.configure(
                title: String(localized: "Style"),
                identifier: "settings.chatStyle",
                options: AppPreferences.ChatDisplay.Style.allCases.map { ($0.label, $0 == chatStyle) },
                textColor: UIColor(palette.fg)
            ) { [weak self] index in
                let style = AppPreferences.ChatDisplay.Style.allCases[index]
                AppPreferences.ChatDisplay.setStyle(style)
                self?.setNeedsUpdateProperties()
            }
        case .workStripStyle:
            let current = AppPreferences.ChatDisplay.workStripStyle
            cell.configure(
                title: String(localized: "Work Strip"),
                identifier: "settings.workStripStyle",
                options: AppPreferences.ChatDisplay.WorkStripStyle.allCases.map { ($0.label, $0 == current) },
                textColor: UIColor(palette.fg)
            ) { [weak self] index in
                let style = AppPreferences.ChatDisplay.WorkStripStyle.allCases[index]
                AppPreferences.ChatDisplay.setWorkStripStyle(style)
                self?.setNeedsUpdateProperties()
            }
        default:
            break
        }
    }

    /// The real work strip and conversation pill, so the preview cannot drift
    /// from the timeline's geometry.
    private func configurePreview(_ cell: SettingsWorkPreviewCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        switch item {
        case .spinnerPreview:
            cell.configureSpinner(labelColor: UIColor(palette.comment))
        case .workStripPreview:
            cell.configureWorkLine(
                WorkStripPreviewCard.sampleWorkLine,
                style: AppPreferences.ChatDisplay.workStripStyle,
                caption: String(localized: "Live Preview"),
                symbol: "rectangle.compress.vertical",
                labelColor: UIColor(palette.comment)
            )
        case .conversationPreview:
            cell.configureWorkLine(
                Self.conversationSample,
                chromeStyle: .conversation,
                caption: String(localized: "Preview"),
                symbol: "bubble.left.and.text.bubble.right",
                labelColor: UIColor(palette.comment)
            )
        default:
            break
        }
    }

    private func configureButtonRow(_ cell: SettingsButtonRowCell, item: Item) {
        let palette = ThemeRuntimeState.currentPalette()
        switch item {
        case .topBar:
            cell.configure(
                title: String(localized: "Top Bar"),
                value: topBarSummary,
                identifier: "settings.chat.topBar",
                color: UIColor(palette.fg)
            ) { [weak self] in
                guard let self else { return }
                navigationController?.pushViewController(SettingsChatTopBarViewController(), animated: true)
            }
        case .quickComments:
            cell.configure(
                title: String(localized: "Quick Comments"),
                identifier: "settings.chat.quickComments",
                color: UIColor(palette.fg)
            ) { [weak self] in
                guard let self, let root = HostFactory.root(near: self) else { return }
                Router.push(
                    HostFactory.screen(root: root, bars: ScreenBars()) { QuickCommentsSettingsView() },
                    from: self
                )
            }
        default:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }
}

/// A settings row with a title and a segmented control. The control carries the
/// settings identifier, so `app.segmentedControls["settings.chatStyle"]` finds
/// the same control the old SwiftUI picker was.
final class SettingsSegmentedRowCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let control = UISegmentedControl()
    private var onChange: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onChange?(self.control.selectedSegmentIndex)
        }, for: .valueChanged)
        contentView.addSubview(titleLabel)
        contentView.addSubview(control)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            control.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        identifier: String,
        options: [(title: String, selected: Bool)],
        textColor: UIColor,
        onChange: @escaping (Int) -> Void
    ) {
        self.onChange = onChange
        titleLabel.text = title
        titleLabel.textColor = textColor
        control.accessibilityIdentifier = identifier
        if control.numberOfSegments != options.count {
            control.removeAllSegments()
            for (index, option) in options.enumerated() {
                control.insertSegment(withTitle: option.title, at: index, animated: false)
            }
        } else {
            for (index, option) in options.enumerated() {
                control.setTitle(option.title, forSegmentAt: index)
            }
        }
        if let selected = options.firstIndex(where: \.selected) {
            control.selectedSegmentIndex = selected
        }
    }
}

/// A settings row that is a real UIButton, so a tap, a VoiceOver activation,
/// and `app.buttons[id]` all reach the same row. A disclosure chevron says it
/// pushes a page.
final class SettingsButtonRowCell: UICollectionViewListCell {
    private let button = UIButton(type: .system)
    private var tapAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityElements = [button]
        accessories = [.disclosureIndicator()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `value` is a second line under the title, for a row that summarizes what
    /// its page holds.
    func configure(
        title: String,
        value: String? = nil,
        identifier: String,
        color: UIColor,
        action: @escaping () -> Void
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.subtitle = value
        configuration.titleAlignment = .leading
        configuration.baseForegroundColor = color
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.accessibilityValue = value
        if let tapAction { button.removeAction(tapAction, for: .touchUpInside) }
        let tap = UIAction { _ in action() }
        tapAction = tap
        button.addAction(tap, for: .touchUpInside)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let tapAction {
            button.removeAction(tapAction, for: .touchUpInside)
            self.tapAction = nil
        }
        button.accessibilityIdentifier = nil
        button.accessibilityValue = nil
    }
}

/// The busy spinner and the work strip previews, drawn with the real timeline
/// views.
final class SettingsWorkPreviewCell: UICollectionViewListCell {
    private let caption = UILabel()
    private let captionIcon = UIImageView()
    private let container = UIView()
    private var content: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.adjustsFontForContentSizeCategory = true
        captionIcon.translatesAutoresizingMaskIntoConstraints = false
        captionIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        container.translatesAutoresizingMaskIntoConstraints = false
        for view in [captionIcon, caption, container] {
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            captionIcon.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            captionIcon.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            caption.leadingAnchor.constraint(equalTo: captionIcon.trailingAnchor, constant: 5),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            caption.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            container.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The real spinner. It follows Settings' busy animation itself.
    func configureSpinner(labelColor: UIColor) {
        caption.text = String(localized: "Preview")
        caption.textColor = labelColor
        captionIcon.image = UIImage(systemName: "circle.dotted")
        captionIcon.tintColor = labelColor
        let spinner = WorkingSpinnerUIView(side: 20)
        spinner.isAnimating = true
        install(spinner, size: CGSize(width: 20, height: 20))
    }

    func configureWorkLine(
        _ workLine: QuietTimelineWorkLine,
        style: AppPreferences.ChatDisplay.WorkStripStyle? = nil,
        chromeStyle: ChatTimelineChromeStyle = .standard,
        caption text: String,
        symbol: String,
        labelColor: UIColor
    ) {
        caption.text = text
        caption.textColor = labelColor
        captionIcon.image = UIImage(systemName: symbol)
        captionIcon.tintColor = labelColor
        let row = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: workLine,
                style: style,
                chromeStyle: chromeStyle
            )
        )
        install(row, size: nil)
    }

    private func install(_ view: UIView, size: CGSize?) {
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        var constraints = [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        if let size {
            constraints.append(view.widthAnchor.constraint(equalToConstant: size.width))
            constraints.append(view.heightAnchor.constraint(equalToConstant: size.height))
        } else {
            constraints.append(view.heightAnchor.constraint(greaterThanOrEqualToConstant: 44))
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        content?.removeFromSuperview()
        content = nil
    }
}
