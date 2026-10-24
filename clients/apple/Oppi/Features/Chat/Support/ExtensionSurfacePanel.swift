import UIKit

enum ExtensionStripPillMetrics {
    static let visualHeight: CGFloat = 36
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 8
}

enum ExtensionNativeSurfaceLayout {
    static let expandedMaxHeight: CGFloat = 260
}

// MARK: - Surfaces

/// The `.elevatedPanel` themed surface behind a strip pill (capsule) or a
/// drawer (rounded, with the panel shadow): Liquid Glass, the role's fill over
/// it, its hairline, and an optional active stroke. Paints only; put it behind
/// the content and pin it to the content's edges.
final class ElevatedSurfaceView: UIView {
    enum Shape {
        case capsule
        case rounded(CGFloat)
    }

    private let shape: Shape
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let activeStroke = CAShapeLayer()

    /// Drawers cast the panel shadow; pills do not.
    init(shape: Shape, castsShadow: Bool = false) {
        self.shape = shape
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        activeStroke.fillColor = UIColor.clear.cgColor
        activeStroke.lineWidth = 1
        layer.addSublayer(activeStroke)
        if castsShadow {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 0, height: 2)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `active` strokes the shape at 45% over the hairline (an expanded pill).
    func apply(palette: ThemePalette, active: UIColor? = nil) {
        let style = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        glass.contentView.backgroundColor = UIColor(style.fill)
        glass.layer.borderColor = style.stroke.map { UIColor($0).cgColor }
        glass.layer.borderWidth = style.strokeLineWidth
        activeStroke.strokeColor = active?.withAlphaComponent(0.45).cgColor
        activeStroke.isHidden = active == nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius: CGFloat = switch shape {
        case .capsule: bounds.height / 2
        case .rounded(let radius): radius
        }
        glass.layer.cornerRadius = radius
        glass.layer.cornerCurve = .continuous
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: radius)
        activeStroke.path = path.cgPath
        activeStroke.frame = bounds
        if layer.shadowOpacity > 0 {
            layer.shadowPath = path.cgPath
        }
    }
}

/// A drawer under the strip: the glass panel with the panel shadow, and its
/// content in a column 12pt in from every edge.
class ExtensionDrawerPanelView: UIView {
    let surface = ElevatedSurfaceView(shape: .rounded(18), castsShadow: true)
    let stack = UIStackView()

