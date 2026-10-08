import SwiftUI
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

/// The one action a swipe to the right shows on every session row
/// (Settings → Sessions → Swipe Actions). Swipe left stays lifecycle.
enum SessionLeadingSwipeAction: String, CaseIterable, Identifiable {
    case none
    case lock
    case lifecycle

    static let defaultValue: SessionLeadingSwipeAction = .lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .lock: String(localized: "Lock")
        case .lifecycle: String(localized: "Stop or Resume")
        }
    }
}

/// One session-list entry, drawn the same in All Sessions and workspace lists:
/// the session row, then its Thread strip or a link to the thread it belongs
/// to. The row body opens the session's chat and the strip or link opens
/// Thread detail; they are sibling tap targets (neither wraps the other), each
/// a real tap recognizer so a swipe on either cancels navigation.
struct SessionListEntryRow: View {
    let entry: SessionListEntry
    let presentation: (Session) -> SessionRowPresentation
    /// Status of any session in the entry: its own seen state and pending asks applied.
    let status: (Session) -> SessionStatusKind
    /// Workspace name to show for a session outside this list's workspace; nil hides it.
    let foreignWorkspaceName: (Session) -> String?
    let actions: SessionListRowActions

    @State private var locks = ScopedLockService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowBody
            if let thread = entry.thread {
                let blockedMember = thread.descendants.first { status($0).isBlocked }
                let rootTarget = actions.lockTarget(thread.root)
                SessionThreadStrip(
                    rollup: thread,
                    status: status,
                    hidesDetails: rootTarget.map(locks.isLocked) ?? false,
                    hidesCost: thread.members.contains { member in
                        actions.lockTarget(member).map(locks.isLocked) ?? false
                    }
                )
                    .padding(.leading, SessionThreadStrip.rowInset)
                    .onTapGesture { actions.openThread(thread.root) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { actions.openThread(thread.root) }
                    .accessibilityIdentifier("thread.nav.\(thread.root.id)")
                    .accessibilityValue(blockedMember.map { status($0).label } ?? "")
            } else if let root = entry.outsideRoot {
                SessionThreadLink(
                    root: root,
                    workspaceName: foreignWorkspaceName(root),
                    lockBadge: actions.lockTarget(root).map(locks.badge) ?? .none
                )
                    .padding(.leading, SessionThreadStrip.rowInset)
                    .onTapGesture { actions.openThread(root) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { actions.openThread(root) }
                    .accessibilityIdentifier("thread.link.\(entry.session.id)")
            }
        }
        .sessionRowActions(entry.session, actions: actions)
    }

    private var rowBody: some View {
        let session = entry.session
        let target = actions.lockTarget(session)
        return SessionRow(
            presentation: presentation(session),
            lockBadge: target.map(locks.badge) ?? .none,
            hidesDetails: target.map(locks.isLocked) ?? false
        )
            .contentShape(Rectangle())
            // A plain Button can still commit after a horizontal drag loses to
            // the List's swipe recognizer. Use an actual tap recognizer so row
            // navigation fails as soon as either swipe direction becomes a drag.
            .onTapGesture { actions.open(session) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { actions.open(session) }
            .accessibilityIdentifier("session.nav.\(session.id)")
            .accessibilityValue(status(session).isBlocked ? status(session).label : "")
    }
}

extension View {
    /// The shared long-press menu and Mail-style swipes for a session row.
    func sessionRowActions(_ session: Session, actions: SessionListRowActions) -> some View {
        modifier(SessionRowActionsModifier(session: session, actions: actions))
    }
}

/// Long-press menu (Open, Stop/Resume, Lock/Unlock, Copy Session ID, Delete)
/// and swipes for every session row. Swipe left is lifecycle: full swipe
/// stops; a stopped row offers Resume and Delete with no full swipe, so a
/// swipe never starts or deletes a session without a deliberate tap. Swipe
/// right is the one action chosen in Settings → Sessions → Swipe Actions.
private struct SessionRowActionsModifier: ViewModifier {
    let session: Session
    let actions: SessionListRowActions

    @AppStorage(AppPreferences.SessionRows.leadingSwipeActionKey)
    private var leadingAction: SessionLeadingSwipeAction = .defaultValue
    @State private var locks = ScopedLockService.shared

    private var lockTarget: ScopedLockTarget? {
        actions.lockTarget(session)
    }

    private var lockScope: ScopedLockScope? {
        lockTarget?.scope
    }

    private var isStopped: Bool { session.status == .stopped }
    /// Incognito sessions cannot resume.
    private var canResume: Bool { isStopped && session.ephemeral != true }

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .swipeActions(edge: .leading, allowsFullSwipe: leadingAllowsFullSwipe) { leadingSwipe }
            .swipeActions(edge: .trailing, allowsFullSwipe: !isStopped) { trailingSwipe }
    }

    // MARK: Menu

