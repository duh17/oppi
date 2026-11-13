import UIKit

// MARK: - Activity list

/// Rows one under another, as a list: no box around them, a hairline between rows inset to the
/// text, none after the last. The drawer or section holding the list is its container.
final class ExtensionNativeActivityListView: UIView, ExtensionNativeBlockRendering {
    private let stack = UIStackView()
    private var rowViews: [String: ExtensionNativeActivityRowView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ block: ExtensionUINativeBlock, context: ExtensionNativeBlockContext) {
        guard case .activityList(_, let rows) = block else { return }
        apply(rows: rows, context: context)
    }

    func apply(rows: [ExtensionUIActivityRow], context: ExtensionNativeBlockContext) {
        apply(rows: rows, context: context, accessibilityIdentifier: ExtensionNativeActivityRowView.defaultAccessibilityIdentifier)
    }

    /// `accessibilityIdentifier` names each row's control. The v1 block list names rows under
    /// `extension.native.activity.row`; a composite that reuses the list names them under its own
    /// surface and card.
    func apply(
        rows: [ExtensionUIActivityRow],
        context: ExtensionNativeBlockContext,
        accessibilityIdentifier: @escaping (ExtensionUIActivityRow) -> String
    ) {
        var next: [String: ExtensionNativeActivityRowView] = [:]
        var ordered: [ExtensionNativeActivityRowView] = []
        for row in rows where next[row.id] == nil {
            let view = rowViews[row.id] ?? ExtensionNativeActivityRowView()
            view.accessibilityIdentifierForControl = accessibilityIdentifier
            view.apply(row: row, context: context)
            next[row.id] = view
            ordered.append(view)
        }
        for (index, view) in ordered.enumerated() {
            view.showsSeparator = index < ordered.count - 1
        }
        rowViews = next
        guard !stack.arrangedSubviews.elementsEqual(ordered, by: ===) else { return }
        for view in stack.arrangedSubviews where !ordered.contains(where: { $0 === view }) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in ordered.enumerated() {
            stack.insertArrangedSubview(view, at: index)
        }
    }
}

/// One activity row, as a list row: the state symbol on the title's first line, then the title and
/// subtitle laid out by `UIListContentConfiguration.subtitleCell()` as a list cell's are, the
/// detail on one quieter line under them, and a thin bar for a row that sends `progress`.
/// Trailing: the time since `since`, ticking, then the chevron of a row that opens something. A
/// row with `blocks` is a disclosure row: tapping shows or hides the blocks, which are built only
/// while shown, and a link moves to its own trailing button. Nested children list under the row,
/// indented. Expansion survives snapshots because list views reuse row views by row id.
///
/// The title is one line, cut in the middle so both ends of a long name stay. The subtitle is one
/// line, two for a row that needs attention or failed (a question or an error is read whole), so a
/// working row's height does not follow its changing line.
///
/// A running row linking to a busy session (`oppi://session/<id>`) shows the newest tool or text
/// line of that session's live tail in place of its subtitle: it is fresher than the publisher's
/// copy. A row linking to a session offers the host's session menu
/// (`ExtensionNativeBlockContext.sessionMenu`) on touch and hold and secondary click, and the same
/// items as accessibility actions.
final class ExtensionNativeActivityRowView: UIView, UIContextMenuInteractionDelegate {
    /// The identifier this row's control carries, from the list that owns it.
    static let defaultAccessibilityIdentifier: (ExtensionUIActivityRow) -> String = {
        "extension.native.activity.row.\($0.id)"
    }

    var accessibilityIdentifierForControl: (ExtensionUIActivityRow) -> String =
        ExtensionNativeActivityRowView.defaultAccessibilityIdentifier

    var showsSeparator = false {
        didSet { separator.isHidden = !showsSeparator }
    }

