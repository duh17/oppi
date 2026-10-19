import UIKit

// UIKit pieces every session list shares (All Sessions, a workspace's
// sessions): the values a hosted row draws, the trailing swipes and long-press
// menu, the delete confirmation and error alert, the section header (titled or
// expandable), and the bar items. The row itself stays SwiftUI
// (`SessionListEntryRow.cellConfiguration`), hosted per cell.

/// What one session-list cell draws, computed by the list in
/// `updateProperties()`. A list reconfigures an item only when this changes.
struct SessionListRowContent: Equatable {
    let entry: SessionListEntry
    /// The row session's presentation (`entry.session`).
    let presentation: SessionRowPresentation
    /// Status of every session the entry draws: the row, its thread members,
    /// and the root it links to.
    let statuses: [String: SessionStatusKind]
    /// Workspace names to show for sessions outside the list's workspace.
    var foreignWorkspaceNames: [String: String] = [:]

    func status(of session: Session) -> SessionStatusKind {
        statuses[session.id] ?? SessionStatusKind.resolve(session: session, seenAt: nil)
    }

    /// Every session whose status the entry draws.
    static func drawnSessions(of entry: SessionListEntry) -> [Session] {
        var sessions = [entry.session]
        if let thread = entry.thread {
            sessions.append(contentsOf: thread.members)
        }
        if let root = entry.outsideRoot {
            sessions.append(root)
        }
        return sessions
    }
}

// MARK: - Swipes and menu

/// Long-press menu (Open, Stop/Resume, Lock/Unlock, Copy Session ID, Delete)
/// and trailing swipes for every session row. Swipe left is lifecycle: full
/// swipe stops; a stopped row offers Resume and Delete with no full swipe, so
/// a swipe never starts or deletes a session without a deliberate tap. There
/// is no leading swipe: a row's leading-edge drag belongs to the workspace
/// drawer, and Lock/Unlock lives only in the long-press menu. The list's
/// `SessionListRowActions` is the owner of every action.
@MainActor
enum SessionListRowMenus {
    /// Stop anything not stopped (idle included); Resume or Delete a stopped
    /// session. Swipe buttons are filled glyphs on a tinted background.
    static func trailingSwipe(
        for session: Session,
        actions: SessionListRowActions,
        palette: ThemePalette
    ) -> UISwipeActionsConfiguration {
        let isStopped = session.status == .stopped
        var buttons: [UIContextualAction] = []
        // UIContextualAction has no public accessibilityIdentifier: UI tests
        // find these by their visible titles after the swipe.
        if isStopped {
            if canResume(session) {
                buttons.append(swipeButton("Resume", symbol: "play.fill", color: UIColor(palette.green)) {
                    actions.resume(session)
                })
            }
            if let delete = actions.delete(session) {
                // Delete only asks (the confirmation deletes), so it is not destructive here.
                buttons.append(swipeButton("Delete", symbol: "trash.fill", color: UIColor(palette.red), action: delete))
            }
        } else {
            buttons.append(swipeButton("Stop", symbol: "stop.fill", color: UIColor(palette.orange)) {
                actions.stop(session)
            })
        }
        let configuration = UISwipeActionsConfiguration(actions: buttons)
        configuration.performsFirstActionWithFullSwipe = !isStopped
        return configuration
    }

