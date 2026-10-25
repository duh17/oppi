import UIKit

/// What a session list does when its rows are used. Each list supplies its own
/// routing and API calls; the rows, Thread strips, long-press menu, and swipe
/// actions stay the same everywhere.
struct SessionListRowActions {
    let open: (Session) -> Void
    /// Opens Thread detail for a root session.
    let openThread: (Session) -> Void
    let stop: (Session) -> Void
    let resume: (Session) -> Void
    /// Nil when this list cannot delete the session.
    let delete: (Session) -> (() -> Void)?
    /// The row's lock scope; nil when the list has no server.
    let lockTarget: (Session) -> ScopedLockTarget?
}

/// What deleting a session asks.
enum SessionDeleteConfirmationPolicy {
    static func deleteMessage(for session: Session) -> String {
        "This permanently deletes SQLite session metadata, local pi JSONL trace files for this session, chat attachment copies under .pi/attachments/\(session.id), generated media attachments served by Oppi, this device's cached timeline copy, and its local message draft."
    }
}

/// One session-list entry, drawn the same in All Sessions and workspace lists:
/// the session row, then its Thread strip or a link to the thread it belongs
/// to. The collection owns the row-body tap (selection), the trailing swipes,
/// and the long-press menu (`SessionListRowMenus`). The row keeps its
/// accessibility activation, and the strip or link opens Thread detail as a
/// control of its own, so a swipe on it cancels navigation.
struct SessionListEntryConfiguration: UIContentConfiguration {
    let row: SessionListRowContent
    let display: SessionRowDisplay
    let themeID: ThemeID
    /// The list's server's icon cache, for saved-Agent Genmoji.
    let iconAssetCache: IconAssetCache?
    let actions: SessionListRowActions

    func makeContentView() -> any UIView & UIContentView {
        SessionListEntryContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class SessionListEntryContentView: UIView, UIContentView {
    private let stack = UIStackView()
    private let rowView = SessionRowView(combinesAccessibility: true)
    /// Made on first use: most rows have neither.
    private var stripView: SessionThreadStripView?
    private var linkView: SessionThreadLinkView?
    private var applied: SessionListEntryConfiguration

    var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? SessionListEntryConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: SessionListEntryConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        rowView.accessibilityTraits = .button
        rowView.onActivate = { [weak self] in
            guard let self else { return }
            applied.actions.open(applied.row.entry.session)
        }
        stack.axis = .vertical
        stack.alignment = .trailing
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(rowView)
        addSubview(stack)
        // The list's own leading and trailing margins; the vertical inset the
        // hosted SwiftUI rows had.
        directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = true
        let margins = layoutMarginsGuide
        // The cell is as tall as its content: stack views fit loosely, so a
        // tall proposed size would otherwise stretch them.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            hug,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Self.verticalInset),
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        apply(configuration)
    }

    /// A Thread control under the row, inset to line up under its icon, that opens the thread.
    private func addThreadControl<Control: UIControl>(_ control: Control) -> Control {
        control.addAction(UIAction { [weak self] _ in self?.openThread() }, for: .touchUpInside)
        control.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(control)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -SessionThreadStripView.rowInset).isActive = true
        return control
    }

    static let verticalInset: CGFloat = 15

