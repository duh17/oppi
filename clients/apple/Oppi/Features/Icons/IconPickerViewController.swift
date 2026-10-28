import UIKit

extension ModalPresentation {
    /// How the router presents `IconPickerViewController`, in its navigation:
    /// full screen in compact width (iPhone), a large sheet in compact
    /// height, otherwise a medium and large sheet with a grabber.
    ///
    /// Full screen is `.overFullScreen`: the picker saves into its presenter,
    /// and a presenter covered by `.fullScreen` left the window and dropped
    /// the saved icon.
    static func iconPicker(
        horizontal: UIUserInterfaceSizeClass,
        vertical: UIUserInterfaceSizeClass
    ) -> ModalPresentation {
        if horizontal == .compact {
            return ModalPresentation(style: .overFullScreen).inNavigation()
        }
        if vertical == .compact {
            return .sheet.detents([.large()], grabber: true).inNavigation()
        }
        return .sheet.detents([.medium(), .large()], grabber: true).inNavigation()
    }

    /// The icon picker's presentation for the presenting view's size classes.
    static func iconPicker(for traits: UITraitCollection) -> ModalPresentation {
        iconPicker(horizontal: traits.horizontalSizeClass, vertical: traits.verticalSizeClass)
    }
}

/// The icon and avatar picker an Agent and a workspace share: an Emoji or
/// Genmoji chooser, and a searchable grid of SF Symbols. Presented at the root
/// of a router navigation controller (`ModalPresentation.iconPicker`), which
/// gives it its bar: Cancel, and Save, which uploads a Genmoji if one was
/// chosen and then commits the icon. A failed save shows its reason at the top
/// with Retry and keeps the choice.
///
/// The screen is a grid, not a list of rows, so it lays out its own sections
/// (a list for the chooser and the search field, a grid for the symbols) and
/// is not on the settings base.
@MainActor
final class IconPickerViewController: UIViewController, UICollectionViewDelegate {
    /// What one picker edits and where its choice goes.
    struct Source {
        let purpose: IconPickerPurpose
        let savedValue: IconChoice
        /// The prefix of every accessibility identifier, e.g. `agent.iconPicker`.
        let accessibilityPrefix: String
        let assetCache: IconAssetCache?
        /// Uploads a Genmoji the person chose and returns the icon that names it.
        let prepareGenmoji: (Data, String) async throws -> IconChoice
        /// Persists the chosen icon. A throw keeps the picker open with the reason.
        let commit: (IconChoice) async throws -> Void
    }

    private enum Section: Hashable, Sendable { case saveError, custom, symbolSearch, symbols, saving }
    private enum Item: Hashable, Sendable {
        case saveError, chooser, validation, search, noResults, symbol(String), saving
    }

