import UIKit

/// Settings > Chat: the busy animation, the chat style and its work strip,
/// the Top Bar page, and Quick Comments. Values are
/// `AppPreferences.ChatDisplay` / `.ChatTopBar`, which open chats observe, so a
/// change reaches them without reopening the chat. Everything here is saved on
/// this device.
final class SettingsChatViewController: ListScreenController<SettingsChatViewController.Section, SettingsChatViewController.Item> {
    enum Section: Hashable, Sendable { case busy, style, topBar, comments }
    enum Item: Hashable, Sendable {
        case spinnerStyle, spinnerPreview
        case chatStyle, workStripStyle, workStripPreview, conversationPreview
        case topBar
        case quickComments
    }

    private let root: AppRootEnvironment

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(
            title: String(localized: "Chat"),
            listIdentifier: "settings.chat.list",
            scope: .device,
            headers: true,
            footers: true
        )
        navigationItem.backBarButtonItem = UIBarButtonItem(title: String(localized: "Chat"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The Top Bar page is pushed above this one and writes the layout; the
        // Top Bar row's summary has to follow it while this page is behind.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(topBarDidChange),
            name: AppPreferences.ChatTopBar.didChangeNotification,
            object: nil
        )
    }

    @objc private func topBarDidChange() { setNeedsUpdateProperties() }

    private var chatStyle: AppPreferences.ChatDisplay.Style { AppPreferences.ChatDisplay.style }
    private var topBarLayout: ChatTopBarLayout { AppPreferences.ChatTopBar.layout }

    /// Which buttons the Top Bar page has on, in the bar's order.
    private var topBarSummary: String {
        let labels = topBarLayout.order.filter(topBarLayout.isShown).map(\.label)
        return labels.isEmpty
            ? String(localized: "Only the … menu")
            : labels.joined(separator: ", ")
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, Item>] {
        // Read every value so any change re-runs this pass.
        _ = (AppPreferences.Appearance.spinnerStyle, AppPreferences.ChatDisplay.style)
        _ = (AppPreferences.ChatDisplay.workStripStyle, AppPreferences.ChatTopBar.layout)
        var style: [Item] = [.chatStyle]
        switch chatStyle {
        case .full: break
        case .compact: style.append(contentsOf: [.workStripStyle, .workStripPreview])
        case .chat: style.append(.conversationPreview)
        }
        return [
            ListSection(
                .busy,
                footer: String(localized: "The spinner shown while a turn is running."),
                items: [.spinnerStyle, .spinnerPreview]
            ),
            ListSection(.style, header: String(localized: "Style"), footer: Self.styleFooter(chatStyle), items: style),
            ListSection(
                .topBar,
                footer: String(localized: "The buttons a chat shows beside the session title. A button turned off moves into the … menu."),
                items: [.topBar]
            ),
            ListSection(
                .comments,
                footer: String(localized: "Edit the quick comments shown after selecting text and choosing Comment."),
                items: [.quickComments]
            ),
        ]
    }

    /// The preference values a row is drawn from.
    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .spinnerStyle, .spinnerPreview: AnyHashable(AppPreferences.Appearance.spinnerStyle.rawValue)
        case .chatStyle: AnyHashable(chatStyle.rawValue)
        case .workStripStyle, .workStripPreview: AnyHashable(AppPreferences.ChatDisplay.workStripStyle.rawValue)
        case .conversationPreview: AnyHashable(chatStyle.rawValue)
        case .topBar: AnyHashable(topBarLayout)
        case .quickComments: AnyHashable("")
        }
    }

    /// Two steps in nine seconds, so the conversation pill reads like a real
    /// finished turn.
    static let conversationSample = QuietTimelineWorkLine(
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

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: String(localized: "Busy Animation"),
            identifier: "settings.spinnerStyle",
            options: SpinnerStyle.allCases.map { style in
                (style.displayName, style == AppPreferences.Appearance.spinnerStyle, { [weak self] in
                    AppPreferences.Appearance.setSpinnerStyle(style)
                    self?.setNeedsUpdateProperties()
                })
            }
        )
    }

    private lazy var segmentedRow = UICollectionView.CellRegistration<SettingsSegmentedRowCell, Item> { [weak self] cell, _, item in
        self?.configureSegmentedRow(cell, item: item)
    }

    private lazy var previewRow = UICollectionView.CellRegistration<SettingsWorkPreviewCell, Item> { [weak self] cell, _, item in
        self?.configurePreview(cell, item: item)
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Item> { [weak self] cell, _, item in
        guard let self else { return }
        switch item {
        case .topBar:
            cell.configure(
                title: String(localized: "Top Bar"),
                systemImage: nil,
                value: topBarSummary,
                identifier: "settings.chat.topBar"
            ) { [weak self] in self?.openTopBarSettings() }
        default:
            cell.configure(
                title: String(localized: "Quick Comments"),
                systemImage: nil,
                value: nil,
                identifier: "settings.chat.quickComments"
            ) { [weak self] in self?.openQuickComments() }
        }
    }

    override func prepareRegistrations() {
        _ = (menuRow, segmentedRow, previewRow, indexRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .spinnerStyle:
            collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .chatStyle, .workStripStyle:
            collectionView.dequeueConfiguredReusableCell(using: segmentedRow, for: indexPath, item: item)
        case .spinnerPreview, .workStripPreview, .conversationPreview:
            collectionView.dequeueConfiguredReusableCell(using: previewRow, for: indexPath, item: item)
        case .topBar, .quickComments:
            collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        }
    }

    private func configureSegmentedRow(_ cell: SettingsSegmentedRowCell, item: Item) {
        switch item {
        case .chatStyle:
            cell.configure(
                title: String(localized: "Style"),
                identifier: "settings.chatStyle",
                options: AppPreferences.ChatDisplay.Style.allCases.map { ($0.label, $0 == chatStyle) }
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
                options: AppPreferences.ChatDisplay.WorkStripStyle.allCases.map { ($0.label, $0 == current) }
            ) { [weak self] index in
                let style = AppPreferences.ChatDisplay.WorkStripStyle.allCases[index]
                AppPreferences.ChatDisplay.setWorkStripStyle(style)
                self?.setNeedsUpdateProperties()
            }
        default:
            break
        }
    }

    /// The counts the Work Strip preview shows.
    static let workStripSample = QuietTimelineWorkLine(
        id: "settings-work-strip-preview",
        turnID: "settings-work-strip-preview",
        sourceItemIDs: [],
        buckets: [
            .init(kind: .read, count: 4),
            .init(kind: .tooling, count: 7),
            .init(kind: .write, count: 1),
            .init(kind: .edit, count: 1, editStats: .init(added: 12, removed: 3)),
        ],
        displayStyle: .icons,
        isExpanded: false,
        isLive: true,
        liveStartedAt: Date(timeIntervalSince1970: 0)
    )

    /// The real work strip and conversation pill, so the preview cannot drift
    /// from the timeline's geometry.
    private func configurePreview(_ cell: SettingsWorkPreviewCell, item: Item) {
        let value = SettingsStyle.current.value
        switch item {
        case .spinnerPreview:
            cell.configureSpinner(labelColor: value)
        case .workStripPreview:
            cell.configureWorkLine(
                Self.workStripSample,
                style: AppPreferences.ChatDisplay.workStripStyle,
                caption: String(localized: "Live Preview"),
                symbol: "rectangle.compress.vertical",
                labelColor: value
            )
        case .conversationPreview:
            cell.configureWorkLine(
                Self.conversationSample,
                chromeStyle: .conversation,
                caption: String(localized: "Preview"),
                symbol: "bubble.left.and.text.bubble.right",
                labelColor: value
            )
        default:
            break
        }
    }

    /// The Top Bar page. Pushed through the router, like every other screen this
    /// chat opens, so it lands the same way from Settings and from the chat's …
    /// menu.
    private func openTopBarSettings() {
        Router.push(SettingsChatTopBarViewController(), from: self)
    }

    private func openQuickComments() {
        Router.push(QuickCommentsViewController(root: root), from: self)
    }
}

