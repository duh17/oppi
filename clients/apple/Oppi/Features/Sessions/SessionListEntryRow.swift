import SwiftUI

/// What a session list does when its rows are used. Each list supplies its own
/// routing and API calls; the rows, Thread strips, and swipe actions stay the same.
struct SessionListRowActions {
    let open: (Session) -> Void
    /// Opens Thread detail for a root session.
    let openThread: (Session) -> Void
    let stop: (Session) -> Void
    let resume: (Session) -> Void
    /// Nil when this list cannot delete the session.
    let delete: (Session) -> (() -> Void)?
}

/// One session-list entry, drawn the same in All Sessions and workspace lists:
/// the session row, then its Thread strip or a link to the thread it belongs
/// to. The row body opens the session's chat and the strip or link opens
/// Thread detail; they are sibling tap targets (neither wraps the other), each
/// a real tap recognizer so a swipe on either cancels navigation.
struct SessionListEntryRow: View {
    let entry: SessionListEntry
    let presentation: (Session) -> SessionRowPresentation
    let hasPendingAsk: (Session) -> Bool
    /// Workspace name to show for a session outside this list's workspace; nil hides it.
    let foreignWorkspaceName: (Session) -> String?
    let actions: SessionListRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowBody
            if let thread = entry.thread {
                let attentionMember = thread.descendants.first(where: hasPendingAsk)
                SessionThreadStrip(rollup: thread, attentionMember: attentionMember)
                    .padding(.leading, SessionThreadStrip.rowInset)
                    .onTapGesture { actions.openThread(thread.root) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { actions.openThread(thread.root) }
                    .accessibilityIdentifier("thread.nav.\(thread.root.id)")
                    .accessibilityValue(attentionMember != nil ? "Question pending" : "")
            } else if let root = entry.outsideRoot {
                SessionThreadLink(root: root, workspaceName: foreignWorkspaceName(root))
                    .padding(.leading, SessionThreadStrip.rowInset)
                    .onTapGesture { actions.openThread(root) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { actions.openThread(root) }
                    .accessibilityIdentifier("thread.link.\(entry.session.id)")
            }
        }
        // Full swipe only stops. On a stopped row it would Resume (start a
        // session) or Delete without a deliberate tap.
        .swipeActions(edge: .trailing, allowsFullSwipe: entry.session.status != .stopped) {
            swipeActions
        }
    }

    private var rowBody: some View {
        let session = entry.session
        return SessionRow(presentation: presentation(session))
            .contentShape(Rectangle())
            // A plain Button can still commit after a horizontal drag loses to
            // the List's swipe recognizer. Use an actual tap recognizer so row
            // navigation fails as soon as either swipe direction becomes a drag.
            .onTapGesture { actions.open(session) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { actions.open(session) }
            .accessibilityIdentifier("session.nav.\(session.id)")
            .accessibilityValue(hasPendingAsk(session) ? "Question pending" : "")
    }

    /// Stop anything not stopped (idle included); Resume or Delete a stopped session.
    @ViewBuilder
    private var swipeActions: some View {
        let session = entry.session
        if session.status == .stopped {
            if session.ephemeral != true {
                Button {
                    actions.resume(session)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .tint(.themeGreen)
                .accessibilityIdentifier("session.resume.\(session.id)")
            }
            if let delete = actions.delete(session) {
                Button(role: SessionDeleteConfirmationPolicy.swipeButtonRole, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.themeRed)
                .accessibilityIdentifier("session.delete.\(session.id)")
            }
        } else {
            Button {
                actions.stop(session)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.themeOrange)
            .accessibilityIdentifier("session.stop.\(session.id)")
        }
    }
}

/// One-line link under a session whose thread is rooted in another list, such
/// as another workspace or worktree. Styled like the Thread strip label.
struct SessionThreadLink: View {
    @Environment(\.sessionRowDisplay) private var display

    let root: Session
    /// Root's workspace when it differs from the list's; nil hides it.
    let workspaceName: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Text("In thread")
            Text(detail)
                .fontWeight(.regular)
                .foregroundStyle(.themeComment)
                .lineLimit(1)
                .truncationMode(.middle)
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