    private let source: Source
    private let model: IconPickerModel<IconChoice>
    private var searchText = ""
    private var draftGenmojiImage: UIImage?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var appliedThemeID: ThemeID?
    private var changedRows = ChangedRows<Item>()
    private var lastErrorMessage: String?
    private let glyphInput = IconPickerGlyphInput()

    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout { [weak self] index, environment in
            self?.layoutSection(at: index, environment: environment) ?? Self.listSection(
                environment, headers: false, footers: false
            )
        }
    )
    private lazy var cancelItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            Router.finish(self)
        })
        item.accessibilityIdentifier = "\(source.accessibilityPrefix).cancel"
        return item
    }()
    private lazy var saveItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = "Save"
        item.accessibilityIdentifier = "\(source.accessibilityPrefix).save"
        return item
    }()
    private lazy var savingItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.accessibilityLabel = "Saving"
        return UIBarButtonItem(customView: spinner)
    }()

    init(source: Source) {
        self.source = source
        model = IconPickerModel(
            purpose: source.purpose,
            savedValue: source.savedValue,
            defaultValue: .defaultValue,
            customChoice: Self.customChoice,
            valueValidation: { value in
                guard case .symbol(let name) = value, !IconSymbolCatalog.isAvailable(name) else { return nil }
                return "The selected SF Symbol is unavailable on this device."
            }
        )
        super.init(nibName: nil, bundle: nil)
        title = source.purpose.title
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static func customChoice(_ value: IconChoice) -> IconPickerCustomChoice? {
        switch value {
        case .emoji(let emoji): .emoji(emoji)
        case .genmoji(_, let contentDescription): .genmoji(contentDescription)
        case .defaultValue, .symbol: nil
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "\(source.accessibilityPrefix).list"
        SettingsListStyle.pin(collectionView, in: view)
        endListAtKeyboard(collectionView)
        installGlyphInput()
        installDataSource()
        navigationItem.leftBarButtonItem = cancelItem
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .oppiThemeDidChange, object: nil
        )
        setNeedsUpdateProperties()
    }

    @objc private func themeDidChange() { setNeedsUpdateProperties() }

    override func updateProperties() {
        super.updateProperties()
        let themeID = ThemeRuntimeState.currentThemeID()
        if appliedThemeID != themeID {
            appliedThemeID = themeID
            SettingsListStyle.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        }
        // Everything a row shows is read here, so a model change re-runs this pass.
        _ = (model.draft, model.selectedCustomChoice, model.validationMessage, model.errorMessage, model.isSaving)
        applySnapshot(themeID: themeID)

        let isSaving = model.isSaving
        let trailing = isSaving ? savingItem : saveItem
        if navigationItem.rightBarButtonItem !== trailing {
            navigationItem.rightBarButtonItem = trailing
        }
        saveItem.isEnabled = model.canSave
        saveItem.accessibilityHint = model.validationMessage.map { "Fix custom input: \($0) Save is disabled." }
            ?? "Saves the selected icon"
        cancelItem.isEnabled = !isSaving
        collectionView.isUserInteractionEnabled = !isSaving
        isModalInPresentation = isSaving
    }

    // MARK: - Snapshot

    private var filteredSymbols: [IconSymbolOption] {
        IconSymbolCatalog.availableOptions(matching: searchText)
    }

    private func applySnapshot(themeID: ThemeID) {
        guard let dataSource else { return }
        let symbols = filteredSymbols
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if model.errorMessage != nil {
            snapshot.appendSections([.saveError])
            snapshot.appendItems([.saveError], toSection: .saveError)
        }
        snapshot.appendSections([.custom])
        snapshot.appendItems(
            model.validationMessage == nil ? [.chooser] : [.chooser, .validation],
            toSection: .custom
        )
        snapshot.appendSections([.symbolSearch])
        snapshot.appendItems(symbols.isEmpty ? [.search, .noResults] : [.search], toSection: .symbolSearch)
        if !symbols.isEmpty {
            snapshot.appendSections([.symbols])
            snapshot.appendItems(symbols.map { .symbol($0.symbolName) }, toSection: .symbols)
        }
        if model.isSaving {
            snapshot.appendSections([.saving])
            snapshot.appendItems([.saving], toSection: .saving)
        }
        let shown = Set(dataSource.snapshot().itemIdentifiers)
        let changed = changedRows.changed(in: snapshot.itemIdentifiers) { item in
            AnyHashable([AnyHashable(themeID), inputs(of: item)])
        }
        snapshot.reconfigureItems(changed.filter(shown.contains))
        dataSource.apply(snapshot, animatingDifferences: dataSource.snapshot().numberOfItems > 0)
        showErrorIfNew()
    }

    /// The values a row is drawn from.
    private func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .saveError: AnyHashable(model.errorMessage)
        case .chooser:
            AnyHashable([
                AnyHashable(model.draft == .value(model.savedValue)),
                AnyHashable(String(describing: model.draft)),
                AnyHashable(model.selectedCustomChoice?.accessibilityDescription),
                AnyHashable(draftGenmojiImage.map(ObjectIdentifier.init)),
                AnyHashable(model.isSaving),
            ])
        case .validation: AnyHashable(model.validationMessage)
        case .search: AnyHashable(model.isSaving)
        case .noResults: AnyHashable(searchText)
        case .symbol(let name): AnyHashable([model.draft == .value(.symbol(name)), model.isSaving])
        case .saving: AnyHashable(0)
        }
    }

    /// A save that failed scrolls its reason into view and moves VoiceOver to it.
    private func showErrorIfNew() {
        let message = model.errorMessage
        defer { lastErrorMessage = message }
        guard message != nil, message != lastErrorMessage else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let indexPath = dataSource?.indexPath(for: .saveError) else { return }
            collectionView.scrollToItem(at: indexPath, at: .top, animated: true)
            if let cell = collectionView.cellForItem(at: indexPath) {
                UIAccessibility.post(notification: .layoutChanged, argument: cell)
            }
        }
    }

    // MARK: - Layout

    private func layoutSection(at index: Int, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        switch dataSource?.sectionIdentifier(for: index) {
        case .symbols:
            return Self.symbolGrid(environment)
        case .custom:
            return Self.listSection(environment, headers: false, footers: true)
        case .symbolSearch:
            return Self.listSection(environment, headers: true, footers: false)
        default:
            return Self.listSection(environment, headers: false, footers: false)
        }
    }

    private static func listSection(
        _ environment: NSCollectionLayoutEnvironment,
        headers: Bool,
        footers: Bool
    ) -> NSCollectionLayoutSection {
        NSCollectionLayoutSection.list(
            using: SettingsListStyle.layoutConfiguration(headers: headers, footers: footers),
            layoutEnvironment: environment
        )
    }

    /// Symbols fill the row at least 104 pt wide each, 8 pt apart; at accessibility
    /// text sizes one to a row, so a name never breaks mid-word.
    private static func symbolGrid(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let spacing: CGFloat = 8
        let inset: CGFloat = 20
        let available = environment.container.effectiveContentSize.width - inset * 2
        let columns = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? 1
            : max(1, Int((available + spacing) / (104 + spacing)))
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .estimated(72)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)),
            repeatingSubitem: item,
            count: columns
        )
        group.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: inset, bottom: 16, trailing: inset)
        return section
    }

    // MARK: - Data source

    private lazy var saveErrorRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            .failure("Save error: \(model.errorMessage ?? "")", retry: { [weak self] in self?.save() }),
            identifier: "\(source.accessibilityPrefix).saveError"
        )
    }
    private lazy var validationRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            .failure("Input error: \(model.validationMessage ?? "")", retry: nil),
            identifier: "\(source.accessibilityPrefix).validationError"
        )
    }
    private lazy var noResultsRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(.message("No results for \u{201C}\(searchText)\u{201D}"))
    }
    private lazy var savingRow = UICollectionView.CellRegistration<SettingsStateRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(.loading("Saving icon\u{2026}"), identifier: "\(source.accessibilityPrefix).loading")
    }
    private lazy var chooserRow = UICollectionView.CellRegistration<IconPickerChooserCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        let preview: IconPickerChooserCell.Preview = switch model.draft {
        case .value(let value): model.selectedCustomChoice == nil ? .none : .choice(value)
        case .genmoji(let data, _): .genmoji(draftGenmojiImage ?? Self.decodeDraft(data))
        }
        cell.configure(
            choice: model.selectedCustomChoice,
            preview: preview,
            purpose: source.purpose == .agent ? .agent : .workspace,
            assetCache: source.assetCache,
            isEnabled: !model.isSaving,
            identifier: "\(source.accessibilityPrefix).emojiGenmoji"
        ) { [weak self] in self?.glyphInput.requestFocus() }
    }
    private lazy var searchRow = UICollectionView.CellRegistration<IconPickerSearchCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(text: searchText, identifier: "\(source.accessibilityPrefix).symbolSearch") { [weak self] text in
            guard let self else { return }
            searchText = text
            setNeedsUpdateProperties()
        }
    }
    private lazy var symbolCell = UICollectionView.CellRegistration<IconPickerSymbolCell, Item> { [weak self] cell, _, item in
        guard let self, case .symbol(let name) = item else { return }
        let value = IconChoice.symbol(name)
        cell.configure(
            symbolName: name,
            label: IconSymbolCatalog.label(for: name) ?? name,
            isSelected: model.draft == .value(value),
            isEnabled: !model.isSaving,
            identifier: "\(source.accessibilityPrefix).symbol.\(name)"
        ) { [weak self] in
            guard IconSymbolCatalog.isAvailable(name) else { return }
            self?.select(value)
        }
    }

    private func installDataSource() {
        _ = (saveErrorRow, validationRow, noResultsRow, savingRow, chooserRow, searchRow, symbolCell)
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.header()
            content.text = self?.source.purpose.symbolSectionTitle
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = "Use the Globe key to switch to the Emoji keyboard if needed."
            content.textProperties.numberOfLines = 0
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(
            collectionView: collectionView,
            cellProvider: SettingsListStyle.cardProvider { [weak self] collectionView, indexPath, item in
                guard let self else { return nil }
                switch item {
                case .saveError: return collectionView.dequeueConfiguredReusableCell(using: saveErrorRow, for: indexPath, item: item)
                case .validation: return collectionView.dequeueConfiguredReusableCell(using: validationRow, for: indexPath, item: item)
                case .noResults: return collectionView.dequeueConfiguredReusableCell(using: noResultsRow, for: indexPath, item: item)
                case .saving: return collectionView.dequeueConfiguredReusableCell(using: savingRow, for: indexPath, item: item)
                case .chooser: return collectionView.dequeueConfiguredReusableCell(using: chooserRow, for: indexPath, item: item)
                case .search: return collectionView.dequeueConfiguredReusableCell(using: searchRow, for: indexPath, item: item)
                case .symbol: return collectionView.dequeueConfiguredReusableCell(using: symbolCell, for: indexPath, item: item)
                }
            }
        )
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }

    // MARK: - Choosing

    private func select(_ value: IconChoice) {
        draftGenmojiImage = nil
        model.selectValue(value)
        setNeedsUpdateProperties()
    }

    private func installGlyphInput() {
        glyphInput.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glyphInput)
        NSLayoutConstraint.activate([
            glyphInput.widthAnchor.constraint(equalToConstant: 1),
            glyphInput.heightAnchor.constraint(equalToConstant: 1),
            glyphInput.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glyphInput.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        glyphInput.onText = { [weak self] text in
            guard let self else { return false }
            draftGenmojiImage = nil
            let accepted = model.selectEmoji(text, transform: IconChoice.emoji)
            setNeedsUpdateProperties()
            return accepted
        }
        glyphInput.onGenmoji = { [weak self] data, contentDescription, previewImage in
            guard let self, model.selectGenmoji(data: data, contentDescription: contentDescription) else { return false }
            draftGenmojiImage = previewImage
            setNeedsUpdateProperties()
            return true
        }
    }

    /// The Genmoji bytes as a picture, when the glyph's own render is not at hand.
    private static func decodeDraft(_ data: Data) -> UIImage? {
        try? IconAssetCache.decodeRemoteHEIF(data: data, size: 512).image
    }

    // MARK: - Saving

    private func save() {
        guard model.canSave else { return }
        view.endEditing(true)
        Task { [weak self] in
            guard let self else { return }
            let saved = await model.save(prepareGenmoji: source.prepareGenmoji, commit: source.commit)
            if saved { Router.finish(self) }
        }
    }
}

