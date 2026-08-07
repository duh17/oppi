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
    @State private var agentNamesById: [String: String] = [:]
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var error: String?
    @State private var showNativeEdit = false
    @State private var showRevision = false
    @State private var showPromptReader = false
    @State private var confirmArchive = false

    var body: some View {
        List {
            if isLoading && schedule == nil {
                ProgressView("Loading schedule…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.themeBg)
            } else if let schedule {
                Section {
                    scheduleSummaryHeader(schedule)
                }

                Section("Instructions") {
                    promptPreview(prompt(in: schedule.action))
                }

                Section(runWithSectionTitle(schedule.action)) {
                    runWithDetail(schedule.action)
                }

                Section {
                    Button {
                        Task { await runNow() }
                    } label: {
                        Label("Run Now", systemImage: "play.fill")
                    }
                    .disabled(isMutating || schedule.status == .archived)
                    .accessibilityIdentifier("schedule.detail.run")

                    if schedule.status == .archived {
                        Button {
                            Task { await mutate(.restore) }
                        } label: {
                            Label("Restore and Activate", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isMutating)
                        .accessibilityIdentifier("schedule.detail.restore")
                    } else {
                        Toggle(isOn: enabledBinding(for: schedule)) {
                            Text("Enabled")
                        }
                        .disabled(isMutating)
                        .accessibilityIdentifier("schedule.detail.enabled")
                    }
                }

                Section {
                    if runs.isEmpty {
                        ContentUnavailableView(
                            "No Runs Yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Scheduled and manual runs will appear here.")
                        )
                    } else {
                        ForEach(runs) { run in
                            ScheduleRunRow(run: run) {
                                openRunSession(run)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Run History")
                        Spacer()
                        if !runs.isEmpty {
                            Text("\(runs.count) recent")
                                .textCase(nil)
                                .foregroundStyle(.themeComment)
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
            // Match agent detail: native Edit plus overflow for guided edit / archive.
            if let schedule {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if schedule.status != .archived {
                        Button("Edit") {
                            showNativeEdit = true
                        }
                        .disabled(isMutating)
                        .accessibilityIdentifier("schedule.detail.nativeEdit")
                    }

                    Menu {
                        Button {
                            showRevision = true
                        } label: {
                            Label("Edit with Oppi", systemImage: "text.bubble")
                        }
                        .disabled(isMutating)
                        .accessibilityIdentifier("schedule.detail.edit")

                        if schedule.status != .archived {
                            Button("Archive", role: .destructive) {
                                confirmArchive = true
                            }
                            .disabled(isMutating)
                            .accessibilityIdentifier("schedule.detail.archive")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Schedule actions")
                    .accessibilityIdentifier("schedule.detail.actions")
                }
            }
        }
        .task(id: scheduleId) { await load() }
        .refreshable { await load() }
        .fullScreenCover(isPresented: $showNativeEdit) {
            if let schedule {
                ScheduleNativeEditView(schedule: schedule) { updated, summary in
                    self.schedule = updated
                    onChanged(summary)
                }
            }
        }
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
        .sheet(isPresented: $showPromptReader) {
            if let schedule {
                ReviewableControlMarkdownView(
                    content: prompt(in: schedule.action),
                    domain: .schedules,
                    targetId: schedule.id,
                    targetName: schedule.name,
                    sourceLabel: "\(schedule.name) prompt",
                    sourcePath: "Schedules/\(schedule.id)/Prompt.md"
                )
            }
        }
        .alert("Archive this schedule?", isPresented: $confirmArchive) {
            Button("Archive", role: .destructive) {
                Task { await mutate(.archive) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops running and moves to Archived. You can restore it later.")
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

    private func scheduleSummaryHeader(_ schedule: AgentSchedule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(schedule.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .textSelection(.enabled)
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

            Label(schedule.trigger.detailTimingSummary(), systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.themeComment)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(schedule.trigger.detailTimingSummary())
                .accessibilityIdentifier("schedule.detail.when")
        }
        .padding(.vertical, 4)
    }

    private func enabledBinding(for schedule: AgentSchedule) -> Binding<Bool> {
        Binding(
            get: { schedule.status == .active },
            set: { isEnabled in
                guard !isMutating else { return }
                if isEnabled, schedule.status == .paused {
                    Task { await mutate(.resume) }
                } else if !isEnabled, schedule.status == .active {
                    Task { await mutate(.pause) }
                }
            }
        )
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.themeComment)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.themeFg)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func runWithSectionTitle(_ action: AgentScheduleAction) -> String {
        switch action {
        case .newSession:
            return "Run with"
        case .existingSession:
            return "Target"
        }
    }

    @ViewBuilder
    private func runWithDetail(_ action: AgentScheduleAction) -> some View {
        switch action {
        case .newSession(
            let workspaceId,
            _,
            let agentId,
            let model,
            let thinkingLevel,
            _,
            let name
        ):
            detailRow("Workspace", humanWorkspaceName(workspaceId))
            if let agentLabel = humanAgentName(agentId) {
                detailRow("Agent", agentLabel)
            }
            if let model, !model.isEmpty {
                detailRow("Model", SessionFormatting.shortModelName(model) ?? model)
            }
            if let thinkingLevel {
                detailRow("Thinking", thinkingLevel.displayTitle)
            }
            if let name, !name.isEmpty {
                detailRow("Session title", name)
            }
            Text("Starts a new session each run")
                .font(.caption)
                .foregroundStyle(.themeComment)
        case .existingSession(let workspaceId, let sessionId, _, let streamingBehavior):
            detailRow("Workspace", humanWorkspaceName(workspaceId))
            detailRow("Session", humanSessionTitle(sessionId))
            detailRow(
                "Delivery",
                streamingBehavior.map { $0 == .steer ? "Steers the session" : "Sends as follow-up" }
                    ?? "Auto"
            )
            Text("Sends into an existing session")
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
    }

    private func promptPreview(_ prompt: String) -> some View {
        Button {
            showPromptReader = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("What it does")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.themeFg)
                    Spacer(minLength: 8)
                    Text("Show instructions")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.themeBlue)
                }
                Text(prompt)
                    .font(.subheadline)
                    .foregroundStyle(.themeFg)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What it does. \(prompt). Show full schedule instructions")
        .accessibilityHint("Opens the prompt as full-screen Markdown")
        .accessibilityIdentifier("schedule.detail.prompt")
    }

    private func prompt(in action: AgentScheduleAction) -> String {
        switch action {
        case .newSession(_, let prompt, _, _, _, _, _),
             .existingSession(_, _, let prompt, _):
            return prompt
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
            async let fetchedAgents = apiClient.listAgents(includeArchived: true)
            schedule = try await fetchedSchedule
            runs = try await fetchedRuns
            if let agents = try? await fetchedAgents {
                agentNamesById = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
            }
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
            runs = scheduleRunsByInsertingNewest(run, into: runs, limit: 20)
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

    private func humanWorkspaceName(_ workspaceId: String) -> String {
        workspaceStore.workspaces.first(where: { $0.id == workspaceId })?.name
            ?? "Unknown workspace"
    }

    private func humanSessionTitle(_ sessionId: String) -> String {
        sessionStore.session(id: sessionId)?.displayTitle ?? "Existing session"
    }

    /// Prefer a resolved agent name. Never surface opaque agent IDs in primary UI.
    private func humanAgentName(_ agentId: String?) -> String? {
        guard let agentId, !agentId.isEmpty else { return nil }
        if let name = agentNamesById[agentId], !name.isEmpty {
            return name
        }
        return "Saved agent"
    }
}

private struct ScheduleRunRow: View {
    let run: AgentScheduleRunSummary
    let openSession: () -> Void

    var body: some View {
        Group {
            if run.sessionId != nil {
                Button(action: openSession) {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the run session")
            } else {
                rowContent
            }
        }
        .accessibilityIdentifier("schedule.run.\(run.id)")
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(tone.color)
                .frame(width: 24, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(run.status.rawValue.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("\(run.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(runSourceLabel)")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                if let errorSummary {
                    Text(errorSummary)
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            if run.sessionId != nil {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var errorSummary: String? {
        guard let error = run.error, !error.isEmpty else { return nil }
        if error.contains("approval_required_noninteractive") {
            return "Approval required — this action can’t run unattended."
        }
        return error
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ":", with: ": ")
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

func scheduleRunsByInsertingNewest(
    _ run: AgentScheduleRunSummary,
    into runs: [AgentScheduleRunSummary],
    limit: Int
) -> [AgentScheduleRunSummary] {
    guard limit > 0 else { return [] }
    let updated = [run] + runs.filter { $0.id != run.id }
    return Array(updated.sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        return $0.id > $1.id
    }.prefix(limit))
}

private extension AgentScheduleRunSummary {
    func withSessionId(_ sessionId: String) -> AgentScheduleRunSummary {
        var copy = self
        copy.sessionId = sessionId
        return copy
    }
}
