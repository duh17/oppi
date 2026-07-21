import SwiftUI

struct ScheduleManagementView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var schedules: [AgentScheduleSummary] = []
    @State private var selectedStatus: AgentScheduleStatus = .active
    @State private var selectedScheduleId: String?
    @State private var isLoading = false
    @State private var error: String?

    private var visibleSchedules: [AgentScheduleSummary] {
        schedules.filter { $0.status == selectedStatus }
    }

    var body: some View {
        List {
            if isLoading && schedules.isEmpty {
                ForEach(0..<2, id: \.self) { _ in
                    ScheduleCardPlaceholder()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if visibleSchedules.isEmpty {
                ContentUnavailableView(
                    selectedStatus.emptyTitle,
                    systemImage: selectedStatus.emptySystemImage,
                    description: Text(selectedStatus.emptyDescription)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(visibleSchedules) { schedule in
                    Button {
                        selectedScheduleId = schedule.id
                    } label: {
                        ScheduleSummaryCard(schedule: schedule)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("schedules.row.\(schedule.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        scheduleSwipeAction(schedule)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(isPresented: scheduleDetailPresented) {
            if let selectedScheduleId {
                ScheduleDetailView(scheduleId: selectedScheduleId) { updated in
                    schedules = schedules.map { $0.id == updated.id ? updated : $0 }
                    if selectedStatus == .archived, updated.status == .active {
                        selectedStatus = .active
                    }
                }
            }
        }
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $selectedStatus) {
                        ForEach(AgentScheduleStatus.allCases, id: \.self) { status in
                            Text(status.filterTitle).tag(status)
                        }
                    }
                } label: {
                    Label(selectedStatus.filterTitle, systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityIdentifier("schedules.filter")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .accessibilityIdentifier("schedules.error")
                }

                GuidedControlSessionComposer(
                    domain: .schedules,
                    intent: .create,
                    placeholder: "Describe what should happen and when…"
                )
            }
        }
        .refreshable { await loadSchedules() }
        .task { await loadSchedules() }
    }

    private var scheduleDetailPresented: Binding<Bool> {
        Binding(
            get: { selectedScheduleId != nil },
            set: { isPresented in
                if !isPresented { selectedScheduleId = nil }
            }
        )
    }

    @ViewBuilder
    private func scheduleSwipeAction(_ schedule: AgentScheduleSummary) -> some View {
        switch schedule.status {
        case .active:
            Button {
                Task { await mutate(schedule, action: .pause) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .tint(.themeOrange)
        case .paused:
            Button {
                Task { await mutate(schedule, action: .resume) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .tint(.themeGreen)
        case .archived:
            Button {
                Task { await mutate(schedule, action: .restore) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.themeBlue)
        }
    }

    private enum SummaryMutation {
        case pause
        case resume
        case restore
    }

    @MainActor
    private func loadSchedules() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            schedules = try await apiClient.listAgentSchedules()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func mutate(_ schedule: AgentScheduleSummary, action: SummaryMutation) async {
        guard let apiClient else { return }
        do {
            let updated = switch action {
            case .pause: try await apiClient.pauseAgentSchedule(schedule.id)
            case .resume: try await apiClient.resumeAgentSchedule(schedule.id)
            case .restore: try await apiClient.restoreAgentSchedule(schedule.id)
            }
            schedules = schedules.map { $0.id == updated.id ? updated : $0 }
            if action == .restore { selectedStatus = .active }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

}

private struct ScheduleSummaryCard: View {
    let schedule: AgentScheduleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(schedule.trigger.scheduleScreenCadence)
                    .font(.caption.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.themeBlue)

                Spacer(minLength: 8)

                if schedule.status != .active {
                    StatusPill(
                        text: schedule.status.rawValue.capitalized,
                        tone: schedule.status == .paused ? .warning : .neutral,
                        emphasis: .tinted,
                        size: .mini
                    )
                }
            }

            Text(schedule.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            Divider()

            Label(schedule.trigger.scheduleScreenTiming(), systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.themeComment)
                .lineLimit(2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.themeBgHighlight, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(schedule.name), \(schedule.trigger.scheduleScreenTiming()), \(schedule.status.rawValue)")
    }
}

private struct ScheduleCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 3).fill(.themeComment.opacity(0.16)).frame(width: 72, height: 12)
            RoundedRectangle(cornerRadius: 5).fill(.themeComment.opacity(0.16)).frame(height: 24)
            Divider()
            RoundedRectangle(cornerRadius: 3).fill(.themeComment.opacity(0.12)).frame(width: 160, height: 14)
        }
        .padding(18)
        .redacted(reason: .placeholder)
        .background(.themeBgHighlight, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension AgentScheduleStatus {
    static var allCases: [AgentScheduleStatus] { [.active, .paused, .archived] }

    var filterTitle: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .archived: "Archived"
        }
    }

    var emptyTitle: String {
        switch self {
        case .active: "No Active Schedules"
        case .paused: "No Paused Schedules"
        case .archived: "No Archived Schedules"
        }
    }

    var emptySystemImage: String {
        switch self {
        case .active: "calendar.badge.plus"
        case .paused: "pause.circle"
        case .archived: "archivebox"
        }
    }

    var emptyDescription: String {
        switch self {
        case .active: "Describe what should happen and when below."
        case .paused: "Schedules you pause will appear here."
        case .archived: "Archived schedules stay recoverable here."
        }
    }
}

private struct ScheduleDetailView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppNavigation.self) private var navigation

    let scheduleId: String
    let onChanged: (AgentScheduleSummary) -> Void

    @State private var schedule: AgentSchedule?
    @State private var runs: [AgentScheduleRunSummary] = []
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var error: String?
    @State private var showRevision = false

    var body: some View {
        List {
            if isLoading && schedule == nil {
                ProgressView("Loading schedule…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.themeBg)
            } else if let schedule {
                Section("Schedule") {
                    detailRow("Name", schedule.name)
                    detailRow("Status", schedule.status.rawValue.capitalized)
                    detailRow("When", schedule.trigger.displaySummary)
                    detailRow("Updated", schedule.updatedAt.relativeString())
                }

                Section("Action") {
                    actionDetail(schedule.action)
                }

                Section("Controls") {
                    Button {
                        Task { await runNow() }
                    } label: {
                        Label("Run Now", systemImage: "play.fill")
                    }
                    .disabled(isMutating || schedule.status == .archived)
                    .accessibilityIdentifier("schedule.detail.run")

                    if schedule.status == .active {
                        Button {
                            Task { await mutate(.pause) }
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .disabled(isMutating)
                    } else if schedule.status == .paused {
                        Button {
                            Task { await mutate(.resume) }
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .disabled(isMutating)
                    } else {
                        Button {
                            Task { await mutate(.restore) }
                        } label: {
                            Label("Restore and Activate", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isMutating)
                        .accessibilityIdentifier("schedule.detail.restore")
                    }

                    if schedule.status != .archived {
                        Button(role: .destructive) {
                            Task { await mutate(.archive) }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .disabled(isMutating)
                    }
                }

                Section("Recent Runs") {
                    if runs.isEmpty {
                        Text("No runs yet")
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(runs) { run in
                            ScheduleRunRow(run: run) {
                                openRunSession(run)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Schedule Not Found", systemImage: "questionmark.circle")
                    .listRowBackground(Color.themeBg)
            }
        }
        .navigationTitle(schedule?.name ?? "Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if schedule != nil {
                    Button("Edit") { showRevision = true }
                        .disabled(isMutating)
                        .accessibilityIdentifier("schedule.detail.edit")
                }
            }
        }
        .task(id: scheduleId) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showRevision) {
            if let schedule {
                GuidedControlSessionSheet(
                    domain: .schedules,
                    intent: .revise,
                    targetId: schedule.id,
                    targetName: schedule.name,
                    placeholder: "Describe how this Schedule should change…"
                )
            }
        }
        .alert("Schedule", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private enum Mutation {
        case pause
        case resume
        case archive
        case restore
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.themeComment)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func actionDetail(_ action: AgentScheduleAction) -> some View {
        switch action {
        case .newSession(let workspaceId, let prompt, let agentId, let model, let worktreeId, let name):
            detailRow("Type", "New session")
            detailRow("Workspace", workspaceName(workspaceId))
            if let agentId, !agentId.isEmpty { detailRow("Agent", agentId) }
            if let worktreeId, !worktreeId.isEmpty { detailRow("Worktree", worktreeId) }
            if let name, !name.isEmpty { detailRow("Session name", name) }
            if let model, !model.isEmpty { detailRow("Model", model) }
            promptPreview(prompt)
        case .existingSession(let workspaceId, let sessionId, let prompt, let streamingBehavior):
            detailRow("Type", "Existing session")
            detailRow("Workspace", workspaceName(workspaceId))
            detailRow("Session", sessionTitle(sessionId))
            detailRow("Delivery", streamingBehavior?.displayName ?? "Auto")
            promptPreview(prompt)
        }
    }

    private func promptPreview(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt")
                .font(.subheadline.weight(.medium))
            Text(prompt)
                .font(.caption.monospaced())
                .foregroundStyle(.themeFg)
                .lineLimit(8)
                .textSelection(.enabled)
        }
    }

    @MainActor
    private func load() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            async let fetchedSchedule = apiClient.getAgentSchedule(scheduleId)
            async let fetchedRuns = apiClient.listAgentScheduleRuns(scheduleId: scheduleId, limit: 20)
            schedule = try await fetchedSchedule
            runs = try await fetchedRuns
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func runNow() async {
        guard let apiClient else { return }
        isMutating = true
        defer { isMutating = false }

        do {
            let run = try await apiClient.runAgentSchedule(scheduleId)
            runs = [run] + runs.filter { $0.id != run.id }
            if let sessionId = run.sessionId {
                openRunSession(run.withSessionId(sessionId))
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func mutate(_ mutation: Mutation) async {
        guard let apiClient else { return }
        isMutating = true
        defer { isMutating = false }

        do {
            let updated: AgentScheduleSummary
            switch mutation {
            case .pause:
                updated = try await apiClient.pauseAgentSchedule(scheduleId)
            case .resume:
                updated = try await apiClient.resumeAgentSchedule(scheduleId)
            case .archive:
                updated = try await apiClient.archiveAgentSchedule(scheduleId)
            case .restore:
                updated = try await apiClient.restoreAgentSchedule(scheduleId)
            }
            if var current = schedule {
                current.status = updated.status
                current.updatedAt = updated.updatedAt
                current.archivedAt = updated.archivedAt
                schedule = current
            }
            onChanged(updated)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openRunSession(_ run: AgentScheduleRunSummary) {
        guard let sessionId = run.sessionId,
              let serverId = workspaceStore.activeServerId else { return }
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(
                serverId: serverId,
                sessionId: sessionId,
                workspaceId: run.action.workspaceId
            )
        )
    }

    private func workspaceName(_ workspaceId: String) -> String {
        workspaceStore.workspaces.first(where: { $0.id == workspaceId })?.name ?? workspaceId
    }

    private func sessionTitle(_ sessionId: String) -> String {
        sessionStore.session(id: sessionId)?.displayTitle ?? sessionId
    }
}

private struct ScheduleRunRow: View {
    let run: AgentScheduleRunSummary
    let openSession: () -> Void

    var body: some View {
        Button(action: openSession) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(tone.color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(run.status.rawValue.capitalized)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.themeFg)
                    Text("\(run.createdAt.relativeString()) · \(runSourceLabel)")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                    if let error = run.error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.themeOrange)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if run.sessionId != nil {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(run.sessionId == nil)
    }

    private var runSourceLabel: String {
        switch run.kind {
        case .due:
            return "Scheduled"
        case .manual:
            return "Started manually"
        }
    }

    private var tone: StatusPillTone {
        switch run.status {
        case .completed:
            return .success
        case .running, .claimed, .pending:
            return .working
        case .failed:
            return .danger
        }
    }

    private var iconName: String {
        switch run.status {
        case .completed:
            return "checkmark.circle.fill"
        case .running:
            return "play.circle.fill"
        case .claimed, .pending:
            return "clock.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

private extension AgentScheduleRunSummary {
    func withSessionId(_ sessionId: String) -> AgentScheduleRunSummary {
        var copy = self
        copy.sessionId = sessionId
        return copy
    }
}
