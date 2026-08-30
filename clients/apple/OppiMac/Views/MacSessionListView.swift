import SwiftUI

/// Home-list selection: inbox rows open the chat trace. Stats-only is for
/// runtime rows that have no workspace target. Inbox IDs stay out of Runtime.
enum MacHomeSessionSelection: Sendable {
    case trace(MacSelectedSessionTarget)
    case statsOnly(StatsActiveSession)
    case none

    static func resolve(
        selectedSessionID: String?,
        targets: [MacSelectedSessionTarget],
        runtimeSessions: [StatsActiveSession]
    ) -> Self {
        guard let selectedSessionID, !selectedSessionID.isEmpty else {
            return .none
        }
        if let target = targets.first(where: { $0.sessionId == selectedSessionID }) {
            return .trace(target)
        }
        if let runtime = runtimeSessions.first(where: { $0.id == selectedSessionID }) {
            return .statsOnly(runtime)
        }
        return .none
    }

    /// Stats-row clicks keep `selectedSessionID` and clear the trace store.
    /// A later catalog hit on that same ID makes `resolve` return `.trace`
    /// without changing the ID, so `onChange(of: selectedSessionID)` does not
    /// fire. Bind when home detail is a catalog session the store does not have.
    static func unboundTraceTarget(
        selectedSessionID: String?,
        targets: [MacSelectedSessionTarget],
        runtimeSessions: [StatsActiveSession],
        boundSessionID: String?
    ) -> MacSelectedSessionTarget? {
        guard case .trace(let target) = resolve(
            selectedSessionID: selectedSessionID,
            targets: targets,
            runtimeSessions: runtimeSessions
        ) else {
            return nil
        }
        guard boundSessionID != target.sessionId else {
            return nil
        }
        return target
    }

    static func runtimeActivity(
        targets: [MacSelectedSessionTarget],
        runtimeSessions: [StatsActiveSession]
    ) -> [StatsActiveSession] {
        let inboxIDs = Set(targets.map(\.sessionId))
        return runtimeSessions.filter { !inboxIDs.contains($0.id) }
    }
}

struct SessionShellList: View {
    let targets: [MacSelectedSessionTarget]
    let runtimeSessions: [StatsActiveSession]
    let isLoadingWorkspaceSessions: Bool
    let workspaceSessionError: String?
    let sessionActionError: (String) -> String?
    let isStoppingSession: (String) -> Bool
    let isDeletingSession: (String) -> Bool
    @Binding var selectedSessionID: String?
    let stopTarget: (MacSelectedSessionTarget) async -> Void
    let deleteTarget: (MacSelectedSessionTarget) async -> Void
    let selectTarget: (MacSelectedSessionTarget) -> Void

    @State private var targetPendingDeletion: MacSelectedSessionTarget?
    @State private var expandedStoppedGroupIDs: Set<String> = []
    @State private var collapsedStoppedGroupIDs: Set<String> = []
    @State private var pendingScrollSessionID: String?

    private var inboxSections: SessionInboxSections<MacSelectedSessionTarget> {
        MacSessionInboxPresentation.sections(
            targets: targets,
            now: Date(),
            calendar: .current
        )
    }

    private var runtimeActivitySessions: [StatsActiveSession] {
        MacHomeSessionSelection.runtimeActivity(
            targets: targets,
            runtimeSessions: runtimeSessions
        )
    }

    var body: some View {
        let sections = inboxSections

        ScrollViewReader { scrollProxy in
            List(selection: $selectedSessionID) {
                if sections.isEmpty {
                    Section {
                        if isLoadingWorkspaceSessions {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading workspace sessions...")
                                    .foregroundStyle(.themeFgDim)
                            }
                        } else {
                            ContentUnavailableView(
                                workspaceSessionError == nil ? "No workspace sessions" : "Could not load sessions",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text(workspaceSessionError ?? "Start or attach the local server, then refresh to load recent workspace sessions.")
                            )
                        }
                    }
                } else {
                    if !sections.yourTurn.isEmpty {
                        sessionSection(SessionInboxSectionTitle.yourTurn, targets: sections.yourTurn)
                    }

                    if !sections.working.isEmpty {
                        sessionSection(SessionInboxSectionTitle.working, targets: sections.working)
                    }

                    ForEach(sections.stoppedGroups) { group in
                        stoppedSessionSection(group)
                    }
                }

                if !runtimeActivitySessions.isEmpty {
                    Section("Runtime activity") {
                        ForEach(runtimeActivitySessions, id: \.id) { session in
                            Text(MacHomeSessionListPaint.runtimeCaption(for: session))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .tag(session.id)
                                .foregroundStyle(.themeFgDim)
                        }
                    }
                }
            }
            .themedListSurface()
            .onChange(of: selectedSessionID, initial: true) { _, sessionID in
                revealSelectedSession(
                    sessionID,
                    in: sections,
                    scrollProxy: scrollProxy
                )
            }
            .onChange(of: expandedStoppedGroupIDs) { _, _ in
                scrollToPendingSelection(using: scrollProxy)
            }
            .onChange(of: selectedSessionID) { _, sessionID in
                if case .trace(let target) = MacHomeSessionSelection.resolve(
                    selectedSessionID: sessionID,
                    targets: targets,
                    runtimeSessions: runtimeActivitySessions
                ) {
                    selectTarget(target)
                }
            }
            .accessibilityIdentifier("workspace.sessionList")
            .navigationTitle("Sessions")
            .confirmationDialog(
                "Delete Session?",
                isPresented: Binding(
                    get: { targetPendingDeletion != nil },
                    set: { if !$0 { targetPendingDeletion = nil } }
                ),
                presenting: targetPendingDeletion
            ) { target in
                Button("Delete Session", role: .destructive) {
                    Task {
                        await deleteTarget(target)
                        targetPendingDeletion = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    targetPendingDeletion = nil
                }
            } message: { target in
                Text("Delete \"\(target.summary.session.displayTitle)\" from local session history and generated attachments.")
            }
        }
    }

