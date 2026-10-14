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
    /// Stage-direction tags on lines without a speaker color.
    var direction: UIColor

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
    private var markups: [AudioLineMarkup] = []
    private var style: AudioTranscriptStyle?
    private var palette: AudioTranscriptPalette?
    private var currentIndex: Int?
    /// Spoken-word sweep through the current line, 0...1; `nil` when its end is unknown.
    private var currentProgress: Double?
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
        currentProgress newProgress: Double?,
        followsPlayback newFollows: Bool
    ) {
        let previousIndex = currentIndex
        let previousProgress = currentProgress
        let resumedFollowing = newFollows && !followsPlayback
        currentIndex = newIndex
        currentProgress = newProgress
        followsPlayback = newFollows

        if newStyle != style {
            style = newStyle
            collectionView.setCollectionViewLayout(Self.layout(for: newStyle), animated: false)
        }

        let contentChanged = newLines != lines
        if contentChanged {
            lines = newLines
            markups = newLines.map { AudioLineMarkup($0.text) }
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
        if !contentChanged, previousIndex == newIndex, previousProgress != newProgress {
            currentCell()?.updateProgress(newProgress)
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

    /// Per-tick sweep update: repaints only the visible current line, without a snapshot pass.
    func updateProgress(_ progress: Double?) {
        guard progress != currentProgress else { return }
        currentProgress = progress
        currentCell()?.updateProgress(progress)
    }

    private func currentCell() -> AudioTranscriptCell? {
        guard let currentIndex else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? AudioTranscriptCell
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
        guard lines.indices.contains(index), markups.indices.contains(index), let style, let palette else { return }
        let line = lines[index]
        cell.apply(AudioTranscriptCell.Content(
            text: line.text,
            markup: markups[index],
            progress: index == currentIndex ? currentProgress : nil,
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

    /// A prefetched current line was configured at an earlier sweep; catch it up as it
    /// appears, which matters once playback has paused and ticks stop.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.item == currentIndex, let cell = cell as? AudioTranscriptCell else { return }
        cell.updateProgress(currentProgress)
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
        var markup: AudioLineMarkup
        /// Sweep through the current line; `nil` for other lines or an unknown end.
        var progress: Double?
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
    private var content: Content?
    private var body: BodyStyle?
    private var renderedSpokenCount: Int?

    /// How the body text paints: base color, and on the current line the faded color
    /// for words the sweep has not reached.
    private struct BodyStyle {
        var font: UIFont
        var color: UIColor
        var upcoming: UIColor?
        var tagTint: UIColor
    }

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
        // Words the sweep has not reached fade back toward the line's base color.
        let upcoming = isCurrent && content.progress != nil ? palette.foreground.withAlphaComponent(0.42) : nil
        let tagTint = content.speaker.flatMap { palette.speakerColors[$0] } ?? palette.direction

        switch content.style {
        case .lyrics:
            speakerLabel.isHidden = true
            currentBar.isHidden = true
            contentView.backgroundColor = .clear
            setInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
            let isNeighbor = content.distanceFromCurrent.map { abs($0) == 1 } ?? false
            body = BodyStyle(
                font: isCurrent
                    ? Self.font(.title1, size: 28, weight: .semibold)
                    : Self.font(.title2, size: 22, weight: .regular),
                color: isCurrent
                    ? palette.foreground
                    : palette.dimmed.withAlphaComponent(isNeighbor ? 0.85 : 0.55),
                upcoming: upcoming,
                tagTint: isCurrent ? tagTint : tagTint.withAlphaComponent(isNeighbor ? 0.8 : 0.55)
            )

        case .script:
            let showsSpeaker = content.startsTurn && content.speaker != nil
            speakerLabel.isHidden = !showsSpeaker
            speakerLabel.text = content.speaker
            speakerLabel.textColor = content.accent
            currentBar.isHidden = !isCurrent
            currentBar.backgroundColor = content.accent
            contentView.backgroundColor = isCurrent ? content.accent.withAlphaComponent(0.12) : .clear
            setInsets(top: showsSpeaker && !content.isFirst ? 18 : 8, leading: 15, bottom: 8, trailing: 12)
            let isHeard = content.distanceFromCurrent.map { $0 < 0 } ?? false
            let color: UIColor = switch content.distanceFromCurrent {
            case nil, 0?: palette.foreground
            case let distance? where distance < 0: palette.dimmed
            default: palette.foreground.withAlphaComponent(0.78)
            }
            body = BodyStyle(
                font: Self.font(.title3, size: 20, weight: .regular),
                color: color,
                upcoming: upcoming,
                tagTint: isHeard ? tagTint.withAlphaComponent(0.7) : tagTint
            )
        }
        self.content = content
        renderedSpokenCount = nil
        renderBody(animated: false)

        isAccessibilityElement = true
        accessibilityLabel = content.speaker.map { "\($0), \(content.text)" } ?? content.text
        var traits: UIAccessibilityTraits = content.isTimed ? .button : .staticText
        if isCurrent { traits.insert(.selected) }
        accessibilityTraits = traits
    }

    /// Moves the sweep; repaints only when another word lights up.
    func updateProgress(_ progress: Double?) {
        guard var content, content.distanceFromCurrent == 0 else { return }
        let hadSweep = content.progress != nil
        content.progress = progress
        if hadSweep != (progress != nil) {
            apply(content)
            return
        }
        self.content = content
        renderBody(animated: true)
    }

    private func renderBody(animated: Bool) {
        guard let content, let body else { return }
        let spokenCount = body.upcoming == nil
            ? content.markup.words.count
            : content.markup.spokenWordCount(at: content.progress ?? 1)
        guard spokenCount != renderedSpokenCount else { return }
        renderedSpokenCount = spokenCount
        let text = Self.attributedBody(content.markup, spokenCount: spokenCount, style: body)
        if animated, window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: bodyLabel, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.bodyLabel.attributedText = text
            }
        } else {
            bodyLabel.attributedText = text
        }
    }

    /// Spoken text before the sweep boundary takes the base color, the rest the faded
    /// color; stage directions become inline tags.
    private static func attributedBody(_ markup: AudioLineMarkup, spokenCount: Int, style: BodyStyle) -> NSAttributedString {
        let boundary = markup.words.indices.contains(spokenCount) ? markup.words[spokenCount] : nil
        let result = NSMutableAttributedString()
        for (index, segment) in markup.segments.enumerated() {
            switch segment {
            case .direction(let text):
                result.append(AudioDirectionTag.attachment(text, tint: style.tagTint, bodyFont: style.font))
            case .spoken(let text):
                let string = text as NSString
                let split: Int = switch boundary {
                case nil: string.length
                case let word? where index < word.segment: string.length
                case let word? where index == word.segment: word.range.location
                default: 0
                }
                let upcoming = style.upcoming ?? style.color
                if split > 0 {
                    result.append(NSAttributedString(
                        string: string.substring(to: split),
                        attributes: [.font: style.font, .foregroundColor: style.color]
                    ))
                }
                if split < string.length {
                    result.append(NSAttributedString(
                        string: string.substring(from: split),
                        attributes: [.font: style.font, .foregroundColor: upcoming]
                    ))
                }
            }
        }
        return result
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

/// Inline stage-direction tag (`[laughs]` → a small tinted capsule) drawn as a text
/// attachment, so it wraps with the line and sits on its text center.
enum AudioDirectionTag {
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    @MainActor
    static func attachment(_ text: String, tint: UIColor, bodyFont: UIFont) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: (bodyFont.pointSize * 0.62).rounded(), weight: .medium)
        let image = image(text, tint: tint, font: font)
        let attachment = NSTextAttachment(image: image)
        // Center the capsule on the body text's x-height.
        let y = (bodyFont.capHeight - image.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: y.rounded(), width: image.size.width, height: image.size.height)
        let tag = NSMutableAttributedString(attachment: attachment)
        tag.addAttribute(.font, value: bodyFont, range: NSRange(location: 0, length: tag.length))
        return tag
    }

    @MainActor
    private static func image(_ text: String, tint: UIColor, font: UIFont) -> UIImage {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let key = "\(text)|\(font.pointSize)|\(red),\(green),\(blue),\(alpha)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: tint])
        let textSize = label.size()
        let margin: CGFloat = 3
        let padding = CGSize(width: 7, height: 2.5)
        let capsule = CGRect(
            x: margin,
            y: 0,
            width: ceil(textSize.width) + padding.width * 2,
            height: ceil(textSize.height) + padding.height * 2
        )
        let size = CGSize(width: capsule.maxX + margin, height: capsule.height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let path = UIBezierPath(roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
            tint.withAlphaComponent(0.16 * alpha).setFill()
            path.fill()
            tint.withAlphaComponent(0.35 * alpha).setStroke()
            path.lineWidth = 1
            path.stroke()
            label.draw(at: CGPoint(x: capsule.minX + padding.width, y: padding.height))
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
