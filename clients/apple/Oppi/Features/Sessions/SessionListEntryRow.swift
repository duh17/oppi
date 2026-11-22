import UIKit

/// What a session list does when its rows are used. Each list supplies its own
/// routing and API calls; the rows, Thread strips, long-press menu, and swipe
/// actions stay the same everywhere.
struct SessionListRowActions {
    let open: (Session) -> Void
    /// Opens or closes the thread a root session starts: its descendants list under it.
    let toggleThread: (Session) -> Void
    /// Opens or closes the fold of an open thread's stopped members (`SessionThreadStoppedFold`).
    let toggleStoppedMembers: (SessionThreadStoppedFold) -> Void
    let stop: (Session) -> Void
    let resume: (Session) -> Void
    /// Nil when this list cannot delete the session.
    let delete: (Session) -> (() -> Void)?
    /// The row's lock scope; nil when the list has no server.
    let lockTarget: (Session) -> ScopedLockTarget?
    /// The row's Pin or Unpin, read when the swipe or menu opens; nil where
    /// the list's server keeps no session pins.
    var pin: (Session) -> PinMenu.Toggle? = { _ in nil }
    /// The row's pane items (Open in New Pane ▸ Right / Below), read when its
    /// menu opens; empty where the window shows one pane or the chat cannot
    /// be named.
    var paneItems: (Session) -> [PaneMenuItem] = { _ in [] }
    /// The row's drag as its chat, so a drop on a pane's edge opens it there;
    /// nil where the window shows one pane.
    var dragItem: (Session) -> UIDragItem? = { _ in nil }
}

@MainActor
extension SessionListRowActions {
    /// Open in New Pane ▸ Right / Below for a session row: the chat opens
    /// beside the pane the list is drawn in (Stage 4a), as the row's tap opens
    /// it in that pane. Nothing on a compact window, where the window holds one
    /// pane. `view` is inside the list, so the items read the window's width
    /// and the pane it is in as its rows do.
    static func paneMenuItems(near view: UIView, chat: WorkspaceSessionNavTarget) -> [PaneMenuItem] {
        PaneOpenMenu.items(near: view, includesOpenHere: false, offersOtherPanes: false) { placement in
            PaneOpenMenu.place(placement, from: view) { PaneOpenContent(session: chat) }
        }
    }

    /// A session row lifts as its chat: dropped on a pane's edge it opens in a
    /// new pane there (`PaneHostController.place`, whose chat rules decide
    /// whether that is beside, in the main pane, or the leaf showing it).
    static func sessionDragItem(near view: UIView, chat: WorkspaceSessionNavTarget, name: String?) -> UIDragItem? {
        guard AdaptiveWidth.isWide(view.traitCollection),
              view.nearestViewController.map({ PaneHostController.containing($0) != nil }) == true else { return nil }
        let provider = NSItemProvider()
        provider.suggestedName = name
        let item = UIDragItem(itemProvider: provider)
        item.localObject = PaneDragPayload(chat: chat)
        return item
    }
}

extension Confirmation {
    /// "Delete Session?" with the deletion's full reach as its message.
    static func deleteSession(_ session: Session) -> Confirmation {
        Confirmation(
            title: String(localized: "Delete Session?"),
            message: "This permanently deletes SQLite session metadata, local pi JSONL trace files for this session, chat attachment copies under .pi/attachments/\(session.id), generated media attachments served by Oppi, this device's cached timeline copy, and its local message draft.",
            actionTitle: String(localized: "Delete Session")
        )
    }
}