    static func contextMenu(
        for session: Session,
        actions: SessionListRowActions
    ) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: session.id as NSString, previewProvider: nil) { _ in
            menu(for: session, actions: actions)
        }
    }

    /// System menu rows: plain outline symbols, no tint, like Mail and Files.
    static func menu(for session: Session, actions: SessionListRowActions) -> UIMenu {
        var main: [UIMenuElement] = [
            UIAction(title: String(localized: "Open"), image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { _ in
                actions.open(session)
            },
        ]
        if session.status == .stopped {
            if canResume(session) {
                main.append(menuAction("Resume", symbol: "play.circle", id: "session.resume.\(session.id)") {
                    actions.resume(session)
                })
            }
        } else {
            main.append(menuAction("Stop", symbol: "stop.circle", id: "session.stop.\(session.id)") {
                actions.stop(session)
            })
        }
        if let target = actions.lockTarget(session) {
            main.append(lockAction(target, sessionId: session.id))
        }
        main.append(menuAction("Copy Session ID", symbol: "doc.on.doc", id: "session.copyId.\(session.id)") {
            UIPasteboard.general.string = session.id
            AppHaptics.impact(style: .light, intensity: 0.8)
            TransientConfirmationPill.show(String(localized: "Session ID Copied"))
        })
        guard session.status == .stopped, let delete = actions.delete(session) else {
            return UIMenu(children: main)
        }
        let deleteAction = menuAction("Delete", symbol: "trash", id: "session.menuDelete.\(session.id)", action: delete)
        deleteAction.attributes = .destructive
        // Two inline groups draw the divider above Delete.
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: main),
            UIMenu(options: .displayInline, children: [deleteAction]),
        ])
    }

    /// Incognito sessions cannot resume.
    private static func canResume(_ session: Session) -> Bool {
        session.status == .stopped && session.ephemeral != true
    }

    /// Lock never asks; Unlock removes the lock and asks for device authentication.
    private static func lockAction(_ target: ScopedLockTarget, sessionId: String) -> UIAction {
        let locks = ScopedLockService.shared
        let scope = target.scope
        if locks.isFlagged(scope) {
            return menuAction("Unlock", symbol: "lock.open", id: "session.unlock.\(sessionId)") {
                Task { _ = await locks.removeLock(scope) }
            }
        }
        return menuAction("Lock", symbol: "lock", id: "session.lock.\(sessionId)") {
            locks.lock(scope, workspaceId: target.workspaceId)
        }
    }

    private static func menuAction(
        _ title: String.LocalizationValue,
        symbol: String,
        id: String,
        action: @escaping () -> Void
    ) -> UIAction {
        let item = UIAction(title: String(localized: title), image: UIImage(systemName: symbol)) { _ in action() }
        item.accessibilityIdentifier = id
        return item
    }

    private static func swipeButton(
        _ title: String.LocalizationValue,
        symbol: String,
        color: UIColor,
        action: @escaping () -> Void
    ) -> UIContextualAction {
        let button = UIContextualAction(style: .normal, title: String(localized: title)) { _, _, completion in
            action()
            completion(true)
        }
        button.image = UIImage(systemName: symbol)
        button.backgroundColor = color
        return button
    }
}

// MARK: - Leading drag

/// Keeps a row's leading-edge drag from opening it. There is no leading swipe,
/// so nothing claims a rightward drag and the cell would select on touch-up.
/// This pan claims it alongside every other recognizer (vertical scroll, the
/// trailing swipe and its swipe-back close, the workspace drawer's edge pan)
/// and cancels the cell's touch, the way the SwiftUI row's tap recognizer
/// failed once the touch became a drag. A tap still selects.
@MainActor
final class SessionListLeadingDragGuard: NSObject, UIGestureRecognizerDelegate {
    private let pan = UIPanGestureRecognizer()

