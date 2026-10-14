import UIKit

/// How the full-screen audio player lays out transcript lines.
enum AudioTranscriptStyle: Equatable {
    /// Verse lines; the current line grows.
    case lyrics
    /// Speaker turns with colored names; the current paragraph is highlighted.
    case script
}

/// Theme snapshot for the UIKit transcript. Speakers without a color use `unnamed`.
struct AudioTranscriptPalette: Equatable {
    var foreground: UIColor
    var dimmed: UIColor
    var unnamed: UIColor
    var speakerColors: [String: UIColor]

    func color(for speaker: String?) -> UIColor {
        speaker.flatMap { speakerColors[$0] } ?? unnamed
    }
}

/// Transcript pane: a self-sizing collection view, so long audiobooks only
/// reconfigure the outgoing and incoming current line per playback tick, and
/// follow-scroll lands on real cell geometry instead of height estimates.
final class AudioTranscriptCollectionView: UIView, UICollectionViewDelegate {
    var onSelectLine: ((Int) -> Void)?
    var onUserScroll: (() -> Void)?

    private var lines: [AudioLyrics.Line] = []
    private var style: AudioTranscriptStyle?
    private var palette: AudioTranscriptPalette?
    private var currentIndex: Int?
    private var followsPlayback = true
    private var pendingInitialScroll = false

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: Self.layout(for: .lyrics))
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.delegate = self
        view.accessibilityIdentifier = "audioLyrics.transcript"
        return view
    }()

    private lazy var dataSource: UICollectionViewDiffableDataSource<Int, Int> = {
        let registration = UICollectionView.CellRegistration<AudioTranscriptCell, Int> { [weak self] cell, _, index in
            self?.configure(cell, at: index)
        }
        return UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, index in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: index)
        }
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(
        lines newLines: [AudioLyrics.Line],
        style newStyle: AudioTranscriptStyle,
        palette newPalette: AudioTranscriptPalette,
        currentIndex newIndex: Int?,
        followsPlayback newFollows: Bool
    ) {
        let previousIndex = currentIndex
        let resumedFollowing = newFollows && !followsPlayback
        currentIndex = newIndex
        followsPlayback = newFollows

        if newStyle != style {
            style = newStyle
            collectionView.setCollectionViewLayout(Self.layout(for: newStyle), animated: false)
        }

        let contentChanged = newLines != lines
        if contentChanged {
            lines = newLines
            palette = newPalette
            var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
            snapshot.appendSections([0])
            snapshot.appendItems(Array(lines.indices))
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else if newPalette != palette {
            palette = newPalette
            reconfigure(collectionView.indexPathsForVisibleItems.map(\.item))
        } else if previousIndex != currentIndex {
            switch Self.repaintScope(previous: previousIndex, current: currentIndex, style: newStyle, count: lines.count) {
            case .rows(let rows):
                reconfigure(rows)
            case .all:
                reconfigure(Array(lines.indices))
            }
        }

        // New content jumps straight to the current line; playback advances and
        // "Current Line" animate. A reader who dragged away is left alone.
        guard followsPlayback, contentChanged || resumedFollowing || previousIndex != currentIndex else { return }
        if contentChanged {
            // First paint may arrive before this view has a size; scroll once it does.
            pendingInitialScroll = true
            setNeedsLayout()
            return
        }
        // Let the reconfigured rows size before measuring the target row.
        DispatchQueue.main.async { [weak self] in
            self?.scrollToCurrent(animated: true)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard pendingInitialScroll, bounds.height > 0 else { return }
        pendingInitialScroll = false
        scrollToCurrent(animated: false)
    }

    // MARK: - Layout

    private static func layout(for style: AudioTranscriptStyle) -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        switch style {
        case .lyrics:
            section.interGroupSpacing = 28
            section.contentInsets = NSDirectionalEdgeInsets(top: 36, leading: 28, bottom: 36, trailing: 28)
        case .script:
            section.interGroupSpacing = 6
            section.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 14)
        }
        return UICollectionViewCompositionalLayout(section: section)
    }

    enum RepaintScope: Equatable {
        case rows([Int])
        case all
    }

    /// Rows whose paint depends on the current line. Lyrics style only the current
    /// line and its neighbors. Scripts color every row as heard or upcoming, so only a
    /// one-line step stays local; play, stop, seek, and skip repaint everything.
    nonisolated static func repaintScope(
        previous: Int?,
        current: Int?,
        style: AudioTranscriptStyle,
        count: Int
    ) -> RepaintScope {
        switch style {
        case .script:
            guard let previous, let current, abs(previous - current) <= 1 else { return .all }
            return .rows(Array(Set([previous, current])).sorted())
        case .lyrics:
            var items = Set<Int>()
            for center in [previous, current].compactMap({ $0 }) {
                for index in (center - 1)...(center + 1) where index >= 0 && index < count {
                    items.insert(index)
                }
            }
            return .rows(items.sorted())
        }
    }

    private func reconfigure(_ items: [Int]) {
        guard !items.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        // Lyrics resize the current line, so let self-sizing animate the change.
        dataSource.apply(snapshot, animatingDifferences: style == .lyrics && window != nil)
    }

    private func scrollToCurrent(animated: Bool) {
        // A drag that landed after this scroll was queued wins.
        guard followsPlayback, let currentIndex, lines.indices.contains(currentIndex), bounds.height > 0 else { return }
        let indexPath = IndexPath(item: currentIndex, section: 0)
        collectionView.layoutIfNeeded()
        // A distant row's origin is the sum of estimated heights. Land on it until it is
        // on screen and self-sizing stops moving it, then anchor on that measured frame.
        var isNear = collectionView.indexPathsForVisibleItems.contains(indexPath)
        var settledMinY: CGFloat?
        for _ in 0..<8 {
            guard let minY = collectionView.layoutAttributesForItem(at: indexPath)?.frame.minY else { return }
            if collectionView.indexPathsForVisibleItems.contains(indexPath), minY == settledMinY { break }
            settledMinY = minY
            if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
                isNear = false
                collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            }
            collectionView.layoutIfNeeded()
        }
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let viewport = collectionView.bounds.height
        let anchor: CGFloat = style == .script ? 0.35 : 0.5
        // A paragraph taller than half the screen starts near the top instead of centering.
        let target = frame.height > viewport * 0.5
            ? frame.minY - viewport * 0.15
            : frame.midY - viewport * anchor
        let inset = collectionView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, collectionView.contentSize.height - viewport + inset.bottom)
        let offset = CGPoint(x: 0, y: min(maxY, max(minY, target)))
        guard abs(collectionView.contentOffset.y - offset.y) > 0.5 else { return }
        collectionView.setContentOffset(offset, animated: animated && isNear)
    }

    // MARK: - Cells

    private func configure(_ cell: AudioTranscriptCell, at index: Int) {
        guard lines.indices.contains(index), let style, let palette else { return }
        let line = lines[index]
        cell.apply(AudioTranscriptCell.Content(
            text: line.text,
            speaker: line.speaker,
            startsTurn: style == .script && AudioReaderCast.startsTurn(lines, at: index),
            isTimed: line.startTime != nil,
            distanceFromCurrent: currentIndex.map { index - $0 },
            style: style,
            accent: palette.color(for: line.speaker),
            palette: palette,
            isFirst: index == 0
        ))
        cell.accessibilityIdentifier = "audioLyrics.line.\(index)"
    }

    // MARK: - UICollectionViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onUserScroll?()
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        lines.indices.contains(indexPath.item) && lines[indexPath.item].startTime != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard lines.indices.contains(indexPath.item), lines[indexPath.item].startTime != nil else { return }
        onSelectLine?(indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let index = indexPaths.first?.item, lines.indices.contains(index) else { return nil }
        let line = lines[index]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if line.startTime != nil {
                actions.append(UIAction(
                    title: String(localized: "Play from Here"),
                    image: UIImage(systemName: "play")
                ) { _ in
                    self?.onSelectLine?(index)
                })
            }
            actions.append(UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = line.speaker.map { "\($0): \(line.text)" } ?? line.text
            })
            return UIMenu(children: actions)
        }
    }
}

