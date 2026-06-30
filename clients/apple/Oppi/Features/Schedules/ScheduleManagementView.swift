import SwiftUI

struct ScheduleManagementView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var schedules: [AgentScheduleSummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showEditor = false

    var body: some View {
        List {
            if isLoading && schedules.isEmpty {
                ProgressView("Loading schedules…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.themeBg)
            } else if schedules.isEmpty {
                ContentUnavailableView(
                    "No Schedules",
                    systemImage: "clock.badge.plus",
                    description: Text("Create timed prompts that launch a fresh session or nudge an existing one.")
                )
                .listRowBackground(Color.themeBg)
            } else {
                Section {
                    ForEach(schedules) { schedule in
                        NavigationLink {
                            ScheduleDetailView(scheduleId: schedule.id)
                        } label: {
                            ScheduleSummaryRow(schedule: schedule)
                        }
                        .accessibilityIdentifier("schedules.row.\(schedule.id)")
                    }
                } header: {
                    Text("Schedules")
                } footer: {
                    Text("Schedules store timing and a target action. The Agent, workspace, worktree, and prompt are resolved when the run fires.")
                }
            }
        }
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Schedule")
                .accessibilityIdentifier("schedules.create.open")
            }
        }
        .refreshable { await loadSchedules() }
        .task { await loadSchedules() }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                ScheduleEditView(schedule: nil) {
                    await loadSchedules()
                }
            }
        }
        .alert("Schedules", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
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
}

private struct ScheduleSummaryRow: View {
    let schedule: AgentScheduleSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: schedule.status == .active ? "clock.badge.checkmark" : "clock")
                .font(.title3)
                .foregroundStyle(statusTone.color)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(schedule.name)
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)

                    StatusPill(
                        text: schedule.status.rawValue.capitalized,
                        tone: statusTone,
                        emphasis: .tinted,
                        size: .mini
                    )
                }

                Text(schedule.trigger.displaySummary)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)

                Text("\(schedule.action.type.displayName) · \(schedule.action.promptChars) characters")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(schedule.updatedAt.relativeString())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 4)
    }

    private var statusTone: StatusPillTone {
        switch schedule.status {
        case .active:
            return .success
        case .paused:
            return .warning
        case .archived:
            return .neutral
        }
    }
}

private struct ScheduleDetailView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppNavigation.self) private var navigation

    let scheduleId: String

    @State private var schedule: AgentSchedule?
    @State private var runs: [AgentScheduleRunSummary] = []
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var error: String?
    @State private var showEditor = false

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
                    }

                    Button(role: .destructive) {
                        Task { await mutate(.archive) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .disabled(isMutating || schedule.status == .archived)
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
                    Button("Edit") { showEditor = true }
                        .disabled(isMutating)
                        .accessibilityIdentifier("schedule.detail.edit")
                }
            }
        }
        .task(id: scheduleId) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showEditor) {
            if let schedule {
                NavigationStack {
                    ScheduleEditView(schedule: schedule) {
                        await load()
                    }
                }
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
        case .newSession(let workspaceId, let prompt, let model, let worktreeId, let name, _):
            detailRow("Type", "New session")
            detailRow("Workspace", workspaceName(workspaceId))
            if let worktreeId, !worktreeId.isEmpty { detailRow("Worktree", worktreeId) }
            if let name, !name.isEmpty { detailRow("Session name", name) }
            if let model, !model.isEmpty { detailRow("Model", model) }
            promptPreview(prompt)
        case .existingSession(let workspaceId, let sessionId, let prompt, let streamingBehavior, _):
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
            }
            if var current = schedule {
                current.status = updated.status
                current.updatedAt = updated.updatedAt
                current.archivedAt = updated.archivedAt
                schedule = current
            }
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
                    HStack(spacing: 6) {
                        Text(run.kind.rawValue.capitalized)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeFg)
                        StatusPill(text: run.status.rawValue.capitalized, tone: tone, emphasis: .tinted, size: .mini)
                    }
                    Text(run.createdAt.relativeString())
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

