import UIKit

/// Which theme choice a Settings row edits: the one manual theme, or the
/// Light or Dark preset Match System switches between.
enum ThemeSlot: Hashable, Sendable {
    case manual, light, dark

    var title: String {
        switch self {
        case .manual: String(localized: "Theme")
        case .light: String(localized: "Light Theme")
        case .dark: String(localized: "Dark Theme")
        }
    }

    /// The themes this slot can choose from: the manual slot takes any theme,
    /// Light and Dark only their own side of the picker.
    var pickerThemes: [ThemeID] {
        switch self {
        case .manual: ThemeID.pickerThemes(matching: nil)
        case .light: ThemeID.pickerThemes(matching: .light)
        case .dark: ThemeID.pickerThemes(matching: .dark)
        }
    }

    /// The Settings row's accessibility identifier.
    var rowIdentifier: String {
        switch self {
        case .manual: "settings.appearance.theme"
        case .light: "settings.appearance.lightTheme"
        case .dark: "settings.appearance.darkTheme"
        }
    }

    @MainActor
    func themeID(in store: ThemeStore) -> ThemeID {
        switch self {
        case .manual: store.manualThemeID
        case .light: store.lightThemeID
        case .dark: store.darkThemeID
        }
    }

    @MainActor
    func choose(_ themeID: ThemeID, in store: ThemeStore) {
        switch self {
        case .manual: store.manualThemeID = themeID
        case .light: store.lightThemeID = themeID
        case .dark: store.darkThemeID = themeID
        }
    }
}

/// The theme gallery: one card per theme, drawn in that theme's own palette,
/// so a theme is judged by what it looks like and not by its name. Built-in
/// themes come first, imported ones after. A tap chooses the theme at once and
/// the app re-themes behind the gallery, which stays open to try another.
///
/// Each card is one button (`ThemeCardCell`); its identifier is
/// `settings.appearance.theme.<theme raw value>`. The kit owns the list, its
/// pin, and its theme; the page owns the grid each section is laid out as
/// (`layoutSection(for:environment:)`) and the cards in it.
@MainActor
final class ThemeGalleryViewController: ListScreenController<ThemeGalleryViewController.Section, ThemeID> {
    enum Section: Hashable, Sendable { case builtIn, imported }

    private let themeStore: ThemeStore
    private let slot: ThemeSlot

    init(themeStore: ThemeStore, slot: ThemeSlot) {
        self.themeStore = themeStore
        self.slot = slot
        super.init(title: slot.title, listIdentifier: "settings.appearance.gallery")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A card is a button of its own: choosing a theme is the card's action,
        // never a selection of the list's.
        collectionView.allowsSelection = false
    }

    // MARK: - Rows

    override func sections() -> [ListSection<Section, ThemeID>] {
        let themes = slot.pickerThemes
        let imported = themes.filter(\.isImported)
        var sections: [ListSection<Section, ThemeID>] = [ListSection(
            .builtIn,
            header: String(localized: "Built-in"),
            items: themes.filter { !$0.isImported }
        )]
        if !imported.isEmpty {
            sections.append(ListSection(.imported, header: String(localized: "Imported"), items: imported))
        }
        return sections
    }

    /// A card is drawn from its own theme's palette, so only whether it is the
    /// chosen one can change what it shows. Reading the store here is what re-runs
    /// the page on a choice made anywhere, including the tap on a card.
    override func inputs(of themeID: ThemeID) -> AnyHashable {
        AnyHashable(themeID == slot.themeID(in: themeStore))
    }

    private lazy var card = UICollectionView.CellRegistration<ThemeCardCell, ThemeID> { [weak self] cell, _, themeID in
        guard let self else { return }
        cell.configure(themeID: themeID, selected: slot.themeID(in: themeStore) == themeID) { [weak self] in
            guard let self else { return }
            slot.choose(themeID, in: themeStore)
            setNeedsUpdateProperties()
        }
    }

    override func prepareRegistrations() { _ = card }

    override func dequeue(_ item: ThemeID, at indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: card, for: indexPath, item: item)
    }

    // MARK: - Layout

    /// One column, or two where the width allows: a card needs about 280pt to
    /// show its chat and swatches without crowding. Text at accessibility sizes
    /// takes the whole row.
    override func layoutSection(
        for section: Section,
        environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection? {
        let spacing: CGFloat = 12
        let inset: CGFloat = 16
        let width = environment.container.effectiveContentSize.width - 2 * inset
        let wide = environment.container.effectiveContentSize.width >= 640
        let columns = wide && !environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
        // Each card sizes itself to its content. A row is as tall as its
        // tallest card; a shorter neighbour (a one-line description beside
        // a two-line one) keeps its own height.
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .absolute((width - spacing * CGFloat(columns - 1)) / CGFloat(columns)),
            heightDimension: .estimated(220)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(220)),
            repeatingSubitem: item,
            count: columns
        )
        group.interItemSpacing = .fixed(spacing)
        let laidOut = NSCollectionLayoutSection(group: group)
        laidOut.interGroupSpacing = spacing
        laidOut.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: inset, bottom: 16, trailing: inset)
        // The heading is the section's own: the kit fills its text from
        // `ListSection.header`.
        laidOut.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36)),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )]
        return laidOut
    }
}