    init(spacing: CGFloat) {
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = spacing
        for view in [surface, stack] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// A drawer body that hugs its content up to `maxHeight` and scrolls past it.
/// The height is all constraints, so a drawer measures in one pass.
final class CappedScrollView: UIView {
    let scrollView = UIScrollView()

    init(content: UIView, maxHeight: CGFloat) {
        super.init(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        // Below the content's own compression resistance: the viewport hugs
        // the content, never squeezes it.
        let hug = scrollView.frameLayoutGuide.heightAnchor.constraint(equalTo: content.heightAnchor)
        hug.priority = .defaultLow - 1
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            scrollView.frameLayoutGuide.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight),
            hug,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let canScroll = scrollView.contentSize.height > scrollView.bounds.height + 0.5
        scrollView.isScrollEnabled = canScroll
        scrollView.alwaysBounceVertical = canScroll
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        if scrollView.contentOffset.y > maxOffset + 0.5 {
            scrollView.contentOffset.y = maxOffset
        }
    }
}

/// Labels for the strip and drawers, scaled for Dynamic Type.
@MainActor
enum ExtensionChromeFont {
    static func label(
        _ style: UIFont.TextStyle,
        _ weight: UIFont.Weight = .regular,
        lines: Int = 1
    ) -> UILabel {
        let label = UILabel()
        label.font = .scaled(style, weight)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = lines
        return label
    }
}

/// A capsule strip pill: content in a row over the pill surface, at least
/// `ExtensionStripPillMetrics.visualHeight` tall.
class ExtensionStripPillControl: UIControl {
    let row = UIStackView()
    let surface = ElevatedSurfaceView(shape: .capsule)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 7
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let metrics = ExtensionStripPillMetrics.self
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.horizontalPadding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.horizontalPadding),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: metrics.verticalPadding),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.visualHeight),
        ])
        let fit = row.topAnchor.constraint(equalTo: topAnchor, constant: metrics.verticalPadding)
        fit.priority = .defaultHigh
        fit.isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addAction(UIAction { [weak self] _ in self?.dimForPress() }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            addAction(UIAction { [weak self] _ in self?.alpha = 1 }, for: event)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func dimForPress() {
        alpha = 0.7
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}

// MARK: - Strip entries

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var extensionSurfaceWords: [String] {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func hasExtensionSurfaceWordPrefix(_ prefix: String) -> Bool {
        let words = extensionSurfaceWords
        let prefixWords = prefix.extensionSurfaceWords
        guard !words.isEmpty, !prefixWords.isEmpty, words.count >= prefixWords.count else {
            return false
        }
        return Array(words.prefix(prefixWords.count)) == prefixWords
    }

    var extensionAccessibilityIdentifierComponent: String {
        let raw = lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(raw)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "widget" : collapsed
    }
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? { self?.trimmedNonEmpty }
}

private struct ExtensionSurfaceHeaderText {
    let title: String
    let subtitle: String?

    init(title rawTitle: String, statusText rawStatusText: String?) {
        let title = rawTitle.trimmedNonEmpty ?? "Extension"
        guard let statusText = rawStatusText.trimmedNonEmpty else {
            self.title = title
            self.subtitle = nil
            return
        }
        if statusText.hasExtensionSurfaceWordPrefix(title) {
            self.title = statusText
            self.subtitle = nil
        } else {
            self.title = title
            self.subtitle = statusText
        }
    }
}

private enum ExtensionSurfaceStripEntry: Equatable {
    case title(String)
    case status(id: String, key: String, text: String)
    case native(ExtensionNativeSurfaceState, statusText: String?)
    case widget(ExtensionWidgetState, statusText: String?, titleOverride: String?)
    case messageQueue(steeringCount: Int, followUpCount: Int, photoCount: Int, fileCount: Int)

    var id: String {
        switch self {
        case .title: "title"
        case .status(let id, _, _): "status:\(id)"
        case .native(let nativeSurface, _): "native:\(nativeSurface.key)"
        case .widget(let widget, _, _): "widget:\(widget.key)"
        case .messageQueue: "message-queue"
        }
    }

    var title: String {
        switch self {
        case .title(let title):
            return title
        case .status(_, let key, _):
            return key
        case .native(let nativeSurface, _):
            let title = nativeSurface.surface.presentation.title?.trimmedNonEmpty
            return title ?? nativeSurface.key.trimmedNonEmpty ?? "Extension"
        case .widget(let widget, let statusText, let titleOverride):
            let rawTitle = titleOverride?.trimmedNonEmpty ?? widget.key.trimmedNonEmpty ?? "Extension widget"
            return ExtensionSurfaceHeaderText(title: rawTitle, statusText: statusText).title
        case .messageQueue:
            return "Message Queue"
        }
    }

    var subtitle: String? {
        switch self {
        case .title:
            return nil
        case .status(_, _, let text):
            return text.trimmedNonEmpty
        case .native(let nativeSurface, let statusText):
            return statusText?.trimmedNonEmpty
                ?? nativeSurface.surface.presentation.subtitle?.trimmedNonEmpty
                ?? Self.nativePreviewText(nativeSurface.surface)
        case .widget(let widget, let statusText, let titleOverride):
            let rawTitle = titleOverride?.trimmedNonEmpty ?? widget.key.trimmedNonEmpty ?? "Extension widget"
            let header = ExtensionSurfaceHeaderText(title: rawTitle, statusText: statusText)
            if let subtitle = header.subtitle {
                return subtitle
            }
            return widget.lines
                .map { ANSIParser.strip($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != header.title }
        case .messageQueue(let steeringCount, let followUpCount, _, _):
            return MessageQueueAttachmentPresentation.countSubtitle(
                steeringCount: steeringCount,
                followUpCount: followUpCount
            )
        }
    }

    var mediaSubtitle: String? {
        guard case .messageQueue(_, _, let photoCount, let fileCount) = self else { return nil }
        return MessageQueueAttachmentPresentation.mediaHint(photoCount: photoCount, fileCount: fileCount)
    }

    var kindLabel: String {
        switch self {
        case .title: "title"
        case .status: "status"
        case .native: "surface"
        case .widget: "widget"
        case .messageQueue: "queue"
        }
    }

    var identifierSuffix: String {
        switch self {
        case .title(let title): "title-\(title.extensionAccessibilityIdentifierComponent)"
        case .status(_, let key, _): "status-\(key.extensionAccessibilityIdentifierComponent)"
        case .native(let nativeSurface, _): nativeSurface.surface.id.extensionAccessibilityIdentifierComponent
        case .widget(let widget, _, _): widget.key.extensionAccessibilityIdentifierComponent
        case .messageQueue: "message-queue"
        }
    }

    var stateTone: ExtensionSurfaceStripTone {
        switch self {
        case .native(let nativeSurface, _): Self.nativeTone(nativeSurface.surface)
        case .widget, .status: .accent
        case .messageQueue(let steeringCount, let followUpCount, _, _):
            steeringCount + followUpCount > 0 ? .success : .neutral
        case .title: .neutral
        }
    }

    var leadingSystemImage: String? {
        if case .messageQueue = self { return "text.append" }
        return nil
    }

    /// Native surfaces and terminal widgets open full screen.
    var supportsFullScreen: Bool {
        switch self {
        case .native, .widget: true
        case .title, .status, .messageQueue: false
        }
    }

    private static func nativePreviewText(_ surface: ExtensionUINativeSurface) -> String? {
        for block in surface.nativeDisplayBlocks {
            switch block {
            case .activityList(_, let rows):
                if let row = rows.first {
                    return row.subtitle?.trimmedNonEmpty ?? row.detail?.trimmedNonEmpty ?? row.title.trimmedNonEmpty
                }
            case .text(_, let spans):
                let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            case .markdown(_, let markdown):
                if let text = markdown.trimmedNonEmpty { return text }
            case .progress(_, let label, let value, let indeterminate):
                if let label = label?.trimmedNonEmpty { return label }
                if indeterminate == true { return "In progress" }
                if let fraction = ExtensionNativeBlockPresentation.normalizedProgress(value) {
                    return "\(Int((fraction * 100).rounded()))%"
                }
            case .section(_, let title, let subtitle, _):
                if let subtitle = subtitle?.trimmedNonEmpty { return subtitle }
                if let title = title?.trimmedNonEmpty { return title }
            case .terminal(_, let lines, _):
                let text = lines.first?.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if let text, !text.isEmpty { return text }
            case .code(_, let language, _):
                return language?.trimmedNonEmpty ?? "Code"
            case .table(_, let columns, let rows, _):
                if let first = columns.first?.trimmedNonEmpty { return first }
                return rows.isEmpty ? "Table" : "\(rows.count) rows"
            case .chart(_, let kind, let title, let labels, _, _):
                return title?.trimmedNonEmpty ?? "\(kind) · \(labels.count)"
            case .divider, .spacer, .unsupported:
                continue
            }
        }
        return surface.fallbackDisplayLines.first?.trimmedNonEmpty
    }

    private static func nativeTone(_ surface: ExtensionUINativeSurface) -> ExtensionSurfaceStripTone {
        let rows = surface.nativeDisplayBlocks.flatMap { block -> [ExtensionUIActivityRow] in
            if case .activityList(_, let rows) = block { return rows }
            return []
        }
        let tones = Set(rows.map { ExtensionNativeBlockPresentation.activityTone($0.state) })
        // The strip shows the most urgent row state; inactive and unknown rows leave it accent.
        let priority: [(ExtensionNativeBlockPresentation.ActivityTone, ExtensionSurfaceStripTone)] = [
            (.error, .danger), (.warning, .warning), (.running, .running), (.queued, .queued), (.success, .success),
        ]
        return priority.first { tones.contains($0.0) }?.1 ?? .accent
    }
}

private enum ExtensionSurfaceStripTone {
    case neutral, accent, running, queued, success, warning, danger

    func color(_ palette: ThemePalette) -> UIColor {
        let color = switch self {
        case .neutral: palette.comment
        case .accent: palette.cyan
        case .running: palette.blue
        case .queued: palette.purple
        case .success: palette.green
        case .warning: palette.orange
        case .danger: palette.red
        }
        return UIColor(color)
    }
}

private extension ExtensionSurfacePlacementGroup {
    var accessibilityIdentifierComponent: String {
        switch self {
        case .aboveEditor: "aboveEditor"
        case .belowEditor: "belowEditor"
        }
    }
}

// MARK: - Strip pill

/// One extension entry's pill: a tone dot (or the queue's icon), title,
/// subtitle, media hint, and a disclosure chevron.
private final class ExtensionSurfaceStripPill: ExtensionStripPillControl {
    private let marker = UIImageView()
    private let dot = UIView()
    private let titleLabel = ExtensionChromeFont.label(.caption1, .semibold)
    private let subtitleLabel = ExtensionChromeFont.label(.caption2, .semibold)
    private let mediaLabel = ExtensionChromeFont.label(.caption2, .semibold)
    private let chevron = UIImageView()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        mediaLabel.accessibilityIdentifier = "chat.messageQueue.widget.media"
        for view in [marker, dot, titleLabel, subtitleLabel, mediaLabel, chevron] {
            row.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }

    func apply(
        _ entry: ExtensionSurfaceStripEntry,
        isActive: Bool,
        placement: ExtensionSurfacePlacementGroup,
        palette: ThemePalette
    ) {
        let tone = entry.stateTone.color(palette)
        if let image = entry.leadingSystemImage {
            marker.image = UIImage.scaledSymbol(image, style: .caption1, weight: .bold, color: tone)
            marker.isHidden = false
            dot.isHidden = true
        } else {
            dot.backgroundColor = tone
            dot.isHidden = false
            marker.isHidden = true
        }
        titleLabel.text = entry.title
        titleLabel.textColor = UIColor(palette.fg)
        let subtitle = entry.subtitle?.trimmedNonEmpty
        subtitleLabel.text = subtitle
        subtitleLabel.textColor = UIColor(palette.comment)
        subtitleLabel.isHidden = subtitle == nil
        let media = entry.mediaSubtitle?.trimmedNonEmpty
        mediaLabel.text = media
        mediaLabel.textColor = UIColor(palette.fg)
        mediaLabel.isHidden = media == nil
        chevron.image = UIImage.scaledSymbol(isActive ? "chevron.down" : "chevron.right", style: .caption2, weight: .bold, color: UIColor(palette.comment))
        surface.apply(palette: palette, active: isActive ? tone : nil)

        accessibilityIdentifier = "extension-strip-\(placement.accessibilityIdentifierComponent)-pill-\(entry.identifierSuffix)"
        accessibilityLabel = "\(isActive ? "Collapse" : "Expand") \(entry.title) \(entry.kindLabel)"
        let parts = [subtitle, media].compactMap(\.self)
        accessibilityValue = parts.isEmpty ? (isActive ? "Expanded" : "Collapsed") : parts.joined(separator: " • ")
    }
}

// MARK: - Drawer

/// What a drawer opens and reads outside itself.
@MainActor
struct ExtensionSurfaceDrawerActions {
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)?
    /// Opens the chat's reader (a native surface or a terminal widget full screen).
    var openReader: (ChatReaderPayload) -> Void
    /// The session's current snapshot of a native surface, by protocol id, so
    /// the reader follows updates the drawer would show.
    var liveSurface: ((String) -> ExtensionUINativeSurface?)?
}

/// The expanded body of one strip entry, under the strip: a header with the
/// entry's title and a collapse button, then the entry's content.
private final class ExtensionSurfaceDrawerView: ExtensionDrawerPanelView {
    let entryID: String
    /// The entry as last applied; same id, newer values.
    private var entry: ExtensionSurfaceStripEntry
    private let placement: ExtensionSurfacePlacementGroup
    var actions: ExtensionSurfaceDrawerActions
    private let titleLabel = ExtensionChromeFont.label(.subheadline, .semibold)
    private let subtitleLabel = ExtensionChromeFont.label(.caption1, lines: 0)
    private let mediaLabel = ExtensionChromeFont.label(.caption1, .semibold)
    private let collapseButton = UIButton(type: .custom)
    private var nativeViewport: ExtensionNativeBlockScrollView?
    /// The rounded well around a status or native body.
    private var inset: UIView?
    private var bodyLabel: UILabel?
    private var statusKeyLabel: UILabel?
    private var messageQueue: MessageQueueView?
    private var adoptedWidth: CGFloat = 0
    var onCollapse: (() -> Void)?

    init(
        entry: ExtensionSurfaceStripEntry,
        placement: ExtensionSurfacePlacementGroup,
        actions: ExtensionSurfaceDrawerActions
    ) {
        self.entryID = entry.id
        self.entry = entry
        self.placement = placement
        self.actions = actions
        super.init(spacing: 10)
        let placementID = placement.accessibilityIdentifierComponent
        accessibilityIdentifier = "extension-strip-\(placementID)-drawer-\(entry.identifierSuffix)"

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, mediaLabel])
        titles.axis = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        collapseButton.layer.cornerRadius = 16
        collapseButton.accessibilityIdentifier = "extension-strip-\(placementID)-drawer-collapse"
        collapseButton.accessibilityLabel = "Collapse \(entry.title) \(entry.kindLabel)"
        collapseButton.addAction(UIAction { [weak self] _ in self?.onCollapse?() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [titles, collapseButton])
        header.axis = .horizontal
        header.alignment = .top
        header.spacing = 10

        stack.addArrangedSubview(header)
        NSLayoutConstraint.activate([
            collapseButton.widthAnchor.constraint(equalToConstant: 32),
            collapseButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        collapseButton.setContentHuggingPriority(.required, for: .horizontal)
        buildContent()
        if entry.supportsFullScreen {
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Open Full Screen") { [weak self] _ in
                    self?.openFullScreen()
                    return true
                },
            ]
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        switch entry {
        case .title:
            let label = ExtensionChromeFont.label(.caption1, lines: 0)
            stack.addArrangedSubview(label)
            bodyLabel = label
        case .status:
            let keyLabel = ExtensionChromeFont.label(.caption2, .semibold)
            keyLabel.setContentHuggingPriority(.required, for: .horizontal)
            keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            let textLabel = ExtensionChromeFont.label(.caption1, lines: 0)
            let row = UIStackView(arrangedSubviews: [keyLabel, textLabel])
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            let box = Self.subtleInset(row, padding: 10)
            box.isAccessibilityElement = true
            stack.addArrangedSubview(box)
            inset = box
            statusKeyLabel = keyLabel
            bodyLabel = textLabel
        case .native:
            let viewport = ExtensionNativeBlockScrollView()
            viewport.accessibilityHint = "Double tap to open full screen."
            nativeViewport = viewport
            let box = Self.subtleInset(viewport, padding: 0)
            stack.addArrangedSubview(box)
            inset = box
        case .widget:
            // The terminal block draws its own inset; no outer padding.
            let viewport = ExtensionNativeBlockScrollView()
            viewport.accessibilityHint = "Double tap to open full screen."
            nativeViewport = viewport
            stack.addArrangedSubview(viewport)
        case .messageQueue:
            let queue = MessageQueueView(presentation: .drawer)
            queue.onOpenMessage = { [weak self] item in self?.openQueuedMessage(item) }
            messageQueue = queue
            stack.addArrangedSubview(queue)
        }
    }

    private static func subtleInset(_ content: UIView, padding: CGFloat) -> UIView {
        let box = UIView()
        box.layer.cornerRadius = 12
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 0.5
        box.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
        ])
        return box
    }

    func apply(
        _ entry: ExtensionSurfaceStripEntry,
        themeID: ThemeID,
        messageQueue configuration: MessageQueueSurfaceConfiguration?,
        sessionLiveTails: [String: ConversationChildTail]
    ) {
        self.entry = entry
        let palette = themeID.palette
        surface.apply(palette: palette)
        titleLabel.text = entry.title
        titleLabel.textColor = UIColor(palette.fg)
        let subtitle = entry.subtitle?.trimmedNonEmpty
        subtitleLabel.text = subtitle
        subtitleLabel.textColor = UIColor(palette.comment)
        subtitleLabel.isHidden = subtitle == nil
        let media = entry.mediaSubtitle?.trimmedNonEmpty
        mediaLabel.text = media
        mediaLabel.textColor = UIColor(palette.fg)
        mediaLabel.isHidden = media == nil
        var buttonConfiguration = UIButton.Configuration.plain()
        buttonConfiguration.image = UIImage.scaledSymbol("chevron.up", style: .caption1, weight: .bold, color: UIColor(palette.comment))
        buttonConfiguration.background.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.04)
        buttonConfiguration.background.cornerRadius = 16
        buttonConfiguration.contentInsets = .zero
        collapseButton.configuration = buttonConfiguration
        inset?.backgroundColor = UIColor(palette.fg).withAlphaComponent(0.035)
        inset?.layer.borderColor = UIColor(palette.fg).withAlphaComponent(0.08).cgColor
        bodyLabel?.textColor = UIColor(palette.fg)
        statusKeyLabel?.textColor = UIColor(palette.comment)
        let placementID = placement.accessibilityIdentifierComponent
        let context = ExtensionNativeBlockContext(
            themeID: themeID,
            linkContext: actions.linkContext,
            onOpenURL: actions.onOpenURL,
            sessionLiveTails: sessionLiveTails
        )
        switch entry {
        case .native(let nativeSurface, _):
            nativeViewport?.update(
                content: ExtensionNativeBlockContent(surface: nativeSurface.surface),
                context: context,
                sizing: .capped(maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight),
                contentInsets: NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10),
                spacing: 10,
                accessibilityIdentifier: "extension-native-surface-\(entry.identifierSuffix)-viewport",
                onDoubleTap: { [weak self] in self?.openFullScreen() }
            )
        case .widget(let widget, _, _):
            nativeViewport?.update(
                content: .terminalLines(widget.lines),
                context: context,
                sizing: .capped(maxHeight: ExtensionNativeSurfaceLayout.expandedMaxHeight),
                contentInsets: NSDirectionalEdgeInsets(),
                spacing: 10,
                accessibilityIdentifier: "extension-strip-\(placementID)-terminal-\(entry.identifierSuffix)",
                onDoubleTap: { [weak self] in self?.openFullScreen() }
            )
        case .messageQueue:
            if let configuration {
                messageQueue?.apply(configuration, themeID: themeID)
            }
            messageQueue?.isHidden = configuration == nil
        case .title(let title):
            bodyLabel?.text = title
        case .status(_, let key, let text):
            statusKeyLabel?.text = key
            bodyLabel?.text = text
            inset?.accessibilityLabel = "\(key), \(text)"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Blocks whose height follows the width measure at the width they get.
        guard let nativeViewport, nativeViewport.bounds.width > 0,
              abs(nativeViewport.bounds.width - adoptedWidth) > 0.5 else { return }
        adoptedWidth = nativeViewport.bounds.width
        nativeViewport.adoptLayoutWidth(adoptedWidth)
        nativeViewport.contentDidChange()
    }

    private func openFullScreen() {
        switch entry {
        case .native(let nativeSurface, let statusText):
            let id = nativeSurface.surface.id
            var liveSurface: (@MainActor () -> ExtensionUINativeSurface?)?
            if let lookup = actions.liveSurface {
                liveSurface = { lookup(id) }
            }
            actions.openReader(.extensionNative(ExtensionNativeReaderContent(
                surface: nativeSurface.surface,
                identifierSuffix: entry.identifierSuffix,
                title: entry.title,
                subtitle: entry.subtitle,
                statusText: statusText,
                linkContext: actions.linkContext,
                onOpenURL: actions.onOpenURL,
                liveSurface: liveSurface
            )))
        case .widget(let widget, _, _):
            actions.openReader(.document(
                content: .terminal(content: widget.lines.joined(separator: "\n"), command: nil)
            ))
        case .title, .status, .messageQueue:
            break
        }
    }

    /// A queued message in the reader, rendered as the Markdown it will send.
    private func openQueuedMessage(_ item: MessageQueueItem) {
        actions.openReader(.document(content: .markdown(
            content: item.message,
            filePath: nil,
            resourceAccess: actions.linkContext.markdownResourceAccess
        )))
    }
}