    /// System menu rows: plain outline symbols, no tint, like Mail and Files.
    @ViewBuilder
    private var menu: some View {
        Button {
            actions.open(session)
        } label: {
            Label("Open", systemImage: "bubble.left.and.text.bubble.right")
        }
        if isStopped {
            if canResume { resumeButton(.menu) }
        } else {
            stopButton(.menu)
        }
        if let lockScope { lockButton(lockScope, .menu) }
        Button {
            UIPasteboard.general.string = session.id
            AppHaptics.impact(style: .light, intensity: 0.8)
            TransientConfirmationPill.show(String(localized: "Session ID Copied"))
        } label: {
            Label("Copy Session ID", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("session.copyId.\(session.id)")
        if isStopped, let delete = actions.delete(session) {
            Divider()
            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("session.menuDelete.\(session.id)")
        }
    }

    // MARK: Swipes

    private var leadingAllowsFullSwipe: Bool {
        switch leadingAction {
        case .none: false
        case .lock: true
        // Full swipe may stop, never resume.
        case .lifecycle: !isStopped
        }
    }

    @ViewBuilder
    private var leadingSwipe: some View {
        switch leadingAction {
        case .none:
            EmptyView()
        case .lock:
            if let lockScope { lockButton(lockScope, .swipe) }
        case .lifecycle:
            if isStopped {
                if canResume { resumeButton(.swipe) }
            } else {
                stopButton(.swipe)
            }
        }
    }

    /// Stop anything not stopped (idle included); Resume or Delete a stopped session.
    @ViewBuilder
    private var trailingSwipe: some View {
        if isStopped {
            if canResume { resumeButton(.swipe) }
            if let delete = actions.delete(session) {
                Button(role: SessionDeleteConfirmationPolicy.swipeButtonRole, action: delete) {
                    Label("Delete", systemImage: "trash.fill")
                }
                .tint(.themeRed)
                .accessibilityIdentifier("session.delete.\(session.id)")
            }
        } else {
            stopButton(.swipe)
        }
    }

    // MARK: Buttons

    /// Swipe buttons are filled glyphs on a tinted background; menu rows use
    /// the outline symbol and the system menu color.
    private enum Placement {
        case menu
        case swipe

        func symbol(_ name: String) -> String {
            self == .swipe ? "\(name).fill" : name
        }
    }

    private func stopButton(_ placement: Placement) -> some View {
        Button {
            actions.stop(session)
        } label: {
            Label("Stop", systemImage: placement == .swipe ? "stop.fill" : "stop.circle")
        }
        .swipeTint(.themeOrange, placement == .swipe)
        .accessibilityIdentifier("session.stop.\(session.id)")
    }

    private func resumeButton(_ placement: Placement) -> some View {
        Button {
            actions.resume(session)
        } label: {
            Label("Resume", systemImage: placement == .swipe ? "play.fill" : "play.circle")
        }
        .swipeTint(.themeGreen, placement == .swipe)
        .accessibilityIdentifier("session.resume.\(session.id)")
    }

    /// Lock never asks; Unlock removes the lock and asks for device authentication.
    @ViewBuilder
    private func lockButton(_ scope: ScopedLockScope, _ placement: Placement) -> some View {
        if locks.isFlagged(scope) {
            Button {
                Task { await locks.removeLock(scope) }
            } label: {
                Label("Unlock", systemImage: placement.symbol("lock.open"))
            }
            .swipeTint(.themeComment, placement == .swipe)
            .accessibilityIdentifier("session.unlock.\(session.id)")
        } else {
            Button {
                locks.lock(scope, workspaceId: lockTarget?.workspaceId)
            } label: {
                Label("Lock", systemImage: placement.symbol("lock"))
            }
            .swipeTint(.themeBlue, placement == .swipe)
            .accessibilityIdentifier("session.lock.\(session.id)")
        }
    }
}

private extension View {
    /// Menu rows keep the system menu color; only swipe buttons are tinted.
    @ViewBuilder
    func swipeTint(_ style: ThemeShapeStyle, _ isSwipe: Bool) -> some View {
        if isSwipe { tint(style) } else { self }
    }
}

/// One-line link under a session whose thread is rooted in another list, such
/// as another workspace or worktree. Styled like the Thread strip label.
struct SessionThreadLink: View {
    @Environment(\.sessionRowDisplay) private var display

    let root: Session
    /// Root's workspace when it differs from the list's; nil hides it.
    let workspaceName: String?
    var lockBadge: ScopedLockState = .none

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Text("In thread")
            Text(detail)
                .fontWeight(.regular)
                .foregroundStyle(.themeComment)
                .lineLimit(1)
                .truncationMode(.middle)
            LockBadge(state: lockBadge)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .foregroundStyle(.themeComment)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.themeBlue)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, display.isCompact ? 4 : 6)
        // Sits just under a row that opens chat; keep a comfortable target of its own.
        .frame(minHeight: 32)
        .background(.themeBgHighlight.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In thread from \(root.displayTitle)" + (workspaceName.map { " in \($0)" } ?? ""))
    }

    private var detail: String {
        (["· \(root.displayTitle)"] + [workspaceName].compactMap { $0 }).joined(separator: " · ")
    }
}