    private let control = ActivityRowControl()
    /// The state symbol, on the title's first line rather than centered on the row.
    private let marker = UIImageView()
    /// A running row's state: the app's still working mark, as session rows draw it, in the
    /// symbol's place.
    private let workingMark = WorkingMarkView(textStyle: .subheadline)
    private let content = UIListContentView(configuration: .subtitleCell())
    /// The quiet one-line detail under the content's subtitle.
    private let detailLabel = ExtensionNativeBlockStyle.label(.caption1)
    private let progressBar = ExtensionNativeProgressBar()
    private let text = UIStackView()
    private let elapsed = BlocksElapsedView()
    private let chevron = UIImageView()
    private let separator = UIView()
    private let childContainer = UIView()
    private var childList: ExtensionNativeActivityListView?
    private let detailContainer = UIView()
    private let linkButton = UIButton(type: .system)
    private var detailStack: ExtensionNativeBlockStackView?
    private var isExpanded = false
    /// The symbol's and the trailing time's center on the title's first line. The content view's
    /// text guide exists once it lays out text, so this is made on the first render.
    private var markerCenter: NSLayoutConstraint?
    /// The symbol's column, scaled with the text up to a cap so a large symbol never crowds out
    /// the title.
    private lazy var markerWidth = marker.widthAnchor.constraint(equalToConstant: 22)
    private let trailing = UIStackView()

    private var row: ExtensionUIActivityRow?
    private var context: ExtensionNativeBlockContext?