    func install(on collectionView: UICollectionView) {
        pan.delegate = self
        pan.cancelsTouchesInView = true
        collectionView.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        let leading: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        return velocity.x * leading > 0 && abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - Alerts

@MainActor
enum SessionListAlerts {
    /// "Delete Session?" with the deletion's full reach as its message. The
    /// sheet anchors to `sourceView` (the row) where it is a popover.
    static func confirmDelete(
        _ session: Session,
        from presenter: UIViewController,
        sourceView: UIView?,
        onDelete: @escaping () -> Void
    ) {
        let sheet = UIAlertController(
            title: String(localized: "Delete Session?"),
            message: SessionDeleteConfirmationPolicy.deleteMessage(for: session),
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Delete Session"), style: .destructive) { _ in
            onDelete()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            if let sourceView, sourceView.window != nil {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
            } else {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }
        presenter.present(sheet, animated: true)
    }

    /// "Error" with OK. A second error while one shows replaces its message.
    static func presentError(_ message: String, from presenter: UIViewController) {
        if let shown = presenter.presentedViewController as? SessionListErrorAlert {
            shown.message = message
            return
        }
        guard presenter.presentedViewController == nil else { return }
        let alert = SessionListErrorAlert(title: String(localized: "Error"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        presenter.present(alert, animated: true)
    }
}

/// Marks the list's error alert, so a later error updates it instead of stacking.
final class SessionListErrorAlert: UIAlertController {}

// MARK: - Section headers

/// A session-list section header: a plain title ("Your Turn"), or an
/// expandable group (a stopped day) that is one button with its title,
/// an optional count, an Expanded/Collapsed value, and a chevron.
final class SessionListSectionHeaderView: UICollectionReusableView {
    static let elementKind = UICollectionView.elementKindSectionHeader

    /// Covers the header for an expandable group; hidden for a titled one.
    private let button = UIButton(type: .custom)
    private let row = UIStackView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView()
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let header = UIListContentConfiguration.header()
        titleLabel.font = header.textProperties.font
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .default)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(detailLabel)
        row.addArrangedSubview(chevron)
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(button)
        button.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)

        let margins = layoutMarginsGuide
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: margins.topAnchor),
            row.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: header.directionalLayoutMargins.top,
            leading: Self.plainInset,
            bottom: header.directionalLayoutMargins.bottom,
            trailing: Self.plainInset
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Header text sits 16 pt in on a plain list and 20 pt in on an inset
    /// grouped one (level with the rows' text), as SwiftUI's did.
    static let plainInset: CGFloat = 16
    static let insetGroupedInset: CGFloat = 20

    var horizontalInset: CGFloat = SessionListSectionHeaderView.plainInset {
        didSet {
            directionalLayoutMargins.leading = horizontalInset
            directionalLayoutMargins.trailing = horizontalInset
        }
    }

    /// A titled header. Reuse clears the expandable state.
    func configure(title: String, palette: ThemePalette) {
        apply(title: title, palette: palette)
        onToggle = nil
        detailLabel.isHidden = true
        chevron.isHidden = true
        button.isHidden = true
        button.accessibilityIdentifier = nil
        button.accessibilityValue = nil
        row.accessibilityElementsHidden = false
        titleLabel.accessibilityTraits = .header
    }

    /// An expandable group header: the whole header toggles the group, for
    /// touch and accessibility activation alike. `detail` (a count) sits
    /// before the chevron.
    func configure(
        title: String,
        detail: String? = nil,
        isExpanded: Bool,
        accessibilityIdentifier: String?,
        palette: ThemePalette,
        onToggle: @escaping () -> Void
    ) {
        apply(title: title, palette: palette)
        self.onToggle = onToggle
        detailLabel.text = detail
        detailLabel.textColor = UIColor(palette.comment)
        detailLabel.isHidden = detail == nil
        chevron.isHidden = false
        chevron.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
        chevron.tintColor = UIColor(palette.comment)
        button.isHidden = false
        button.accessibilityLabel = detail.map { "\(title), \($0)" } ?? title
        button.accessibilityValue = isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        button.accessibilityIdentifier = accessibilityIdentifier
        // The button speaks for the row beneath it.
        row.accessibilityElementsHidden = true
    }

    private func apply(title: String, palette: ThemePalette) {
        titleLabel.text = title
        // SwiftUI's section header color; the chevron and count keep the theme's.
        titleLabel.textColor = .secondaryLabel
        backgroundColor = UIColor(palette.bg)
    }
}

// MARK: - Bar items

/// Bar items the session lists share, in UIKit. On the Duo's vertical rail an
/// item prefers the rail (`axisBehavior`) and keeps its overflow rank
/// (`visibilityPriority` from `VerticalRailItemPriority`); a top-leading item
/// stays in the horizontal bar.
@MainActor
enum SessionListBarItems {
    /// Whether the system places a vertical bar for these traits.
    static func joinsRail(_ traits: UITraitCollection) -> Bool {
        SystemVerticalBar.traitIsActive(traits)
    }

    /// Navigation outranks the frequent actions, and an accessory leaves first.
    static func railItem(_ item: UIBarButtonItem, priority: VerticalRailItemPriority) -> UIBarButtonItem {
        if #available(iOS 27.1, *) {
            item.axisBehavior = .verticalPreferred
            item.visibilityPriority = switch priority {
            case .navigation: UIBarButtonItemVisibilityPriority(higherThan: .high)
            case .keep: .high
            case .overflowFirst: .low
            }
        }
        return item
    }

    /// Keeps a leading control in the top-left corner when a side rail exists.
    static func horizontalOnly(_ item: UIBarButtonItem) -> UIBarButtonItem {
        if #available(iOS 27.1, *) {
            item.axisBehavior = .horizontalOnly
        }
        return item
    }