    private func revealSelectedSession(
        _ sessionID: String?,
        in sections: SessionInboxSections<MacSelectedSessionTarget>,
        scrollProxy: ScrollViewProxy
    ) {
        guard let sessionID else {
            pendingScrollSessionID = nil
            return
        }
        if let group = sections.stoppedGroups.first(where: { group in
            group.items.contains(where: { $0.sessionId == sessionID })
        }), !isStoppedGroupExpanded(group) {
            pendingScrollSessionID = sessionID
            collapsedStoppedGroupIDs.remove(group.id)
            expandedStoppedGroupIDs.insert(group.id)
            return
        }

        pendingScrollSessionID = nil
        scrollProxy.scrollTo(sessionID, anchor: .center)
    }

    private func scrollToPendingSelection(using scrollProxy: ScrollViewProxy) {
        guard let sessionID = pendingScrollSessionID else { return }
        pendingScrollSessionID = nil
        scrollProxy.scrollTo(sessionID, anchor: .center)
    }

    private func sessionSection(
        _ title: String,
        targets: [MacSelectedSessionTarget]
    ) -> some View {
        Section(title) {
            ForEach(targets, id: \.sessionId) { target in
                sessionRow(target)
            }
        }
    }

    private func stoppedSessionSection(
        _ group: SessionInboxStoppedDayGroup<MacSelectedSessionTarget>
    ) -> some View {
        Section {
            if isStoppedGroupExpanded(group) {
                ForEach(group.items, id: \.sessionId) { target in
                    sessionRow(target)
                }
            }
        } header: {
            Button {
                toggleStoppedGroupExpansion(group)
            } label: {
                HStack(spacing: 8) {
                    Text(stoppedGroupTitle(group))
                    Spacer()
                    Image(systemName: isStoppedGroupExpanded(group) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFgDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.sessionList.\(group.id)")
            .accessibilityValue(isStoppedGroupExpanded(group) ? "Expanded" : "Collapsed")
        }
    }

    private func sessionRow(_ target: MacSelectedSessionTarget) -> some View {
        WorkspaceSessionActionRow(
            summary: target.summary,
            includeWorkspaceContext: true,
            actionError: sessionActionError(target.sessionId),
            isStopping: isStoppingSession(target.sessionId),
            isDeleting: isDeletingSession(target.sessionId),
            selectSession: {
                selectedSessionID = target.sessionId
                selectTarget(target)
            },
            stopSession: { await stopTarget(target) },
            requestDelete: { targetPendingDeletion = target }
        )
        .tag(target.sessionId)
        .foregroundStyle(.themeFg)
    }

    private func stoppedGroupTitle(
        _ group: SessionInboxStoppedDayGroup<MacSelectedSessionTarget>
    ) -> String {
        SessionInboxSectionTitle.stopped(
            day: group.day,
            now: Date(),
            calendar: .current
        )
    }

    private func isStoppedGroupExpanded(
        _ group: SessionInboxStoppedDayGroup<MacSelectedSessionTarget>
    ) -> Bool {
        if expandedStoppedGroupIDs.contains(group.id) {
            return true
        }
        if collapsedStoppedGroupIDs.contains(group.id) {
            return false
        }
        return SessionInboxStoppedDayPolicy.isExpandedByDefault(
            day: group.day,
            now: Date(),
            calendar: .current
        )
    }

    private func toggleStoppedGroupExpansion(
        _ group: SessionInboxStoppedDayGroup<MacSelectedSessionTarget>
    ) {
        if isStoppedGroupExpanded(group) {
            expandedStoppedGroupIDs.remove(group.id)
            collapsedStoppedGroupIDs.insert(group.id)
        } else {
            collapsedStoppedGroupIDs.remove(group.id)
            expandedStoppedGroupIDs.insert(group.id)
        }
    }
}