/// One session-list entry, drawn the same in All Sessions and workspace lists:
/// the session row, then its Thread strip or a link to the thread it belongs
/// to. The collection owns the row-body tap (selection), the trailing swipes,
/// and the long-press menu (`SessionListRowMenus`). The row keeps its
/// accessibility activation. The strip folds the thread open and closed, and the
/// link opens the thread's root chat; each is a control of its own, so a swipe
/// on it cancels the tap. A child row listed under an open thread is an ordinary
/// row, indented by its depth.
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
    /// One Thread control and the slot that carries it. Made on first use: most rows have neither.
    private struct ThreadControl<Control: UIControl> {
        let control: Control
        /// The full-width slot the control sits in. The list hides the slot, so a hidden control
        /// takes the stack's spacing with it.
        let slot: UIView

        @MainActor var isShown: Bool { !slot.isHidden }
    }

    private var strip: ThreadControl<SessionThreadStripView>?
    private var link: ThreadControl<SessionThreadLinkView>?
    private var applied: SessionListEntryConfiguration
    /// Where the row starts: the list's margin plus the indent of a thread's child row.
    private var leadingConstraint: NSLayoutConstraint?
    private var identityObserver: NSObjectProtocol?

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
        let leading = stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor)
        leadingConstraint = leading
        // The cell is as tall as its content: stack views fit loosely, so a
        // tall proposed size would otherwise stretch them.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            hug,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Self.verticalInset),
            leading,
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        // A thread's children move in past the wider column where they are, so a
        // deepened icon never leaves a child row hanging off its parent's grid.
        identityObserver = NotificationCenter.default.addObserver(
            forName: AppPreferenceStore.Appearance.sessionIconSizeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyIndent() }
        }
        apply(configuration)
    }

    isolated deinit {
        if let identityObserver {
            NotificationCenter.default.removeObserver(identityObserver)
        }
    }

    /// A Thread row under the row, on the row's grid: the control starts on the row's title column and
    /// ends on its trailing text column, so the strip reads as part of the row rather than a card
    /// beside it. The slot keeps the stack's spacing and hiding for it.
    private func addThreadControl<Control: UIControl>(
        _ control: Control,
        action: @escaping (SessionListEntryContentView) -> Void
    ) -> ThreadControl<Control> {
        control.addAction(UIAction { [weak self] _ in self.map(action) }, for: .touchUpInside)
        control.translatesAutoresizingMaskIntoConstraints = false
        let slot = SessionThreadRowSlot()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(control)
        stack.addArrangedSubview(slot)
        NSLayoutConstraint.activate([
            // The slot spans the row, so the stack can space and hide it; inside it the control sits on
            // the grid, and a touch beside the control reaches the row as a touch outside the slot does.
            slot.widthAnchor.constraint(equalTo: stack.widthAnchor),
            control.topAnchor.constraint(equalTo: slot.topAnchor),
            slot.bottomAnchor.constraint(equalTo: control.bottomAnchor),
            control.leadingAnchor.constraint(equalTo: rowView.textLeadingAnchor),
            control.trailingAnchor.constraint(equalTo: rowView.textTrailingAnchor),
        ])
        return ThreadControl(control: control, slot: slot)
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

    /// A child row starts where its depth and the current icon size put it.
    private func applyIndent() {
        leadingConstraint?.constant = SessionRowIdentity.current.indent(forDepth: applied.row.entry.depth)
        setNeedsLayout()
    }

    private func apply(_ configuration: SessionListEntryConfiguration) {
        applied = configuration
        applyIndent()
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
            let strip = strip ?? addThreadControl(SessionThreadStripView()) { $0.toggleThread() }
            self.strip = strip
            strip.slot.setHiddenIfChanged(false)
            strip.control.accessibilityIdentifier = "thread.nav.\(thread.root.id)"
            strip.control.apply(
                SessionThreadStripView.Content(
                    rollup: thread,
                    askCounts: row.askCounts,
                    hidesDetails: row.lockBadge(of: thread.root) == .locked,
                    hidesCost: thread.members.contains { row.lockBadge(of: $0) == .locked },
                    isExpanded: entry.isExpanded
                ),
                display: configuration.display,
                style: style,
                iconAssetCache: configuration.iconAssetCache
            )
        } else {
            strip?.slot.setHiddenIfChanged(true)
        }

        if entry.thread == nil, let root = entry.outsideRoot {
            let link = link ?? addThreadControl(SessionThreadLinkView()) { $0.openRoot() }
            self.link = link
            link.slot.setHiddenIfChanged(false)
            link.control.apply(
                root: root,
                workspaceName: row.foreignWorkspaceNames[root.id],
                lockBadge: row.lockBadge(of: root),
                display: configuration.display,
                colors: style.colors
            )
            link.control.accessibilityIdentifier = "thread.link.\(session.id)"
        } else {
            link?.slot.setHiddenIfChanged(true)
        }
        var elements: [UIView] = [rowView]
        if let strip, strip.isShown { elements.append(strip.control) }
        if let link, link.isShown { elements.append(link.control) }
        accessibilityElements = elements
    }

    private func toggleThread() {
        guard let root = applied.row.entry.thread?.root else { return }
        applied.actions.toggleThread(root)
    }

    private func openRoot() {
        guard let root = applied.row.entry.outsideRoot else { return }
        applied.actions.open(root)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        // Compact density decides its rows from the width before sizing. The
        // row is laid out inside `layoutMarginsGuide`, so size it for the same
        // margins and the child indent. The cell's own `directionalLayoutMargins` are not those: this
        // view's margins settle against the safe area and readable width the
        // cell is actually laid out in, and a row sized for a narrower width
        // than it is drawn at keeps a taller height than it needs.
        rowView.prepareLayout(
            width: targetSize.width - layoutMargins.left - layoutMargins.right - (leadingConstraint?.constant ?? 0)
        )
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }
}

/// The slot a Thread control sits in, as an arranged subview of the row's stack. It spans the row so
/// the stack can space and hide it, and it lets a touch beside the control through to the cell, as a
/// touch on the row's margin did before the control had a slot: the row, not the slot, takes it.
final class SessionThreadRowSlot: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
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
        glyph.image = UIImage.scaledSymbol("bubble.left.and.bubble.right", style: .caption1, weight: .semibold)
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
        SessionRowText.setLockBadge(lockBadge, on: lockLabel, color: colors.comment, key: root.id)
        chevron.tintColor = colors.comment
        accessibilityLabel = "In thread from \(root.displayTitle)" + (workspaceName.map { " in \($0)" } ?? "")
    }
}