extension IconPickerViewController {
    private enum UploadError: LocalizedError {
        case serverOffline

        var errorDescription: String? { "Server is offline" }
    }

    /// A Genmoji upload to `apiClient`'s server, as `Source.prepareGenmoji`.
    static func uploadGenmoji(using apiClient: APIClient?) -> (Data, String) async throws -> IconChoice {
        { data, contentDescription in
            guard let apiClient else { throw UploadError.serverOffline }
            let asset = try await apiClient.uploadIconAsset(
                data: data,
                contentType: NSAdaptiveImageGlyph.contentType.preferredMIMEType ?? "image/heic"
            )
            return .genmoji(assetId: asset.assetId, contentDescription: contentDescription)
        }
    }

    /// The error `commit` throws when there is no server to save to.
    static var offlineError: any Error { UploadError.serverOffline }
}

// MARK: - Cells

/// The Emoji or Genmoji chooser: the current custom choice drawn at the left
/// with what it is, or the prompt. The whole row is one button that opens the
/// keyboard on the picker's hidden glyph input.
private final class IconPickerChooserCell: UICollectionViewListCell {
    enum Preview {
        case none
        case choice(IconChoice)
        case genmoji(UIImage?)
    }

    private let button = SettingsRowButton(type: .system)
    private let iconView = IconChoiceUIView(size: 28, frameSize: 36)
    private let imageView = UIImageView()
    private let promptView = UIImageView(image: UIImage(systemName: "face.smiling"))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let leading = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [iconView, imageView, promptView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            ])
        }
        imageView.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28),
        ])
        // The icon slot is 36 pt at every text size, so the prompt's symbol does not scale out of it.
        promptView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22)
        leading.setContentHuggingPriority(.required, for: .horizontal)
        leading.setContentCompressionResistancePriority(.required, for: .horizontal)
        leading.widthAnchor.constraint(equalToConstant: 36).isActive = true
        leading.heightAnchor.constraint(equalToConstant: 36).isActive = true

        titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        for label in [titleLabel, detailLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 2
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [leading, text, chevron])
        row.spacing = 12
        row.alignment = .center
        for view in [row, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.onHighlight = { [weak self] in self?.isHighlighted = $0 }
        button.accessibilityTraits = .button
        // The labels paint the row; the button above them is its one accessible element.
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        choice: IconPickerCustomChoice?,
        preview: Preview,
        purpose: IconChoiceUIView.Content.Purpose,
        assetCache: IconAssetCache?,
        isEnabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let style = SettingsStyle.current
        iconView.isHidden = true
        imageView.isHidden = true
        promptView.isHidden = true
        switch preview {
        case .none:
            promptView.isHidden = false
            promptView.tintColor = style.accent
        case .choice(let value):
            iconView.isHidden = false
            iconView.apply(
                .choice(value, purpose: purpose, sandbox: false),
                colors: ComposerThemeColors(palette: ThemeRuntimeState.currentPalette()),
                assetCache: assetCache
            )
        case .genmoji(let image):
            imageView.isHidden = false
            imageView.image = image
        }
        titleLabel.text = "Choose Emoji or Genmoji"
        titleLabel.textColor = style.title
        detailLabel.text = choice?.accessibilityDescription
        detailLabel.textColor = style.value
        detailLabel.isHidden = choice == nil
        chevron.tintColor = style.value
        contentView.alpha = isEnabled ? 1 : 0.4
        button.isEnabled = isEnabled
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = "Choose Emoji or Genmoji"
        button.accessibilityValue = choice?.accessibilityDescription ?? "No custom choice selected"
        button.accessibilityHint = "Opens the current keyboard"
        button.accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        imageView.image = nil
        isHighlighted = false
    }
}