// MARK: - Card

/// A theme card. Everything inside is drawn from the previewed theme's
/// palette and never from the app's: a mini chat (a user bubble, an assistant
/// reply, one line of code in the syntax colors), a strip of the seven
/// accents, then the theme's name and a short description on its own
/// background. A checkmark and a thicker accent border mark the chosen theme.
///
/// Like `SettingsIndexRowCell`, the card paints and its overlay button is its
/// one accessible element, so a tap, a VoiceOver activation and
/// `app.buttons[id]` all choose the theme. The preview is decorative to
/// VoiceOver.
final class ThemeCardCell: UICollectionViewCell {
    private let button = SettingsRowButton(type: .system)
    private let card = UIView()
    private let userBubble = ThemeCardBubble()
    private let reply = UILabel()
    private let codeBlock = ThemeCardBubble()
    private let swatches = ThemeSwatchStrip()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        contentView.addSubview(card)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        button.onHighlight = { [weak self] pressed in
            UIView.animate(withDuration: 0.15) {
                self?.card.transform = pressed ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
                self?.card.alpha = pressed ? 0.85 : 1
            }
        }
        accessibilityElements = [button]

        userBubble.label.font = .preferredFont(forTextStyle: .subheadline)
        userBubble.cornerRadius = 14
        userBubble.insets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        userBubble.label.text = String(localized: "Make it feel calmer")
        reply.font = .preferredFont(forTextStyle: .subheadline)
        reply.adjustsFontForContentSizeCategory = true
        reply.numberOfLines = 0
        reply.text = String(localized: "Done. Here is the new look.")
        codeBlock.label.font = UIFontMetrics(forTextStyle: .caption1)
            .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        codeBlock.cornerRadius = 10
        codeBlock.insets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        codeBlock.borderWidth = 1

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 0
        checkmark.isAccessibilityElement = false
        checkmark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        checkmark.setContentHuggingPriority(.required, for: .horizontal)
        checkmark.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The bubble hugs the trailing edge, like the user's side of the chat.
        let userRow = UIView()
        userBubble.translatesAutoresizingMaskIntoConstraints = false
        userRow.addSubview(userBubble)
        NSLayoutConstraint.activate([
            userBubble.topAnchor.constraint(equalTo: userRow.topAnchor),
            userBubble.bottomAnchor.constraint(equalTo: userRow.bottomAnchor),
            userBubble.trailingAnchor.constraint(equalTo: userRow.trailingAnchor),
            userBubble.leadingAnchor.constraint(greaterThanOrEqualTo: userRow.leadingAnchor, constant: 36),
        ])

