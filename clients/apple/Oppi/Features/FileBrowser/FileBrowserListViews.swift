import UIKit

/// The breadcrumb row of `FileBrowserViewController`: the root label, then
/// each folder down to the current one. An ancestor jumps back to that
/// folder. The row scrolls sideways and shows the current folder first.
final class FileBrowserBreadcrumbCell: UICollectionViewListCell {
    struct Segment: Equatable {
        let label: String
        let depth: Int
    }

    private let scrollView = UIScrollView()
    /// Buttons and the chevrons between them, laid out by hand at their
    /// natural widths from the leading edge.
    private var pieces: [UIView] = []
    private var shown: [Segment] = []
    private var shownDepth = -1
    private var needsScrollToEnd = false
    private var insetConstraints: [NSLayoutConstraint] = []
    private let heightConstraint: NSLayoutConstraint
    private var onNavigate: ((Int) -> Void)?

    private static let spacing: CGFloat = 2
    private static let verticalPadding: CGFloat = 2

    override init(frame: CGRect) {
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        insetConstraints = [
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ]
        // Below required so the list's fitting height never conflicts.
        heightConstraint.priority = .init(999)
        NSLayoutConstraint.activate(insetConstraints + [heightConstraint])
        // The path is navigation, not one element.
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        segments: [Segment],
        currentDepth: Int,
        insets: NSDirectionalEdgeInsets,
        palette: ThemePalette,
        onNavigate: @escaping (Int) -> Void
    ) {
        self.onNavigate = onNavigate
        insetConstraints[0].constant = insets.top
        insetConstraints[1].constant = insets.leading
        insetConstraints[2].constant = insets.trailing
        insetConstraints[3].constant = insets.bottom
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
        guard segments != shown || currentDepth != shownDepth else {
            // Same path: a theme change still recolors it.
            applyColors(palette)
            return
        }
        shown = segments
        shownDepth = currentDepth
        for view in pieces {
            view.removeFromSuperview()
        }
        pieces = []
        var buttons: [UIButton] = []
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let chevron = UIImageView(image: UIImage(
                    systemName: "chevron.right",
                    withConfiguration: UIImage.SymbolConfiguration(font: Self.font(.caption2, .semibold))
                ))
                chevron.contentMode = .center
                chevron.isAccessibilityElement = false
                scrollView.addSubview(chevron)
                pieces.append(chevron)
            }
            let isCurrent = segment.depth == currentDepth
            var configuration = UIButton.Configuration.plain()
            var title = AttributedString(segment.label)
            title.font = Self.font(.caption1, isCurrent ? .semibold : .medium)
            configuration.attributedTitle = title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            let depth = segment.depth
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                guard depth < currentDepth else { return }
                self?.onNavigate?(depth)
            })
            scrollView.addSubview(button)
            pieces.append(button)
            buttons.append(button)
        }
        accessibilityElements = buttons
        applyColors(palette)
        heightConstraint.constant = (pieces.map { $0.intrinsicContentSize.height }.max() ?? 0)
            + Self.verticalPadding * 2
        needsScrollToEnd = true
        setNeedsLayout()
    }

    /// The current folder in the theme's blue, ancestors and chevrons in its
    /// comment color.
    private func applyColors(_ palette: ThemePalette) {
        let current = UIColor(palette.blue)
        let ancestor = UIColor(palette.comment)
        let chevron = ancestor.withAlphaComponent(0.5)
        var segmentIndex = 0
        for piece in pieces {
            if let image = piece as? UIImageView {
                image.tintColor = chevron
                continue
            }
            guard let button = piece as? UIButton, var configuration = button.configuration,
                  shown.indices.contains(segmentIndex) else { continue }
            let isCurrent = shown[segmentIndex].depth == shownDepth
            segmentIndex += 1
            configuration.attributedTitle?.foregroundColor = isCurrent ? current : ancestor
            button.configuration = configuration
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The scroll view's frame first: Auto Layout sets it in the content
        // view's pass, after this one.
        contentView.layoutIfNeeded()
        let height = scrollView.bounds.height
        var x: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            let size = piece.intrinsicContentSize
            if index > 0 { x += Self.spacing }
            piece.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width
        }
        scrollView.contentSize = CGSize(width: x, height: height)
        guard needsScrollToEnd, scrollView.bounds.width > 0 else { return }
        needsScrollToEnd = false
        // The current folder, at the end, stays in view.
        scrollView.contentOffset = CGPoint(x: max(0, x - scrollView.bounds.width), y: 0)
    }

    static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
            .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// The search field at the top of the tree column (regular width), where the
/// navigation bar's search would sit above the open file instead.
final class FileBrowserColumnSearchField: UIView {
    let textField = UITextField()
    /// The clear button emptied the field.
    var onClear: (() -> Void)?
    private let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let clearButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        textField.placeholder = String(localized: "Search files")
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .search
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.addAction(UIAction { [weak self] _ in self?.syncClearButton() }, for: .editingChanged)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false
        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.accessibilityLabel = String(localized: "Clear file search")
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            textField.text = ""
            syncClearButton()
            onClear?()
        }, for: .primaryActionTriggered)
        let row = UIStackView(arrangedSubviews: [icon, textField, clearButton])
        row.axis = .horizontal
        row.spacing = 8
        // The text field's natural height sets the row's, so the field keeps
        // it and the list below takes the rest of the column.
        row.alignment = .fill
        textField.setContentHuggingPriority(.required, for: .vertical)
        textField.setContentCompressionResistancePriority(.required, for: .vertical)
        icon.contentMode = .center
        for view in [icon, clearButton] {
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        syncClearButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The screen's search text, without echoing back as an edit.
    func setText(_ text: String) {
        guard (textField.text ?? "") != text else { return }
        textField.text = text
        syncClearButton()
    }

    func apply(_ palette: ThemePalette) {
        let comment = UIColor(palette.comment)
        icon.tintColor = comment
        clearButton.tintColor = comment
        textField.textColor = UIColor(palette.fg)
        textField.attributedPlaceholder = NSAttributedString(
            string: String(localized: "Search files"),
            attributes: [.foregroundColor: comment]
        )
    }

    private func syncClearButton() {
        clearButton.isHidden = (textField.text ?? "").isEmpty
    }
}