/// A settings row with a title and a segmented control. The control carries the
/// settings identifier, so `app.segmentedControls["settings.chatStyle"]` finds
/// the same control the old SwiftUI picker was. Only for a choice that reshapes
/// a live preview on the same page; every other choice is a `SettingsMenuRowCell`.
final class SettingsSegmentedRowCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let control = UISegmentedControl()
    private var onChange: ((Int) -> Void)?
    private var sideBySideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []

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
            control.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        sideBySideConstraints = [
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            control.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ]
        // Accessibility sizes: the title wraps above a full-width control, as in
        // `SettingsSliderRowCell`, instead of the two sharing one line.
        stackedConstraints = [
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
            control.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            control.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ]
        arrangeForTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.arrangeForTextSize()
        }
    }

    private func arrangeForTextSize() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        NSLayoutConstraint.deactivate(stacked ? sideBySideConstraints : stackedConstraints)
        NSLayoutConstraint.activate(stacked ? stackedConstraints : sideBySideConstraints)
        titleLabel.numberOfLines = stacked ? 0 : 1
        titleLabel.setContentCompressionResistancePriority(stacked ? .defaultLow : .required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        title: String,
        identifier: String,
        options: [(title: String, selected: Bool)],
        onChange: @escaping (Int) -> Void
    ) {
        self.onChange = onChange
        titleLabel.text = title
        titleLabel.textColor = SettingsStyle.current.title
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
        caption.numberOfLines = 0
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

    /// The composer's mic as it looks while dictating, in the chosen Dictation
    /// Animation. It follows that setting on its own and does not listen.
    func configureMic(labelColor: UIColor) {
        let style = AppPreferences.Appearance.dictationIndicatorStyle
        caption.text = String(localized: "Preview")
        caption.textColor = labelColor
        captionIcon.image = UIImage(systemName: "mic")
        captionIcon.tintColor = labelColor
        let mic = MicButtonChromeView()
        mic.isUserInteractionEnabled = false
        mic.isAccessibilityElement = false
        mic.apply(
            isRecording: true,
            isProcessing: false,
            voiceSpectrum: .zero,
            languageLabel: "EN",
            accentColor: SettingsStyle.current.accent,
            engineBadge: .onDevice,
            diameter: ComposerInputMetrics.controlDiameter,
            animated: false
        )
        install(mic, size: CGSize(width: ComposerInputMetrics.controlDiameter, height: ComposerInputMetrics.controlDiameter))
        isAccessibilityElement = true
        accessibilityIdentifier = "settings.voice.micPreview"
        accessibilityLabel = String(localized: "Dictation animation preview")
        accessibilityValue = style.displayName
    }

    /// Any preview view under a caption (Text's sample fonts).
    func configurePreview(_ view: UIView, caption text: String, symbol: String, labelColor: UIColor) {
        caption.text = text
        caption.textColor = labelColor
        captionIcon.image = UIImage(systemName: symbol)
        captionIcon.tintColor = labelColor
        install(view, size: nil, minimumHeight: 0)
        // A preview that fills the row, where a work strip hugs its content.
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
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

    private func install(_ view: UIView, size: CGSize?, minimumHeight: CGFloat = 44) {
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
            constraints.append(view.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight))
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        content?.removeFromSuperview()
        content = nil
        isAccessibilityElement = false
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }
}