// MARK: - Panel

/// An extension placement's strip of pills and, while one is expanded, its
/// drawer. Above the composer the strip also carries the chat's own leading
/// pills (review comments, now playing) and trailing notification chip.
final class ExtensionSurfacePanelView: UIView {
    struct Content {
        var surface: ExtensionSurfaceState
        var messageQueue: MessageQueueSurfaceConfiguration?
        var themeID: ThemeID
        /// A new id collapses the expanded entry.
        var collapseRequestID: Int
        /// Busy child sessions' live tails by session id, shown under drawer rows that link
        /// to them. Empty while no drawer is expanded.
        var sessionLiveTails: [String: ConversationChildTail] = [:]
    }

    let placement: ExtensionSurfacePlacementGroup
    var actions: ExtensionSurfaceDrawerActions
    /// An entry expanded (true) or collapsed (false).
    var onExpandedEntryChange: ((Bool) -> Void)?

    private let stripScroll = UIScrollView()
    private let stripRow = UIStackView()
    private let stack = UIStackView()
    private var leadingViews: [UIView] = []
    private var trailingViews: [UIView] = []
    private var pills: [String: ExtensionSurfaceStripPill] = [:]
    private var drawer: ExtensionSurfaceDrawerView?
    private var expandedEntryID: String?
    private var lastCollapseRequestID: Int?
    private var lastContent: Content?