final class AudioTranscriptCell: UICollectionViewCell {
    struct Content {
        var text: String
        var speaker: String?
        var startsTurn: Bool
        var isTimed: Bool
        /// `nil` when nothing is playing; negative for lines already heard.
        var distanceFromCurrent: Int?
        var style: AudioTranscriptStyle
        var accent: UIColor
        var palette: AudioTranscriptPalette
        var isFirst: Bool
    }

    private let speakerLabel = UILabel()
    private let bodyLabel = UILabel()
    private let stack = UIStackView()
    private let currentBar = UIView()
    private var stackLeading: NSLayoutConstraint?
    private var stackTrailing: NSLayoutConstraint?
    private var stackTop: NSLayoutConstraint?
    private var stackBottom: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.layer.cornerCurve = .continuous

        speakerLabel.adjustsFontForContentSizeCategory = true
        speakerLabel.font = Self.font(.subheadline, size: 15, weight: .semibold)
        bodyLabel.numberOfLines = 0
        bodyLabel.adjustsFontForContentSizeCategory = true

        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.addArrangedSubview(speakerLabel)
        stack.addArrangedSubview(bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        currentBar.layer.cornerRadius = 1.5
        currentBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(currentBar)

        let leading = stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let trailing = contentView.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        let top = stack.topAnchor.constraint(equalTo: contentView.topAnchor)
        let bottom = contentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor)
        bottom.priority = .init(999)
        stackLeading = leading
        stackTrailing = trailing
        stackTop = top
        stackBottom = bottom
        NSLayoutConstraint.activate([
            leading, trailing, top, bottom,
            currentBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            currentBar.widthAnchor.constraint(equalToConstant: 3),
            currentBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            contentView.bottomAnchor.constraint(equalTo: currentBar.bottomAnchor, constant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { stack.alpha = isHighlighted ? 0.55 : 1 }
    }

    func apply(_ content: Content) {
        let isCurrent = content.distanceFromCurrent == 0
        let palette = content.palette
        bodyLabel.text = content.text

        switch content.style {
        case .lyrics:
            speakerLabel.isHidden = true
            currentBar.isHidden = true
            contentView.backgroundColor = .clear
            setInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
            bodyLabel.font = isCurrent
                ? Self.font(.title1, size: 28, weight: .semibold)
                : Self.font(.title2, size: 22, weight: .regular)
            let isNeighbor = content.distanceFromCurrent.map { abs($0) == 1 } ?? false
            bodyLabel.textColor = isCurrent
                ? palette.foreground
                : palette.dimmed.withAlphaComponent(isNeighbor ? 0.85 : 0.55)

        case .script:
            let showsSpeaker = content.startsTurn && content.speaker != nil
            speakerLabel.isHidden = !showsSpeaker
            speakerLabel.text = content.speaker
            speakerLabel.textColor = content.accent
            currentBar.isHidden = !isCurrent
            currentBar.backgroundColor = content.accent
            contentView.backgroundColor = isCurrent ? content.accent.withAlphaComponent(0.12) : .clear
            setInsets(top: showsSpeaker && !content.isFirst ? 18 : 8, leading: 15, bottom: 8, trailing: 12)
            bodyLabel.font = Self.font(.title3, size: 20, weight: .regular)
            bodyLabel.textColor = switch content.distanceFromCurrent {
            case nil, 0?: palette.foreground
            case let distance? where distance < 0: palette.dimmed
            default: palette.foreground.withAlphaComponent(0.78)
            }
        }

        isAccessibilityElement = true
        accessibilityLabel = content.speaker.map { "\($0), \(content.text)" } ?? content.text
        var traits: UIAccessibilityTraits = content.isTimed ? .button : .staticText
        if isCurrent { traits.insert(.selected) }
        accessibilityTraits = traits
    }

    private func setInsets(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        stackTop?.constant = top
        stackLeading?.constant = leading
        stackBottom?.constant = bottom
        stackTrailing?.constant = trailing
    }

    private static func font(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }
}
