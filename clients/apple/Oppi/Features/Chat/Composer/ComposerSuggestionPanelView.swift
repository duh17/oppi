import UIKit

/// Rounded @file / slash-command panel. Looks like the previous SwiftUI list:
/// dark fill, 12pt continuous corners, 260pt cap, hairline dividers, whole-row tap.
final class ComposerSuggestionPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    enum Content {
        case files([FileSuggestion])
        case slash([SlashCommand])
        case empty
    }

    var onSelectFile: ((FileSuggestion) -> Void)?
    var onSelectSlash: ((SlashCommand) -> Void)?
    var onHeightChange: (() -> Void)?
    var measuredHeight: CGFloat { isHidden ? 0 : heightConstraint?.constant ?? 0 }

    private let maxPanelHeight: CGFloat = 260
    private let panelCornerRadius: CGFloat = 12
    private var content: Content = .empty
    private var colors = ComposerThemeColors.placeholder
    private var heightConstraint: NSLayoutConstraint?
    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(52)
                )
            )
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(52)
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            return section
        }
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = false
        view.dataSource = self
        view.delegate = self
        view.register(ComposerSuggestionCell.self, forCellWithReuseIdentifier: ComposerSuggestionCell.reuseID)
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = panelCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        let height = heightAnchor.constraint(equalToConstant: 0)
        height.priority = .required
        heightConstraint = height
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(content: Content, colors: ComposerThemeColors) {
        self.content = content
        self.colors = colors
        backgroundColor = colors.bgDark
        layer.borderColor = colors.comment.withAlphaComponent(0.22).cgColor
        collectionView.reloadData()
        let count: Int
        switch content {
        case .files(let items): count = items.count
        case .slash(let items): count = items.count
        case .empty: count = 0
        }
        collectionView.showsVerticalScrollIndicator = count > 5
        setHiddenIfChanged(count == 0)
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
        let fallback: CGFloat = count == 0 ? 0 : CGFloat(count) * 52
        let measured = contentHeight > 1 ? contentHeight : fallback
        let height = min(measured, maxPanelHeight)
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
            onHeightChange?()
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch content {
        case .files(let items): return items.count
        case .slash(let items): return items.count
        case .empty: return 0
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ComposerSuggestionCell.reuseID,
            for: indexPath
        ) as? ComposerSuggestionCell ?? ComposerSuggestionCell()
        let isLast: Bool
        switch content {
        case .files(let items):
            isLast = indexPath.item == items.count - 1
            cell.applyFile(items[indexPath.item], colors: colors, showsDivider: !isLast)
        case .slash(let items):
            isLast = indexPath.item == items.count - 1
            cell.applySlash(items[indexPath.item], colors: colors, showsDivider: !isLast)
        case .empty:
            break
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch content {
        case .files(let items):
            onSelectFile?(items[indexPath.item])
        case .slash(let items):
            onSelectSlash?(items[indexPath.item])
        case .empty:
            break
        }
    }
}