    /// Opens the workspace drawer. The rail shows its title; the bar a symbol.
    static func sidebarOpen(joinsRail: Bool, tint: UIColor, action: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: joinsRail ? String(localized: "Workspaces") : nil,
            image: UIImage(systemName: "sidebar.left"),
            primaryAction: UIAction { _ in action() }
        )
        item.tintColor = tint
        item.accessibilityLabel = String(localized: "Show workspaces")
        item.accessibilityIdentifier = "workspace.sidebar.open"
        return joinsRail ? railItem(item, priority: .navigation) : horizontalOnly(item)
    }

    /// Folder for the trailing bottom-bar capsule. On the rail, `railTitle`
    /// makes it a labeled symbol so the system shows the folder and keeps the
    /// title for overflow.
    static func files(
        isEnabled: Bool,
        accessibilityLabel: String,
        railTitle: String?,
        palette: ThemePalette,
        action: @escaping () -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: railTitle,
            image: UIImage(systemName: "folder"),
            primaryAction: UIAction { _ in action() }
        )
        item.isEnabled = isEnabled
        item.tintColor = UIColor(isEnabled ? palette.fg : palette.fgDim)
        item.accessibilityLabel = accessibilityLabel
        item.accessibilityIdentifier = "workspace.files.open"
        return railTitle == nil ? item : railItem(item, priority: .keep)
    }

    /// The rail's compose control. The rail has no room for the capsule's
    /// mic, so long-press keeps Dictate.
    static func railCompose(
        showsDictation: Bool,
        tint: UIColor,
        onStart: @escaping () -> Void,
        onDictate: @escaping () -> Void
    ) -> UIBarButtonItem {
        var menuItems: [UIMenuElement] = []
        if showsDictation {
            menuItems.append(UIAction(title: String(localized: "Dictate"), image: UIImage(systemName: "mic")) { _ in onDictate() })
        }
        let item = UIBarButtonItem(
            title: String(localized: "Message"),
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: UIAction { _ in onStart() },
            menu: menuItems.isEmpty ? nil : UIMenu(children: menuItems)
        )
        item.tintColor = tint
        item.accessibilityLabel = String(localized: "Start Quick Session")
        item.accessibilityIdentifier = "workspace.quickSession.start"
        item.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Dictate Quick Session")) { _ in
                onDictate()
                return true
            },
        ]
        return railItem(item, priority: .keep)
    }

    /// Now Playing is a wide pill. On the rail it is a labeled symbol that
    /// opens the same player.
    static func railNowPlaying(tint: UIColor, onOpen: @escaping () -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: String(localized: "Playing"),
            image: UIImage(systemName: "waveform"),
            primaryAction: UIAction { _ in onOpen() }
        )
        item.tintColor = tint
        item.accessibilityLabel = String(localized: "Now Playing")
        item.accessibilityIdentifier = "sessionList.nowPlaying.rail"
        return railItem(item, priority: .overflowFirst)
    }

    /// SwiftUI content (the Message capsule, the now-playing pill, the server
    /// switcher) as a bar item.
    static func hosted(_ host: UIViewController) -> UIBarButtonItem {
        UIBarButtonItem(customView: host.view)
    }
}