/// The symbol search field. The field is the cell's one accessible element and
/// at least 44 pt tall, so the control itself meets the touch target.
private final class IconPickerSearchCell: UICollectionViewListCell {
    private let field = UITextField()
    private var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = "Search symbols"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.borderStyle = .none
        field.layer.cornerRadius = 10
        // Text starts 10 pt in from the rounded edge, and the clear button stops short of it.
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        field.leftViewMode = .always
        field.returnKeyType = .search
        field.accessibilityLabel = "Search SF Symbols"
        field.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(field.text ?? "")
        }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.field.resignFirstResponder() }, for: .editingDidEndOnExit)
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityElements = [field]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(text: String, identifier: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        // The field owns its text while it is being typed in.
        if !field.isFirstResponder, field.text != text { field.text = text }
        let style = SettingsStyle.current
        field.backgroundColor = style.page
        field.textColor = style.title
        field.tintColor = style.accent
        field.attributedPlaceholder = NSAttributedString(
            string: "Search symbols",
            attributes: [.foregroundColor: style.value]
        )
        field.accessibilityIdentifier = identifier
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
    }
}

/// One symbol in the grid: the symbol over its name, one button for the whole
/// tile. The selected symbol has the accent tint and a checkmark.
private final class IconPickerSymbolCell: UICollectionViewCell {
    private let button = SettingsRowButton(type: .system)
    private let symbolView = UIImageView()
    private let nameLabel = UILabel()
    private let badge = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        contentView.layer.borderWidth = 1
        symbolView.contentMode = .center
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        nameLabel.textAlignment = .center
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        let stack = UIStackView(arrangedSubviews: [symbolView, nameLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        for view in [stack, badge, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        button.accessibilityTraits = .button
        accessibilityElements = [button]
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        symbolName: String,
        label: String,
        isSelected: Bool,
        isEnabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) {
        let style = SettingsStyle.current
        let tint = isSelected ? style.accent : style.title
        symbolView.image = UIImage(systemName: symbolName)
        symbolView.tintColor = tint
        nameLabel.text = label
        nameLabel.textColor = tint
        badge.isHidden = !isSelected
        badge.tintColor = style.accent
        contentView.backgroundColor = isSelected ? style.accent.withAlphaComponent(0.14) : style.card
        contentView.layer.borderColor = (isSelected ? style.accent.withAlphaComponent(0.7) : .clear).cgColor
        contentView.alpha = isEnabled ? 1 : 0.4
        button.isEnabled = isEnabled
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.accessibilityValue = isSelected ? "Selected" : "Not selected"
        button.accessibilityTraits = {
            var traits: UIAccessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            if isSelected { traits.insert(.selected) }
            return traits
        }()
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
    }
}

// MARK: - Emoji and Genmoji input

/// The responder that takes the Emoji or Genmoji the person picks on the
/// keyboard. It is one point, clear, and hidden from VoiceOver: the chooser row
/// owns the label and the feedback, and this owns glyph input.
private final class IconPickerGlyphInput: UITextView, UITextViewDelegate {
    /// Text typed or picked; true when it is a valid emoji, which closes the keyboard.
    var onText: ((String) -> Bool)?
    /// A Genmoji's bytes, its description, and a render; true when accepted.
    var onGenmoji: ((Data, String, UIImage?) -> Bool)?

    override var canBecomeFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isEditable = true
        isSelectable = true
        supportsAdaptiveImageGlyph = true
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        textContainer.maximumNumberOfLines = 1
        textContainer.lineBreakMode = .byClipping
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Starts from an empty field and takes the keyboard.
    func requestFocus() {
        clear()
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            becomeFirstResponder()
        }
    }

    private func clear() {
        delegate = nil
        attributedText = NSAttributedString()
        delegate = self
    }

    func textViewDidChange(_ textView: UITextView) {
        let attributed = textView.attributedText ?? NSAttributedString()
        var glyph: NSAdaptiveImageGlyph?
        attributed.enumerateAttribute(.adaptiveImageGlyph, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            guard let value = value as? NSAdaptiveImageGlyph else { return }
            glyph = value
            stop.pointee = true
        }
        if let glyph {
            let image = Self.render(glyph, size: 128)
            if onGenmoji?(glyph.imageContent, glyph.contentDescription, image) == true {
                textView.resignFirstResponder()
            }
            clear()
            return
        }
        if onText?(textView.text ?? "") == true {
            textView.resignFirstResponder()
        }
    }

    /// Renders only the trusted glyph object received directly from UIKit's
    /// text input. Persisted bytes never enter this system-glyph path.
    private static func render(_ glyph: NSAdaptiveImageGlyph, size: CGFloat) -> UIImage? {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0

        let attributed = NSMutableAttributedString(string: "\u{FFFC}")
        attributed.addAttributes(
            [.adaptiveImageGlyph: glyph, .font: UIFont.systemFont(ofSize: size * 0.8)],
            range: NSRange(location: 0, length: 1)
        )
        textView.attributedText = attributed
        textView.sizeToFit()
        guard textView.bounds.width > 0, textView.bounds.height > 0 else { return nil }

        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let scale = min(size / textView.bounds.width, size / textView.bounds.height)
            context.cgContext.translateBy(
                x: (size - textView.bounds.width * scale) / 2,
                y: (size - textView.bounds.height * scale) / 2
            )
            context.cgContext.scaleBy(x: scale, y: scale)
            textView.layer.render(in: context.cgContext)
        }
    }
}