private struct ScheduleEditView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss

    let schedule: AgentSchedule?
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var triggerKind: ScheduleTriggerKind = .at
    @State private var atDate = Date().addingTimeInterval(3_600)
    @State private var intervalValue = "1"
    @State private var intervalUnit: ScheduleIntervalUnit = .hour
    @State private var cronExpression = "0 9 * * *"
    @State private var timeZone = TimeZone.current.identifier

    @State private var actionKind: AgentScheduleActionKind = .newSession
    @State private var selectedWorkspaceId = ""
    @State private var selectedSessionId = ""
    @State private var prompt = ""
    @State private var model = ""
    @State private var worktreeId = ""
    @State private var sessionName = ""
    @State private var streamingBehavior: ExistingSessionStreamingBehavior = .followUp

    @State private var isSaving = false
    @State private var error: String?

    private var workspaces: [Workspace] { workspaceStore.workspaces }

    private var sessionsForSelectedWorkspace: [Session] {
        guard !selectedWorkspaceId.isEmpty else { return [] }
        return sessionStore.listProjectionSessions(workspaceId: selectedWorkspaceId)
            .filter { $0.status != .stopped }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedWorkspaceId.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (actionKind == .newSession || !selectedSessionId.isEmpty)
            && !isSaving
    }

    var body: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("schedule.edit.name")
            }

            Section("When") {
                Picker("Type", selection: $triggerKind) {
                    ForEach(ScheduleTriggerKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                switch triggerKind {
                case .at:
                    DatePicker("Date", selection: $atDate, displayedComponents: [.date, .hourAndMinute])
                case .every:
                    HStack {
                        TextField("Interval", text: $intervalValue)
                            .keyboardType(.numberPad)
                        Picker("Unit", selection: $intervalUnit) {
                            ForEach(ScheduleIntervalUnit.allCases, id: \.self) { unit in
                                Text(unit.displayName).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                case .cron:
                    TextField("Cron expression", text: $cronExpression)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }

                TextField("Time zone", text: $timeZone)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Action") {
                Picker("Target", selection: $actionKind) {
                    Text("New Session").tag(AgentScheduleActionKind.newSession)
                    Text("Existing Session").tag(AgentScheduleActionKind.existingSession)
                }
                .pickerStyle(.segmented)

                Picker("Workspace", selection: $selectedWorkspaceId) {
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .onChange(of: selectedWorkspaceId) { _, _ in
                    selectedSessionId = sessionsForSelectedWorkspace.first?.id ?? ""
                }

                if actionKind == .existingSession {
                    Picker("Session", selection: $selectedSessionId) {
                        ForEach(sessionsForSelectedWorkspace) { session in
                            Text(session.displayTitle).tag(session.id)
                        }
                    }
                    Picker("Delivery", selection: $streamingBehavior) {
                        ForEach(ExistingSessionStreamingBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                } else {
                    TextField("Session name", text: $sessionName)
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Worktree ID (optional)", text: $worktreeId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section("Prompt") {
                TextEditor(text: $prompt)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("schedule.edit.prompt")
            }

            if schedule == nil {
                Section("Approval") {
                    Text("Creating automatic schedules from iOS requires an accepted approval ref. Use `oppi schedule create --approval-ref …` for now.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.themeOrange)
                }
            }
        }
        .navigationTitle(schedule == nil ? "New Schedule" : "Edit Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("schedule.edit.save")
            }
        }
        .onAppear(perform: populate)
    }

    @MainActor
    private func save() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            guard let schedule else {
                throw ScheduleEditError.approvalRequired
            }
            let trigger = try buildTrigger()
            let action = buildAction()
            _ = try await apiClient.updateAgentSchedule(
                scheduleId: schedule.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                trigger: trigger,
                action: action
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func populate() {
        guard let schedule else {
            name = "Scheduled check"
            selectedWorkspaceId = workspaces.first?.id ?? ""
            selectedSessionId = sessionsForSelectedWorkspace.first?.id ?? ""
            return
        }

        name = schedule.name
        timeZone = schedule.trigger.timeZone
        switch schedule.trigger {
        case .at(let date, _):
            triggerKind = .at
            atDate = date
        case .every(let intervalMs, _):
            triggerKind = .every
            let resolved = ScheduleIntervalUnit.valueAndUnit(for: intervalMs)
            intervalValue = String(resolved.value)
            intervalUnit = resolved.unit
        case .cron(let expression, _):
            triggerKind = .cron
            cronExpression = expression
        }

        switch schedule.action {
        case .newSession(let workspaceId, let prompt, let model, let worktreeId, let name, _):
            actionKind = .newSession
            selectedWorkspaceId = workspaceId
            self.prompt = prompt
            self.model = model ?? ""
            self.worktreeId = worktreeId ?? ""
            sessionName = name ?? ""
        case .existingSession(let workspaceId, let sessionId, let prompt, let streamingBehavior, _):
            actionKind = .existingSession
            selectedWorkspaceId = workspaceId
            selectedSessionId = sessionId
            self.prompt = prompt
            self.streamingBehavior = streamingBehavior ?? .followUp
        }
    }

    private func buildTrigger() throws -> AgentScheduleTrigger {
        let cleanTimeZone = timeZone.nilIfBlank ?? TimeZone.current.identifier
        switch triggerKind {
        case .at:
            return .at(atDate, timeZone: cleanTimeZone)
        case .every:
            guard let value = Int64(intervalValue.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
                throw ScheduleEditError.invalidInterval
            }
            let interval = value.multipliedReportingOverflow(by: intervalUnit.multiplierMs)
            guard !interval.overflow else { throw ScheduleEditError.intervalTooLarge }
            return .every(intervalMs: interval.partialValue, timeZone: cleanTimeZone)
        case .cron:
            return .cron(expression: cronExpression.trimmingCharacters(in: .whitespacesAndNewlines), timeZone: cleanTimeZone)
        }
    }

    private func buildAction() -> AgentScheduleAction {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let approvalRefs = schedule?.action.approvalRefs
        switch actionKind {
        case .newSession:
            return .newSession(
                workspaceId: selectedWorkspaceId,
                prompt: cleanPrompt,
                model: model.nilIfBlank,
                worktreeId: worktreeId.nilIfBlank,
                name: sessionName.nilIfBlank,
                approvalRefs: approvalRefs
            )
        case .existingSession:
            return .existingSession(
                workspaceId: selectedWorkspaceId,
                sessionId: selectedSessionId,
                prompt: cleanPrompt,
                streamingBehavior: streamingBehavior,
                approvalRefs: approvalRefs
            )
        }
    }
}

private enum ScheduleTriggerKind: CaseIterable {
    case at
    case every
    case cron

    var displayName: String {
        switch self {
        case .at:
            return "At"
        case .every:
            return "Every"
        case .cron:
            return "Cron"
        }
    }
}

private enum ScheduleIntervalUnit: CaseIterable {
    case minute
    case hour
    case day

    var displayName: String {
        switch self {
        case .minute:
            return "Minutes"
        case .hour:
            return "Hours"
        case .day:
            return "Days"
        }
    }

    var multiplierMs: Int64 {
        switch self {
        case .minute:
            return 60_000
        case .hour:
            return 3_600_000
        case .day:
            return 86_400_000
        }
    }

    static func valueAndUnit(for intervalMs: Int64) -> (value: Int64, unit: ScheduleIntervalUnit) {
        if intervalMs % ScheduleIntervalUnit.day.multiplierMs == 0 {
            return (intervalMs / ScheduleIntervalUnit.day.multiplierMs, .day)
        }
        if intervalMs % ScheduleIntervalUnit.hour.multiplierMs == 0 {
            return (intervalMs / ScheduleIntervalUnit.hour.multiplierMs, .hour)
        }
        return (max(1, intervalMs / ScheduleIntervalUnit.minute.multiplierMs), .minute)
    }
}

private enum ScheduleEditError: LocalizedError {
    case approvalRequired
    case invalidInterval
    case intervalTooLarge

    var errorDescription: String? {
        switch self {
        case .approvalRequired:
            return "Creating automatic schedules from iOS requires an accepted approval ref. Use the Oppi CLI with --approval-ref for now."
        case .invalidInterval:
            return "Interval must be a positive number."
        case .intervalTooLarge:
            return "Interval is too large."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