        // The checkmark shares the name's line only, and keeps its space when
        // hidden: choosing a card never narrows its description, so the card's
        // height does not change under it.
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, checkmark])
        nameRow.alignment = .center
        nameRow.spacing = 8
        let caption = UIStackView(arrangedSubviews: [nameRow, detailLabel])
        caption.axis = .vertical
        caption.spacing = 2

        let stack = UIStackView(arrangedSubviews: [userRow, reply, codeBlock, swatches, caption])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(14, after: swatches)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(themeID: ThemeID, selected: Bool, action: @escaping () -> Void) {
        // The palette the app paints with: built-ins are contrast-resolved,
        // and a custom theme keeps its JSON colors as written.
        let palette = themeID.palette
        let bg = palette.ui.bg
        let accent = palette.ui.blue

        card.backgroundColor = bg
        card.layer.borderWidth = selected ? 3 : 1
        card.layer.borderColor = (selected ? accent : palette.ui.comment.withAlphaComponent(0.45)).cgColor

        userBubble.backgroundColor = palette.ui.userMessageBg
        userBubble.label.textColor = palette.ui.userMessageText
        reply.textColor = palette.ui.fg
        codeBlock.backgroundColor = palette.ui.bgDark
        codeBlock.borderColor = palette.ui.mdCodeBlockBorder
        codeBlock.label.attributedText = Self.codeLine(palette: palette, font: codeBlock.label.font)
        swatches.configure(
            colors: [palette.blue, palette.cyan, palette.green, palette.orange, palette.purple, palette.red, palette.yellow],
            outline: palette.ui.fg.withAlphaComponent(0.2)
        )

        nameLabel.text = themeID.displayName
        nameLabel.textColor = palette.ui.fg
        detailLabel.text = Self.detail(of: themeID)
        detailLabel.textColor = palette.ui.fgDim
        checkmark.tintColor = accent
        checkmark.alpha = selected ? 1 : 0

        button.accessibilityIdentifier = "settings.appearance.theme.\(themeID.rawValue)"
        button.accessibilityLabel = themeID.displayName
        // The description is the one part of the preview worth speaking.
        button.accessibilityValue = Self.detail(of: themeID)
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        button.setTapAction(action)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        button.setTapAction(nil)
        button.accessibilityIdentifier = nil
        button.accessibilityLabel = nil
        button.accessibilityValue = nil
        button.accessibilityTraits = .button
        card.transform = .identity
        card.alpha = 1
    }

    /// An imported theme has no description of its own; say which side of the
    /// day it belongs to.
    private static func detail(of themeID: ThemeID) -> String {
        guard themeID.isImported else { return themeID.detail }
        return themeID.preferredColorScheme == .light
            ? String(localized: "Imported light theme")
            : String(localized: "Imported dark theme")
    }

    /// `return render("ok", 42)` in the theme's syntax colors.
    private static func codeLine(palette: ThemePalette, font: UIFont) -> NSAttributedString {
        let tokens: [(String, UIColor)] = [
            ("return", palette.ui.syntaxKeyword), (" ", palette.ui.mdCodeBlock),
            ("render", palette.ui.syntaxFunction), ("(", palette.ui.syntaxPunctuation),
            ("\"ok\"", palette.ui.syntaxString), (",", palette.ui.syntaxPunctuation),
            (" ", palette.ui.mdCodeBlock), ("42", palette.ui.syntaxNumber),
            (")", palette.ui.syntaxPunctuation),
        ]
        let line = NSMutableAttributedString()
        for (text, color) in tokens {
            line.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        return line
    }
}

/// A padded, rounded label: the chat bubble and the code block of a card.
private final class ThemeCardBubble: UIView {
    let label = UILabel()

    var insets = UIEdgeInsets.zero {
        didSet {
            top.constant = insets.top
            leading.constant = insets.left
            bottom.constant = -insets.bottom
            trailing.constant = -insets.right
        }
    }
    var cornerRadius: CGFloat {
        get { layer.cornerRadius }
        set { layer.cornerRadius = newValue }
    }
    var borderWidth: CGFloat {
        get { layer.borderWidth }
        set { layer.borderWidth = newValue }
    }
    var borderColor: UIColor? {
        didSet { layer.borderColor = borderColor?.cgColor }
    }

    private lazy var top = label.topAnchor.constraint(equalTo: topAnchor)
    private lazy var leading = label.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor)
    private lazy var trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        addSubview(label)
        NSLayoutConstraint.activate([top, leading, bottom, trailing])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The seven accents as dots. They grow with Dynamic Type, and at
/// accessibility sizes wrap onto a second row instead of running off the card.
private final class ThemeSwatchStrip: UIView {
    private let dots = (0..<7).map { _ in ThemeSwatchDot() }
    private let rows = UIStackView()
    private var sizes: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        rows.axis = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        for dot in dots {
            dot.translatesAutoresizingMaskIntoConstraints = false
            sizes.append(dot.widthAnchor.constraint(equalToConstant: 20))
            sizes.append(dot.heightAnchor.constraint(equalTo: dot.widthAnchor))
        }
        NSLayoutConstraint.activate(sizes)
        arrange()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.arrange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(colors: [UIColor], outline: UIColor) {
        for (dot, color) in zip(dots, colors) {
            dot.backgroundColor = color
            dot.layer.borderColor = outline.cgColor
        }
    }

    private func arrange() {
        let size = min(UIFontMetrics(forTextStyle: .body).scaledValue(for: 20, compatibleWith: traitCollection), 40)
        for constraint in sizes where constraint.firstAttribute == .width { constraint.constant = size }
        let perRow = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 4 : dots.count
        for row in rows.arrangedSubviews {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for start in stride(from: 0, to: dots.count, by: perRow) {
            let row = UIStackView(arrangedSubviews: Array(dots[start..<min(start + perRow, dots.count)]))
            row.spacing = 8
            rows.addArrangedSubview(row)
        }
    }
}

private final class ThemeSwatchDot: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }
}