    init(placement: ExtensionSurfacePlacementGroup, actions: ExtensionSurfaceDrawerActions) {
        self.placement = placement
        self.actions = actions
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stripScroll.showsHorizontalScrollIndicator = false
        stripScroll.alwaysBounceVertical = false
        stripScroll.contentInsetAdjustmentBehavior = .never
        stripScroll.accessibilityIdentifier = "extension-strip-\(placement.accessibilityIdentifierComponent)-collapsed"
        stripRow.axis = .horizontal
        stripRow.alignment = .center
        stripRow.spacing = 8
        stripRow.translatesAutoresizingMaskIntoConstraints = false
        stripScroll.addSubview(stripRow)
        stack.addArrangedSubview(stripScroll)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripRow.topAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.topAnchor),
            stripRow.bottomAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.bottomAnchor),
            stripRow.leadingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.leadingAnchor),
            stripRow.trailingAnchor.constraint(equalTo: stripScroll.contentLayoutGuide.trailingAnchor),
            stripScroll.frameLayoutGuide.heightAnchor.constraint(equalTo: stripRow.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Views the strip shows before its entries (chat pills) and after them.
    func setStripAccessories(leading: [UIView], trailing: [UIView]) {
        guard !leading.elementsEqual(leadingViews, by: ===) || !trailing.elementsEqual(trailingViews, by: ===) else {
            return
        }
        leadingViews = leading
        trailingViews = trailing
        lastContent.map(apply)
    }

    /// Whether the panel shows anything for `content`.
    func hasVisibleContent(_ content: Content) -> Bool {
        !leadingViews.isEmpty || !trailingViews.isEmpty || !stripEntries(content).isEmpty
    }

    func apply(_ content: Content) {
        lastContent = content
        let palette = content.themeID.palette
        let entries = stripEntries(content)
        let ids = entries.map(\.id)

        if let lastCollapseRequestID, lastCollapseRequestID != content.collapseRequestID {
            expandedEntryID = nil
            onExpandedEntryChange?(false)
        }
        lastCollapseRequestID = content.collapseRequestID
        if let expandedEntryID, !ids.contains(expandedEntryID) {
            self.expandedEntryID = nil
            onExpandedEntryChange?(false)
        }

        var arranged: [UIView] = leadingViews
        var keptPills: [String: ExtensionSurfaceStripPill] = [:]
        for entry in entries {
            let pill = pills[entry.id] ?? ExtensionSurfaceStripPill()
            pill.apply(entry, isActive: entry.id == expandedEntryID, placement: placement, palette: palette)
            let id = entry.id
            pill.onTap = { [weak self] in self?.toggle(id) }
            keptPills[entry.id] = pill
            arranged.append(pill)
        }
        arranged.append(contentsOf: trailingViews)
        pills = keptPills
        if !stripRow.arrangedSubviews.elementsEqual(arranged, by: ===) {
            for view in stripRow.arrangedSubviews where !arranged.contains(where: { $0 === view }) {
                view.removeFromSuperview()
            }
            for (index, view) in arranged.enumerated() {
                stripRow.insertArrangedSubview(view, at: index)
            }
        }
        stripScroll.isHidden = arranged.isEmpty

        let active = expandedEntryID.flatMap { id in entries.first { $0.id == id } }
        if let active {
            if drawer?.entryID != active.id {
                drawer?.removeFromSuperview()
                let next = ExtensionSurfaceDrawerView(entry: active, placement: placement, actions: actions)
                next.onCollapse = { [weak self] in self?.setExpanded(nil) }
                stack.addArrangedSubview(next)
                drawer = next
            }
            drawer?.actions = actions
            drawer?.apply(
                active,
                themeID: content.themeID,
                messageQueue: content.messageQueue,
                sessionLiveTails: content.sessionLiveTails
            )
        } else if let drawer {
            drawer.removeFromSuperview()
            self.drawer = nil
        }
    }

    private func toggle(_ id: String) {
        setExpanded(expandedEntryID == id ? nil : id)
    }

    private func setExpanded(_ id: String?) {
        let changed = expandedEntryID != id
        expandedEntryID = id
        if changed, let lastContent {
            // A host that sizes this panel from outside (a SwiftUI preview)
            // measures it again.
            invalidateIntrinsicContentSize()
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.10, delay: 0, options: .curveEaseOut) {
                self.apply(lastContent)
                self.superview?.layoutIfNeeded()
            }
        }
        onExpandedEntryChange?(id != nil)
    }

    private func stripEntries(_ content: Content) -> [ExtensionSurfaceStripEntry] {
        let surface = content.surface
        var result: [ExtensionSurfaceStripEntry] = []
        if placement.showsChrome {
            if let title = surface.title?.trimmedNonEmpty {
                result.append(.title(title))
            }
            result.append(contentsOf: surface.standaloneStatusEntries().map {
                .status(id: $0.id, key: $0.key, text: $0.text)
            })
        }
        result.append(contentsOf: surface.widgetEntries(in: placement).map { entry in
            switch entry {
            case .native(let nativeSurface):
                return .native(
                    nativeSurface,
                    statusText: surface.attachedStatusText(
                        for: nativeSurface.key,
                        extensionScopeId: nativeSurface.extensionScopeId
                    )
                )
            case .widget(let widget):
                return .widget(
                    widget,
                    statusText: surface.attachedStatusText(for: widget.key, extensionScopeId: widget.extensionScopeId),
                    titleOverride: surface.displayTitle(for: widget)
                )
            }
        })
        if let messageQueue = content.messageQueue, messageQueue.hasVisibleEntry {
            let media = MessageQueueAttachmentPresentation.mediaCounts(in: messageQueue.queue)
            result.append(.messageQueue(
                steeringCount: messageQueue.queue.steering.count,
                followUpCount: messageQueue.queue.followUp.count,
                photoCount: media.photos,
                fileCount: media.files
            ))
        }
        return result
    }
}