    /// The separator starts under the title, past the identity icon.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let cell = superview as? UICollectionViewListCell else { return }
        cell.separatorLayoutGuide.leadingAnchor.constraint(equalTo: rowView.textLeadingAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func apply(_ configuration: SessionListEntryConfiguration) {
        applied = configuration
        let row = configuration.row
        let entry = row.entry
        let session = entry.session
        let style = SessionRowStyle.for(configuration.themeID)
        let status = row.status(of: session)

        rowView.apply(
            SessionRowView.Content(
                presentation: row.presentation,
                lockBadge: row.lockBadge(of: session),
                hidesDetails: row.lockBadge(of: session) == .locked,
                isDurable: row.isDurable,
                callBadge: row.callBadge
            ),
            display: configuration.display,
            themeID: configuration.themeID,
            iconAssetCache: configuration.iconAssetCache
        )
        rowView.accessibilityIdentifier = "session.nav.\(session.id)"
        rowView.accessibilityValue = status.isBlocked ? status.label : ""

        if let thread = entry.thread {
            let stripView = stripView ?? addThreadControl(SessionThreadStripView())
            self.stripView = stripView
            stripView.setHiddenIfChanged(false)
            stripView.accessibilityIdentifier = "thread.nav.\(thread.root.id)"
            stripView.apply(
                SessionThreadStripView.Content(
                    rollup: thread,
                    statuses: row.statuses,
                    hidesDetails: row.lockBadge(of: thread.root) == .locked,
                    hidesCost: thread.members.contains { row.lockBadge(of: $0) == .locked }
                ),
                display: configuration.display,
                style: style,
                iconAssetCache: configuration.iconAssetCache
            )
        } else {
            stripView?.setHiddenIfChanged(true)
        }

        if entry.thread == nil, let root = entry.outsideRoot {
            let linkView = linkView ?? addThreadControl(SessionThreadLinkView())
            self.linkView = linkView
            linkView.setHiddenIfChanged(false)
            linkView.apply(
                root: root,
                workspaceName: row.foreignWorkspaceNames[root.id],
                lockBadge: row.lockBadge(of: root),
                display: configuration.display,
                colors: style.colors
            )
            linkView.accessibilityIdentifier = "thread.link.\(session.id)"
        } else {
            linkView?.setHiddenIfChanged(true)
        }
        accessibilityElements = ([rowView, stripView, linkView] as [UIView?]).compactMap { $0 }.filter { !$0.isHidden }
    }

    private func openThread() {
        let entry = applied.row.entry
        guard let root = entry.thread?.root ?? entry.outsideRoot else { return }
        applied.actions.openThread(root)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        // Compact density decides its rows from the width before sizing. The
        // row is laid out inside `layoutMarginsGuide`, so size it for the same
        // margins. The cell's own `directionalLayoutMargins` are not those: this
        // view's margins settle against the safe area and readable width the
        // cell is actually laid out in, and a row sized for a narrower width
        // than it is drawn at keeps a taller height than it needs.
        rowView.prepareLayout(width: targetSize.width - layoutMargins.left - layoutMargins.right)
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }
}

/// One-line link under a session whose thread is rooted in another list, such
/// as another workspace or worktree. Styled like the Thread strip label.
final class SessionThreadLinkView: UIControl {
    private let stack = UIStackView()
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let lockLabel = UILabel()
    private let chevron = UIImageView()
    private var verticalPadding: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous

        let font = UIFont.scaled(.caption1, .semibold)
        glyph.image = UIImage.scaledSymbol("point.3.connected.trianglepath.dotted", style: .caption1, weight: .semibold)
        titleLabel.text = String(localized: "In thread")
        titleLabel.font = font
        detailLabel.font = UIFont.scaled(.caption1)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = UIImage.scaledSymbol("chevron.right", style: .caption1, weight: .semibold)
        for view in [glyph, titleLabel, lockLabel, chevron] as [UIView] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        [glyph, titleLabel, detailLabel, lockLabel, SessionRowSpacer(minWidth: 4), chevron].forEach(stack.addArrangedSubview)
        addSubview(stack)
        let top = stack.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        let bottom = bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 6)
        verticalPadding = [top, bottom]
        NSLayoutConstraint.activate([
            top, bottom,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // Sits just under a row that opens chat; keep a comfortable target of its own.
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        root: Session,
        workspaceName: String?,
        lockBadge: ScopedLockState,
        display: SessionRowDisplay,
        colors: ComposerThemeColors
    ) {
        backgroundColor = colors.bgHighlight.withAlphaComponent(0.45)
        for constraint in verticalPadding { constraint.constant = display.isCompact ? 4 : 6 }
        glyph.tintColor = colors.blue
        titleLabel.textColor = colors.blue
        detailLabel.text = (["· \(root.displayTitle)"] + [workspaceName].compactMap { $0 }).joined(separator: " · ")
        detailLabel.textColor = colors.comment
        SessionRowText.setLockBadge(lockBadge, on: lockLabel, color: colors.comment)
        chevron.tintColor = colors.comment
        accessibilityLabel = "In thread from \(root.displayTitle)" + (workspaceName.map { " in \($0)" } ?? "")
    }
}
