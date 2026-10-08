#if DEBUG
import Foundation
import SwiftUI

// MARK: - Session status preview

/// Every session status on production rows, sections, thread strip, and thread summary.
///
/// Uses `SessionListEntryRow`, `SessionThreadStrip`, `SessionThreadSummaryChips`, and the
/// waterfall with mock sessions, so status visuals cannot drift from the real lists. It does
/// not instantiate the stores: the seen state is a fixed table.
struct SessionStatusScreenshotPreview: View {
    enum Screen {
        case inbox
        case thread
    }

    @Environment(\.theme) private var theme

    let screen: Screen

    private let fixture = SessionStatusPreviewFixture(now: Date())

    var body: some View {
        NavigationStack {
            switch screen {
            case .inbox: inbox
            case .thread: thread
            }
        }
        .accessibilityIdentifier(
            ProcessInfo.processInfo.environment["SCREENSHOT_READY_ID"] ?? "screenshot.ready"
        )
    }

    // MARK: Inbox

    private var inbox: some View {
        let sections = fixture.inboxSections()
        return List {
            if !sections.yourTurn.isEmpty {
                Section(SessionInboxSectionTitle.yourTurn) {
                    ForEach(sections.yourTurn) { entryRow($0) }
                }
            }
            if !sections.working.isEmpty {
                Section(SessionInboxSectionTitle.working) {
                    ForEach(sections.working) { entryRow($0) }
                }
            }
            ForEach(sections.stoppedGroups) { group in
                Section("Stopped · Today") {
                    ForEach(group.items) { entryRow($0) }
                }
            }
        }
        .listStyle(.plain)
        .themedListSurface()
        .navigationTitle("All Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entryRow(_ entry: SessionListEntry) -> some View {
        SessionListEntryRow(
            entry: entry,
            presentation: { session in
                SessionRowPresentationBuilder.make(
                    session: session,
                    workspaceContext: "oppi",
                    seenAt: fixture.seenAt(session.id)
                )
            },
            status: fixture.status,
            foreignWorkspaceName: { _ in nil },
            actions: SessionListRowActions(
                open: { _ in },
                openThread: { _ in },
                stop: { _ in },
                resume: { _ in },
                delete: { _ in nil },
                lockTarget: { _ in nil }
            )
        )
        .listRowBackground(theme.bg.primary)
    }

    // MARK: Thread

    private var thread: some View {
        let snapshot = fixture.threadSnapshot
        let members = snapshot.sessions
        let rollup = SessionStatusRollup(
            root: members.first.map(fixture.status),
            others: members.dropFirst().map(fixture.status)
        )
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(members[0].displayTitle)
                        .font(.title2.bold())
                        .foregroundStyle(.themeFg)
                    SessionThreadSummaryChips(rollup: rollup) {}
                        .accessibilityIdentifier("thread.summary")
                }
                .listRowBackground(Color.clear)
            }
            Section("Inbox strip") {
                if let thread = SessionThreadGrouping.rollups(from: members).first {
                    SessionThreadStrip(rollup: thread, status: fixture.status)
                }
            }
            Section("Waterfall") {
                SessionThreadWaterfallView(
                    waterfall: SessionThreadWaterfall.build(
                        snapshot: snapshot,
                        now: fixture.now,
                        status: fixture.status
                    ),
                    agentNames: [:],
                    onOpen: { _ in }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Mock sessions for the status preview: one per status, and a thread with mixed members.
private struct SessionStatusPreviewFixture {
    let now: Date

    /// Sessions this device has seen the outcome of; every other outcome is unseen.
    private let seenIds: Set<String> = ["idle", "stopped", "thread-root"]

    func seenAt(_ id: String) -> Date? {
        seenIds.contains(id) ? now : nil
    }

    func status(_ session: Session) -> SessionStatusKind {
        SessionStatusKind.resolve(session: session, seenAt: seenAt(session.id))
    }

    private func session(
        _ id: String,
        _ name: String,
        lifecycle: SessionStatus,
        program: ProgramStatus?,
        parent: String? = nil,
        createdAgo: TimeInterval = 1_800,
        activeAgo: TimeInterval = 120,
        cost: Double = 0.42
    ) -> Session {
        Session(
            id: id,
            workspaceId: "oppi",
            workspaceName: "oppi",
            name: name,
            status: lifecycle,
            createdAt: now.addingTimeInterval(-createdAgo),
            lastActivity: now.addingTimeInterval(-activeAgo),
            lastAgentReplyAt: now.addingTimeInterval(-activeAgo),
            currentTurnStartedAt: lifecycle == .busy ? now.addingTimeInterval(-95) : nil,
            programStatus: program,
            model: "anthropic/claude-sonnet-5",
            messageCount: 12,
            tokens: TokenUsage(input: 0, output: 0),
            cost: cost,
            parentSessionId: parent
        )
    }

    private func program(
        _ state: ProgramStatusState,
        kind: ProgramStatusKind? = nil,
        ago: TimeInterval = 120
    ) -> ProgramStatus {
        ProgramStatus(state: state, kind: kind, since: now.addingTimeInterval(-ago))
    }

    private var statusSessions: [Session] {
        [
            session("approval", "Migrate the billing schema", lifecycle: .busy, program: program(.blocked, kind: .permission), activeAgo: 30),
            session("question", "Pick a pagination strategy", lifecycle: .ready, program: program(.blocked, kind: .question), activeAgo: 240),
            session("signin", "Sync the staging bucket", lifecycle: .ready, program: program(.blocked, kind: .auth), activeAgo: 400),
            session("error", "Fix flaky checkout test", lifecycle: .ready, program: program(.error, ago: 600), activeAgo: 600),
            session("done", "Draft release notes", lifecycle: .ready, program: program(.done, ago: 300), activeAgo: 300),
            session("idle", "Review dependency bumps", lifecycle: .ready, program: program(.done, ago: 7_200), activeAgo: 7_200),
            session("working", "Refactor the timeline reducer", lifecycle: .busy, program: program(.working, ago: 95), activeAgo: 5),
            session("stopped", "Spike: vector search", lifecycle: .stopped, program: program(.done, ago: 5_400), activeAgo: 5_400),
        ]
    }

    private var threadMembers: [Session] {
        [
            session("thread-root", "Refactor checkout flow", lifecycle: .ready, program: program(.done, ago: 900),
                    createdAgo: 7_200, activeAgo: 900, cost: 3.14),
            session("thread-approval", "Update payment client", lifecycle: .busy, program: program(.blocked, kind: .permission, ago: 60),
                    parent: "thread-root", createdAgo: 3_000, activeAgo: 60),
            session("thread-working-1", "Write migration tests", lifecycle: .busy, program: program(.working, ago: 90),
                    parent: "thread-root", createdAgo: 2_800, activeAgo: 10),
            session("thread-working-2", "Port fixtures", lifecycle: .busy, program: program(.working, ago: 200),
                    parent: "thread-root", createdAgo: 2_600, activeAgo: 20),
            session("thread-error", "Regenerate snapshots", lifecycle: .ready, program: program(.error, ago: 500),
                    parent: "thread-root", createdAgo: 2_400, activeAgo: 500),
            session("thread-done", "Draft changelog", lifecycle: .ready, program: program(.done, ago: 700),
                    parent: "thread-root", createdAgo: 2_200, activeAgo: 700),
            session("thread-stopped", "Audit call sites", lifecycle: .stopped, program: program(.done, ago: 1_400),
                    parent: "thread-root", createdAgo: 2_000, activeAgo: 1_400),
        ]
    }

    var threadSnapshot: SessionThreadSnapshot {
        SessionThreadSnapshot(
            rootSessionId: "thread-root",
            sessions: threadMembers,
            interactions: [],
            counterparts: []
        )
    }

    func inboxSections() -> SessionInboxSections<SessionListEntry> {
        let sessions = statusSessions + threadMembers
        let entries = SessionListEntries.threads(listed: sessions, loaded: sessions)
        let none: (Session) -> SessionListAttentionCounts = { _ in .none }
        return SessionInboxGrouping.make(
            items: entries,
            now: now,
            calendar: .current,
            session: \.representative,
            attention: { none($0.session) },
            sectionKind: { $0.sectionKind(attention: none) },
            isBlocked: { $0.isBlocked(attention: none) }
        )
    }
}
#endif
