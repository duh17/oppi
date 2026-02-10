import SwiftUI

// MARK: - Session List (workspace-grouped, native iOS)

struct SessionListView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PermissionStore.self) private var permissionStore

    @State private var showNewSession = false
    @State private var searchText = ""
    @State private var collapsedWorkspaces: Set<String> = []
    @State private var stoppedExpanded = false

    // MARK: - Grouping

    /// Sessions filtered by search query.
    private var filtered: [Session] {
        let all = sessionStore.sessions
        guard !searchText.isEmpty else { return all }
        let query = searchText.lowercased()
        return all.filter { session in
            (session.name?.lowercased().contains(query) ?? false)
            || (session.workspaceName?.lowercased().contains(query) ?? false)
            || (session.model?.lowercased().contains(query) ?? false)
            || (session.lastMessage?.lowercased().contains(query) ?? false)
            || (session.changeStats?.changedFiles.contains(where: { $0.lowercased().contains(query) }) ?? false)
        }
    }

    /// Active sessions (not stopped) grouped by workspace.
    private var workspaceGroups: [(name: String, sessions: [Session])] {
        let active = filtered.filter { $0.status != .stopped }
        let grouped = Dictionary(grouping: active) { $0.workspaceName ?? "Other" }
        return grouped
            .map { (name: $0.key, sessions: $0.value) }
            .sorted { lhs, rhs in
                // Workspaces with attention items float to top
                let lhsAttention = lhs.sessions.contains { needsAttention($0) }
                let rhsAttention = rhs.sessions.contains { needsAttention($0) }
                if lhsAttention != rhsAttention { return lhsAttention }
                // Then by most recent activity
                let lhsDate = lhs.sessions.map(\.lastActivity).max() ?? .distantPast
                let rhsDate = rhs.sessions.map(\.lastActivity).max() ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    /// Stopped sessions (separate collapsed section).
    private var stoppedSessions: [Session] {
        filtered
            .filter { $0.status == .stopped }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func needsAttention(_ session: Session) -> Bool {
        permissionStore.pending(for: session.id).count > 0
        || session.status == .error
    }

    // MARK: - Body

    var body: some View {
        List {
            // Active sessions grouped by workspace
            ForEach(workspaceGroups, id: \.name) { group in
                let isExpanded = Binding<Bool>(
                    get: { !collapsedWorkspaces.contains(group.name) },
                    set: { expanded in
                        if expanded {
                            collapsedWorkspaces.remove(group.name)
                        } else {
                            collapsedWorkspaces.insert(group.name)
                        }
                    }
                )

                Section(isExpanded: isExpanded) {
                    ForEach(sortedByAttention(group.sessions)) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(
                                session: session,
                                pendingCount: permissionStore.pending(for: session.id).count
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await deleteSession(session) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    WorkspaceSectionHeader(
                        name: group.name,
                        sessionCount: group.sessions.count,
                        hasAttention: group.sessions.contains { needsAttention($0) }
                    )
                }
            }

            // Stopped sessions — collapsed by default
            if !stoppedSessions.isEmpty {
                Section(isExpanded: $stoppedExpanded) {
                    ForEach(stoppedSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(
                                session: session,
                                pendingCount: 0
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteSession(session) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Label("Stopped", systemImage: "stop.circle")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sessions")
        .navigationDestination(for: String.self) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .searchable(text: $searchText, prompt: "Search sessions")
        .refreshable {
            await refreshSessions()
        }
        .overlay {
            if sessionStore.sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Create a session to start working with pi.")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            Button {
                showNewSession = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .shadow(radius: 4, y: 2)
            .padding()
        }
        .sheet(isPresented: $showNewSession) {
            WorkspacePickerView()
        }
    }

    /// Sort sessions within a workspace: attention first, then by recency.
    private func sortedByAttention(_ sessions: [Session]) -> [Session] {
        sessions.sorted { lhs, rhs in
            let lhsAttn = needsAttention(lhs)
            let rhsAttn = needsAttention(rhs)
            if lhsAttn != rhsAttn { return lhsAttn }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    // MARK: - Actions

    private func refreshSessions() async {
        guard let api = connection.apiClient else { return }
        do {
            let sessions = try await api.listSessions()
            sessionStore.sessions = sessions
            Task.detached { await TimelineCache.shared.saveSessionList(sessions) }
        } catch {
            // Keep cached list on error
        }
    }

    private func deleteSession(_ session: Session) async {
        guard let api = connection.apiClient else { return }
        sessionStore.remove(id: session.id)
        do {
            try await api.deleteSession(id: session.id)
            Task.detached { await TimelineCache.shared.removeTrace(session.id) }
        } catch {
            print("[delete] failed for \(session.id): \(error)")
        }
    }
}

// MARK: - Workspace Section Header

private struct WorkspaceSectionHeader: View {
    let name: String
    let sessionCount: Int
    let hasAttention: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
            Spacer()
            if hasAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Text("\(sessionCount)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

// MARK: - Session Row (native)

struct SessionRow: View {
    let session: Session
    let pendingCount: Int

    private var title: String {
        session.name ?? "Session \(String(session.id.prefix(8)))"
    }

    private var modelShort: String? {
        guard let model = session.model, !model.isEmpty else { return nil }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    private var contextPercent: Double? {
        guard let used = session.contextTokens,
              let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(session.status.nativeColor)
                .frame(width: 10, height: 10)
                .opacity(session.status == .busy || session.status == .stopping ? 0.8 : 1)
                .animation(
                    session.status == .busy || session.status == .stopping
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: session.status
                )

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: name
                Text(title)
                    .font(.body)
                    .fontWeight(pendingCount > 0 ? .semibold : .regular)
                    .lineLimit(1)

                // Row 2: change status
                if let stats = session.changeStats {
                    HStack(spacing: 8) {
                        Text(filesTouchedSummary(stats.filesChanged))
                            .foregroundStyle(changeSummaryColor(stats))

                        Text("+\(stats.addedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoGreen)

                        Text("-\(stats.removedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoRed)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }

                // Row 3: model + compact metrics
                HStack(spacing: 6) {
                    if let model = modelShort {
                        Text(model)
                    }

                    if session.messageCount > 0 {
                        Text("\(session.messageCount) msgs")
                    }

                    if let pct = contextPercent {
                        NativeContextGauge(percent: pct)
                    }

                    if session.cost > 0 {
                        Text(costString(session.cost))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Trailing: time + pending badge
            VStack(alignment: .trailing, spacing: 4) {
                Text(session.lastActivity.relativeString())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func costString(_ cost: Double) -> String {
        cost >= 0.01
            ? String(format: "$%.2f", cost)
            : String(format: "$%.3f", cost)
    }

    private func filesTouchedSummary(_ filesChanged: Int) -> String {
        filesChanged == 1 ? "1 file touched" : "\(filesChanged) files touched"
    }

    private func changeSummaryColor(_ stats: SessionChangeStats) -> Color {
        if stats.filesChanged >= 25 || stats.mutatingToolCalls >= 80 {
            return .tokyoRed
        }
        if stats.filesChanged >= 10 || stats.mutatingToolCalls >= 30 {
            return .tokyoOrange
        }
        return .tokyoGreen
    }
}

// MARK: - Native Context Gauge

/// Compact context usage indicator using system colors.
private struct NativeContextGauge: View {
    let percent: Double

    private var clamped: Double { min(max(percent, 0), 1) }

    private var tint: Color {
        if clamped > 0.9 { return .red }
        if clamped > 0.7 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: 24 * clamped)
            }
            .frame(width: 24, height: 4)

            Text("\(Int((clamped * 100).rounded()))%")
                .monospacedDigit()
        }
    }
}

// MARK: - Native Status Colors

extension SessionStatus {
    /// System-compatible status colors (not Tokyo Night).
    var nativeColor: Color {
        switch self {
        case .starting: return .blue
        case .ready: return .green
        case .busy: return .yellow
        case .stopping: return .orange
        case .stopped: return .secondary
        case .error: return .red
        }
    }
}
