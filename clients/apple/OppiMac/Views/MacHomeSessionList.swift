import SwiftUI

/// Home session list with shared FTS search. Grouped inbox stays in
/// ``SessionShellList``; search results flatten like iOS.
struct MacHomeSessionList: View {
    let targets: [MacSelectedSessionTarget]
    @Binding var searchQuery: String
    let isSearching: Bool
    let searchMatches: [MacSessionSearchPresentation.Match]?
    let runtimeSessions: [StatsActiveSession]
    let isLoadingWorkspaceSessions: Bool
    let workspaceSessionError: String?
    let sessionActionError: (String) -> String?
    let isStoppingSession: (String) -> Bool
    let isDeletingSession: (String) -> Bool
    @Binding var selectedSessionID: String?
    let refresh: () async -> Void
    let stopTarget: (MacSelectedSessionTarget) async -> Void
    let deleteTarget: (MacSelectedSessionTarget) async -> Void
    let selectTarget: (MacSelectedSessionTarget) -> Void

    @State private var targetPendingDeletion: MacSelectedSessionTarget?

    private var searchContent: MacSessionSearchPresentation.ListContent {
        MacSessionSearchPresentation.ListContent.resolve(
            query: searchQuery,
            matches: searchMatches,
            isSearching: isSearching
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            listControls
            Divider()
            listContent
        }
        .background {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()
        }
    }

    private var listControls: some View {
        HStack(spacing: 8) {
            TextField("Search sessions", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search sessions")
                .accessibilityIdentifier("workspace.sessionList.search")

            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh Sessions", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(isLoadingWorkspaceSessions)
            .help("Refresh sessions")
            .accessibilityIdentifier("workspace.sessionList.refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.themeBg)
    }

    @ViewBuilder
    private var listContent: some View {
        switch searchContent {
        case .groupedInbox:
            SessionShellList(
                targets: targets,
                runtimeSessions: runtimeSessions,
                isLoadingWorkspaceSessions: isLoadingWorkspaceSessions,
                workspaceSessionError: workspaceSessionError,
                sessionActionError: sessionActionError,
                isStoppingSession: isStoppingSession,
                isDeletingSession: isDeletingSession,
                selectedSessionID: $selectedSessionID,
                stopTarget: stopTarget,
                deleteTarget: deleteTarget,
                selectTarget: selectTarget
            )
        case .searching:
            List {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Searching sessions…")
                        Spacer()
                    }
                    .frame(minHeight: 88)
                }
            }
            .accessibilityIdentifier("workspace.sessionList")
            .navigationTitle("Sessions")
            .themedListSurface()
        case .noMatches(let query):
            List {
                Section {
                    ContentUnavailableView(
                        "No Matching Sessions",
                        systemImage: "magnifyingglass",
                        description: Text("No sessions match “\(query)”.")
                    )
                }
            }
            .accessibilityIdentifier("workspace.sessionList")
            .navigationTitle("Sessions")
            .themedListSurface()
        case .results(let matches):
            List(selection: $selectedSessionID) {
                Section("Results") {
                    ForEach(matches, id: \.target.sessionId) { match in
                        searchRow(match)
                    }
                }
            }
            .onChange(of: selectedSessionID) { _, sessionID in
                if let match = matches.first(where: { $0.target.sessionId == sessionID }) {
                    selectTarget(match.target)
                }
            }
            .accessibilityIdentifier("workspace.sessionList")
            .navigationTitle("Sessions")
            .themedListSurface()
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

    private func searchRow(_ match: MacSessionSearchPresentation.Match) -> some View {
        let chrome = MacSessionInboxRowChrome.make(status: match.target.summary.status)
        let presentation = SessionRowPresentationBuilder.make(
            session: match.target.summary.session,
            pendingAskCount: match.target.summary.pendingAskCount,
            workspaceContext: SessionRowPresentationBuilder.allSessionsWorkspaceContext(
                for: match.target.summary.session
            ),
            searchSnippet: match.snippet
        )

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                selectedSessionID = match.target.sessionId
                selectTarget(match.target)
            } label: {
                WorkspaceSessionSummaryRow(presentation: presentation)
            }
            .buttonStyle(.plain)

            if let actionError = sessionActionError(match.target.sessionId) {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .tag(match.target.sessionId)
        .foregroundStyle(.themeFg)
        .contextMenu {
            Button("Open") {
                selectedSessionID = match.target.sessionId
                selectTarget(match.target)
            }
            if chrome.showsContextMenuStop {
                Button("Stop Session") {
                    Task { await stopTarget(match.target) }
                }
                .disabled(
                    isStoppingSession(match.target.sessionId)
                        || isDeletingSession(match.target.sessionId)
                )
            }
            if chrome.showsContextMenuDelete {
                Button("Delete Session", role: .destructive) {
                    targetPendingDeletion = match.target
                }
                .disabled(
                    isDeletingSession(match.target.sessionId)
                        || isStoppingSession(match.target.sessionId)
                )
            }
        }
    }
}