private final class ComposerSuggestionCell: UICollectionViewCell {
    static let reuseID = "composer.suggestion"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let trailingLabel = UILabel()
    private let divider = UIView()
    private let textStack = UIStackView()
    private let titleRow = UIStackView()
    private let hitTarget = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(trailingLabel)
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleRow)
        textStack.addArrangedSubview(subtitleLabel)
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        let row = UIStackView(arrangedSubviews: [iconView, textStack])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        hitTarget.translatesAutoresizingMaskIntoConstraints = false
        hitTarget.accessibilityTraits.insert(.button)
        hitTarget.addAction(UIAction { [weak self] _ in self?.forwardSelection() }, for: .touchUpInside)
        contentView.addSubview(hitTarget)
        contentView.addSubview(row)
        contentView.addSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hitTarget.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hitTarget.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hitTarget.topAnchor.constraint(equalTo: contentView.topAnchor),
            hitTarget.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
        ])
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func forwardSelection() {
        var view: UIView? = self
        while let current = view {
            if let collection = current as? UICollectionView, let indexPath = collection.indexPath(for: self) {
                collection.delegate?.collectionView?(collection, didSelectItemAt: indexPath)
                return
            }
            view = current.superview
        }
    }

    func applyFile(_ suggestion: FileSuggestion, colors: ComposerThemeColors, showsDivider: Bool) {
        trailingLabel.setHiddenIfChanged(true)
        subtitleLabel.setHiddenIfChanged(suggestion.parentPath == nil)
        subtitleLabel.text = suggestion.parentPath
        subtitleLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        subtitleLabel.textColor = colors.comment
        if suggestion.isDirectory {
            iconView.image = FileIcon(symbolName: "folder.fill", tint: .yellow)
                .uiImage(pointSize: 11, weight: .medium)
        } else {
            iconView.image = FileIcon.forPath(suggestion.path).uiImage(pointSize: 11, weight: .medium)
        }
        if suggestion.matchPositions.isEmpty {
            titleLabel.attributedText = nil
            titleLabel.text = suggestion.displayName
            titleLabel.font = UIFont.monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .medium
            )
            titleLabel.textColor = colors.fg
        } else {
            titleLabel.text = nil
            titleLabel.attributedText = ComposerSuggestionHighlight.attributedFilename(
                path: suggestion.path,
                matchPositions: suggestion.matchPositions,
                isDirectory: suggestion.isDirectory,
                matchColor: colors.yellow,
                restColor: colors.fgDim
            )
        }
        divider.backgroundColor = colors.comment.withAlphaComponent(0.18)
        divider.setHiddenIfChanged(!showsDivider)
        hitTarget.accessibilityLabel = suggestion.displayName
    }

    func applySlash(_ command: SlashCommand, colors: ComposerThemeColors, showsDivider: Bool) {
        trailingLabel.setHiddenIfChanged(false)
        let iconColor: UIColor
        switch command.source {
        case .builtin: iconColor = colors.blue
        case .extension: iconColor = colors.purple
        case .prompt: iconColor = colors.green
        case .skill: iconColor = colors.yellow
        }
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.image = UIImage(systemName: command.source.iconName, withConfiguration: config)?
            .withTintColor(iconColor, renderingMode: .alwaysOriginal)
        titleLabel.attributedText = nil
        titleLabel.text = command.invocation
        titleLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .medium
        )
        titleLabel.textColor = colors.blue
        trailingLabel.text = command.source.label
        trailingLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        trailingLabel.textColor = colors.comment
        if let description = command.description {
            subtitleLabel.setHiddenIfChanged(false)
            subtitleLabel.text = description
            subtitleLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
            subtitleLabel.textColor = colors.comment
        } else {
            subtitleLabel.setHiddenIfChanged(true)
            subtitleLabel.text = nil
        }
        divider.backgroundColor = colors.comment.withAlphaComponent(0.18)
        divider.setHiddenIfChanged(!showsDivider)
        hitTarget.accessibilityLabel = command.invocation
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.72 : 1 }
    }
}

enum ComposerSuggestionHighlight {
    static func attributedFilename(
        path: String,
        matchPositions: [Int],
        isDirectory: Bool,
        matchColor: UIColor,
        restColor: UIColor
    ) -> NSAttributedString {
        let normalizedPath = (isDirectory && path.hasSuffix("/")) ? String(path.dropLast()) : path
        let scalars = Array(normalizedPath.unicodeScalars)
        let filenameOffset: Int
        if let lastSlash = scalars.lastIndex(of: "/") {
            filenameOffset = lastSlash + 1
        } else {
            filenameOffset = 0
        }
        let filenameScalars = Array(scalars[filenameOffset...])
        let matchSet = Set(matchPositions.compactMap { pos -> Int? in
            let adjusted = pos - filenameOffset
            guard adjusted >= 0, adjusted < filenameScalars.count else { return nil }
            return adjusted
        })
        let matchFont = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .bold
        )
        let restFont = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        let result = NSMutableAttributedString()
        var i = 0
        while i < filenameScalars.count {
            if matchSet.contains(i) {
                var end = i
                while end + 1 < filenameScalars.count, matchSet.contains(end + 1) {
                    end += 1
                }
                result.append(NSAttributedString(
                    string: String(String.UnicodeScalarView(filenameScalars[i...end])),
                    attributes: [.foregroundColor: matchColor, .font: matchFont]
                ))
                i = end + 1
            } else {
                var end = i
                while end + 1 < filenameScalars.count, !matchSet.contains(end + 1) {
                    end += 1
                }
                result.append(NSAttributedString(
                    string: String(String.UnicodeScalarView(filenameScalars[i...end])),
                    attributes: [.foregroundColor: restColor, .font: restFont]
                ))
                i = end + 1
            }
        }
        return result
    }
}