    override init(frame: CGRect) {
        super.init(frame: frame)

        content.isUserInteractionEnabled = false
        marker.contentMode = .center
        marker.isAccessibilityElement = false
        detailLabel.lineBreakMode = .byTruncatingTail
        progressBar.isHidden = true
        // The detail lines up under the content's text; the stack's bottom margin takes over the
        // content's while there is one.
        for view in [content, detailLabel, progressBar] as [UIView] { text.addArrangedSubview(view) }
        text.axis = .vertical
        text.spacing = 0
        text.setCustomSpacing(6, after: detailLabel)
        text.isLayoutMarginsRelativeArrangement = true
        text.isUserInteractionEnabled = false
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        elapsed.isAccessibilityElement = false
        chevron.contentMode = .center
        chevron.isAccessibilityElement = false
        for view in [elapsed, chevron] as [UIView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        trailing.addArrangedSubview(elapsed)
        trailing.addArrangedSubview(chevron)
        trailing.axis = .horizontal
        trailing.alignment = .firstBaseline
        trailing.spacing = 6
        trailing.isUserInteractionEnabled = false
        // The text fills the row's height; the symbol and the time hang off the title's line.
        for view in [marker, text, trailing, workingMark] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            control.addSubview(view)
        }
        control.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        control.addInteraction(UIContextMenuInteraction(delegate: self))
        // A pointer (iPad, Mac) highlights the row as it does a list cell.
        control.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 10))
        control.accessibilityActionsProvider = { [weak self] in self?.menuAccessibilityActions() ?? [] }
        control.accessibilityValueProvider = { [weak self] in self?.liveAccessibilityValue() }

        detailContainer.isHidden = true
        linkButton.isHidden = true
        linkButton.addTarget(self, action: #selector(handleLinkTap), for: .touchUpInside)
        linkButton.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [control, linkButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 4
        let column = UIStackView(arrangedSubviews: [header, detailContainer, childContainer])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = true
        addSubview(separator)

        // One device pixel, from the screen this row lands on.
        let separatorHeight = separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale))
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            marker.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            text.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 12),
            text.topAnchor.constraint(equalTo: control.topAnchor),
            text.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            trailing.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 8),
            trailing.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            trailing.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
            separatorHeight,
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Inset to the text, as a list cell's separator is.
            separator.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            markerWidth,
            workingMark.centerXAnchor.constraint(equalTo: marker.centerXAnchor),
            workingMark.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            linkButton.widthAnchor.constraint(equalToConstant: 44),
            linkButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.render()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            separatorHeight.constant = 1 / max(1, self.traitCollection.displayScale)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(row: ExtensionUIActivityRow, context: ExtensionNativeBlockContext) {
        self.row = row
        self.context = context
        render()
    }

    private var linkURL: URL? {
        row.flatMap(ExtensionNativeBlockPresentation.activityRowURL)
    }

    private var linkedSessionId: String? {
        linkURL.flatMap { url in
            guard case .success(let link)? = PaneLinkCodec.decode(url), case .session(let id) = link.route else { return nil }
            return id
        }
    }

    private var detailBlocks: [ExtensionUINativeBlock] {
        row?.blocks?.compactMap(\.nativeDisplayBlock) ?? []
    }

    /// What the row says on its second line: a running row's newest live tool or text line, else
    /// the publisher's subtitle. Output, thinking and status lines never stand in for it.
    private func subtitleText(_ row: ExtensionUIActivityRow, context: ExtensionNativeBlockContext) -> String? {
        let tone = ExtensionNativeBlockPresentation.activityTone(row.state)
        let live = tone == .running
            ? linkedSessionId.flatMap { context.sessionLiveTails[$0] }?
                .lines.last { $0.kind == .tool || $0.kind == .text }?.text
            : nil
        return live?.trimmedNonEmpty ?? row.subtitle?.trimmedNonEmpty
    }

    private func render() {
        guard let row, let context else { return }
        let palette = context.palette
        let tone = ExtensionNativeBlockPresentation.activityTone(row.state)
        let hasDetail = !detailBlocks.isEmpty
        let rowLink = linkURL
        // The row tap has one job: disclosure when the row has blocks, else
        // navigation. A row with both keeps its link on a separate button.
        let linkURL = hasDetail ? nil : rowLink
        let subtitle = subtitleText(row, context: context)
        // At accessibility sizes the words wrap in full rather than cut a name to one word, and
        // the time moves under the text so the title keeps the row's width.
        let accessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory

        let titleFont = ExtensionNativeBlockStyle.font(.subheadline, weight: .semibold)
        let working = tone == .running
        marker.image = Self.markerSymbol(tone).flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        }
        marker.tintColor = ExtensionNativeBlockStyle.activityColor(tone, palette: palette)
        workingMark.isHidden = !working
        if working {
            workingMark.apply(tint: ExtensionNativeBlockStyle.activityColor(tone, palette: palette), palette: palette)
        }
        var configuration = UIListContentConfiguration.subtitleCell()
        // No hyphens inside names: `catalyst-ghostty-spike` wraps at its own hyphens. An attributed
        // title takes its line breaks from its paragraph style: one line cut in the middle keeps
        // both ends of a long name.
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.hyphenationFactor = 0
        titleStyle.lineBreakMode = accessibilitySize ? .byWordWrapping : .byTruncatingMiddle
        configuration.attributedText = NSAttributedString(
            string: row.title,
            attributes: [.font: titleFont, .foregroundColor: palette.ui.fg, .paragraphStyle: titleStyle]
        )
        configuration.textProperties.numberOfLines = accessibilitySize ? 0 : 1
        configuration.textProperties.lineBreakMode = titleStyle.lineBreakMode
        configuration.secondaryText = subtitle
        configuration.secondaryTextProperties.font = ExtensionNativeBlockStyle.font(.footnote)
        configuration.secondaryTextProperties.color = palette.ui.fg.withAlphaComponent(0.72)
        let readWhole = tone == .warning || tone == .error
        configuration.secondaryTextProperties.numberOfLines = accessibilitySize ? 0 : (readWhole ? 2 : 1)
        configuration.textToSecondaryTextVerticalPadding = 2
        let detail = row.detail?.trimmedNonEmpty
        let progress = ExtensionNativeBlockPresentation.normalizedProgress(row.progress)
        let hasFooter = detail != nil || progress != nil
        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: hasFooter ? 2 : 8, trailing: 0)
        content.configuration = configuration
        if markerCenter == nil, let guide = content.textLayoutGuide {
            markerCenter = marker.centerYAnchor.constraint(equalTo: guide.topAnchor)
            markerCenter?.isActive = true
        }
        markerCenter?.constant = titleFont.lineHeight / 2
        text.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: hasFooter ? 8 : 0, trailing: 0)
        detailLabel.text = detail
        detailLabel.textColor = palette.ui.comment
        detailLabel.isHidden = detail == nil
        detailLabel.numberOfLines = accessibilitySize ? 0 : 1
        progressBar.isHidden = progress == nil
        if let progress { progressBar.apply(fraction: progress, palette: palette) }
        markerWidth.constant = min(30, UIFontMetrics(forTextStyle: .body).scaledValue(for: 22, compatibleWith: traitCollection))

        if let since = row.since {
            elapsed.isHidden = false
            elapsed.apply(
                ExtensionUISurfaceElapsedNode(
                    base: ExtensionUISurfaceNodeBase(id: nil, accessibility: nil),
                    since: since, style: nil, tone: nil, format: "short"
                ),
                font: ExtensionNativeBlockStyle.font(.footnote, monospacedDigits: true),
                color: palette.ui.comment
            )
        } else {
            elapsed.isHidden = true
        }
        placeElapsed(underText: accessibilitySize)

        let isLinked = linkURL != nil
        let isInteractive = isLinked || hasDetail
        chevron.isHidden = !isInteractive
        chevron.image = UIImage(
            systemName: hasDetail ? (isExpanded ? "chevron.up" : "chevron.down") : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        )
        chevron.tintColor = palette.ui.comment.withAlphaComponent(0.7)
        separator.backgroundColor = palette.ui.comment.withAlphaComponent(0.25)
        control.isUserInteractionEnabled = isInteractive
        control.highlightColor = palette.ui.fg.withAlphaComponent(0.08)

        control.isAccessibilityElement = true
        control.accessibilityIdentifier = accessibilityIdentifierForControl(row)
        control.accessibilityLabel = ExtensionNativeBlockPresentation.joinedNonEmpty([row.title, subtitle, row.detail], separator: ", ")
        control.accessibilityTraits = isInteractive ? .button : .staticText
        control.accessibilityHint = hasDetail
            ? (isExpanded ? "Hides details" : "Shows details")
            : linkURL.flatMap { url in
                context.linkOutcome(for: url).flatMap {
                    ExtensionSurfaceLinkRouting.accessibilityHint(for: $0)
                }
            }

        let separateLink = hasDetail ? rowLink : nil
        linkButton.isHidden = separateLink == nil
        linkButton.setImage(UIImage(
            systemName: "arrow.up.right",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .default)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        ), for: .normal)
        linkButton.tintColor = palette.ui.comment
        linkButton.accessibilityIdentifier = accessibilityIdentifierForControl(row) + ".link"
        linkButton.accessibilityLabel = "Open \(row.title)"
        linkButton.accessibilityHint = separateLink.flatMap { url in
            context.linkOutcome(for: url).flatMap {
                ExtensionSurfaceLinkRouting.accessibilityHint(for: $0)
            }
        }

        if hasDetail, isExpanded {
            let stack = detailStack ?? makeDetailStack()
            stack.apply(blocks: detailBlocks, context: context)
            detailContainer.isHidden = false
        } else {
            detailContainer.isHidden = true
            if !hasDetail, let stack = detailStack {
                stack.removeFromSuperview()
                detailStack = nil
                isExpanded = false
            }
        }

        let children = row.children ?? []
        if !children.isEmpty {
            let list = childList ?? makeChildList()
            list.apply(rows: children, context: context)
            childContainer.isHidden = false
        } else {
            childContainer.isHidden = true
        }
    }

    /// The time trails the title's line, or sits under the text at accessibility sizes. Under the
    /// text it fills the text's width: kept at its own width there, it would hold the whole text
    /// column, and the list with it, to the width of the time.
    private func placeElapsed(underText: Bool) {
        if underText {
            guard elapsed.superview !== text else { return }
            elapsed.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text.addArrangedSubview(elapsed)
        } else {
            guard elapsed.superview !== trailing else { return }
            elapsed.setContentHuggingPriority(.required, for: .horizontal)
            trailing.insertArrangedSubview(elapsed, at: 0)
        }
    }

    /// The row's state and its time, read when VoiceOver asks, so the time is the current one.
    private func liveAccessibilityValue() -> String? {
        guard let row else { return nil }
        return ExtensionNativeBlockPresentation.joinedNonEmpty(
            [ExtensionNativeBlockPresentation.activityRowAccessibilityValue(row), elapsed.isHidden ? nil : elapsed.accessibilityValue],
            separator: ", "
        )
    }

    private func makeChildList() -> ExtensionNativeActivityListView {
        let list = ExtensionNativeActivityListView()
        list.translatesAutoresizingMaskIntoConstraints = false
        childContainer.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: childContainer.topAnchor),
            list.leadingAnchor.constraint(equalTo: childContainer.leadingAnchor, constant: 22),
            list.trailingAnchor.constraint(equalTo: childContainer.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: childContainer.bottomAnchor),
        ])
        childList = list
        return list
    }

    private func makeDetailStack() -> ExtensionNativeBlockStackView {
        let stack = ExtensionNativeBlockStackView()
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        detailStack = stack
        return stack
    }

    @objc private func handleTap() {
        if !detailBlocks.isEmpty {
            isExpanded.toggle()
            render()
            invalidateExtensionNativeBlockHost()
            UIAccessibility.post(notification: .layoutChanged, argument: control)
            return
        }
        guard let url = linkURL else { return }
        context?.open(url)
    }

    @objc private func handleLinkTap() {
        guard let url = linkURL else { return }
        context?.open(url)
    }

    // MARK: Context menu

    /// The host's menu for the linked session, built when asked so it shows the session as it is.
    private func sessionMenu() -> UIMenu? {
        guard let sessionId = linkedSessionId, let url = linkURL else { return nil }
        return context?.sessionMenu?(sessionId, url, row?.state)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = sessionMenu() else { return nil }
        return UIContextMenuConfiguration(identifier: linkedSessionId as NSString?, previewProvider: nil) { _ in menu }
    }

    /// The menu's actions as accessibility actions: the same items run the same owner actions.
    /// Items the menu loads later (a deferred element) are left to the menu itself.
    private func menuAccessibilityActions() -> [UIAccessibilityCustomAction] {
        func leaves(_ elements: [UIMenuElement]) -> [UIAction] {
            elements.flatMap { element -> [UIAction] in
                if let action = element as? UIAction { return [action] }
                if let menu = element as? UIMenu { return leaves(menu.children) }
                return []
            }
        }
        return leaves(sessionMenu()?.children ?? []).map { action in
            UIAccessibilityCustomAction(name: action.title, image: action.image) { [weak control] _ in
                action.performWithSender(control, target: nil)
                return true
            }
        }
    }

    /// A running row draws `workingMark` instead.
    private static func markerSymbol(_ tone: ExtensionNativeBlockPresentation.ActivityTone) -> String? {
        switch tone {
        case .running: nil
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .queued: "clock"
        case .inactive: "ellipsis.circle"
        case .neutral: "circle.fill"
        }
    }
}

/// The row's tap target: a list cell's pressed highlight, and the menu's items and the live time
/// read by VoiceOver when it asks rather than copied when the row drew.
private final class ActivityRowControl: UIControl {
    var highlightColor: UIColor = .clear
    var accessibilityActionsProvider: () -> [UIAccessibilityCustomAction] = { [] }
    var accessibilityValueProvider: () -> String? = { nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? highlightColor : .clear }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { accessibilityActionsProvider() }
        set { super.accessibilityCustomActions = newValue }
    }

    override var accessibilityValue: String? {
        get { accessibilityValueProvider() }
        set { super.accessibilityValue = newValue }
    }
}
