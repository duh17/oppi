import SwiftUI

struct ScheduleNativeEditView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(SessionStore.self) private var sessionStore

    let schedule: AgentSchedule
    let onSaved: (AgentSchedule, AgentScheduleSummary) -> Void

    @State private var name: String
    @State private var triggerDraft: ScheduleTriggerDraft
    @State private var prompt: String
    @State private var workspaceId: String
    @State private var agentId: String
    @State private var model: String
    @State private var thinkingLevel: ThinkingLevel?
    @State private var sessionName: String
    @State private var targetSessionId: String
    @State private var streamingBehavior: ExistingSessionStreamingBehavior?
    @State private var agents: [AgentDefinitionSummary] = []
    @State private var isShowingModelPicker = false
    @State private var isShowingTimeZonePicker = false
    @State private var isSaving = false
    @State private var error: String?

    private static let commonIntervals: [Int64] = [
        15 * 60_000,
        60 * 60_000,
        6 * 60 * 60_000,
        24 * 60 * 60_000,
        7 * 24 * 60 * 60_000,
    ]
    init(schedule: AgentSchedule, onSaved: @escaping (AgentSchedule, AgentScheduleSummary) -> Void) {
        self.schedule = schedule
        self.onSaved = onSaved
        _name = State(initialValue: schedule.name)
        _triggerDraft = State(initialValue: ScheduleTriggerDraft(trigger: schedule.trigger))
        _prompt = State(initialValue: schedule.action.prompt)

        switch schedule.action {
        case .newSession(
            let workspaceId,
            _,
            let agentId,
            let model,
            let thinkingLevel,
            _,
            let name
        ):
            _workspaceId = State(initialValue: workspaceId)
            _agentId = State(initialValue: agentId ?? "")
            _model = State(initialValue: model ?? "")
            _thinkingLevel = State(initialValue: thinkingLevel)
            _sessionName = State(initialValue: name ?? "")
            _targetSessionId = State(initialValue: "")
            _streamingBehavior = State(initialValue: nil)
        case .existingSession(
            let workspaceId,
            let sessionId,
            _,
            let streamingBehavior
        ):
            _workspaceId = State(initialValue: workspaceId)
            _agentId = State(initialValue: "")
            _model = State(initialValue: "")
            _thinkingLevel = State(initialValue: nil)
            _sessionName = State(initialValue: "")
            _targetSessionId = State(initialValue: sessionId)
            _streamingBehavior = State(initialValue: streamingBehavior)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workspaceId.isEmpty
            && (isNewSessionAction || !targetSessionId.isEmpty)
            && triggerDraft.canSave
            && !isSaving
    }

    private var isNewSessionAction: Bool {
        if case .newSession = schedule.action { return true }
        return false
    }

    private var availableSessions: [Session] {
        var sessions = sessionStore.listProjectionSessions(workspaceId: workspaceId)
        if let current = sessionStore.session(id: targetSessionId),
           !sessions.contains(where: { $0.id == current.id }) {
            sessions.append(current)
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    private var intervalOptions: [Int64] {
        Array(Set(Self.commonIntervals + [triggerDraft.intervalMs])).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Schedule") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("schedule.nativeEdit.name")

                    Picker("Cadence", selection: $triggerDraft.cadence) {
                        ForEach(ScheduleTriggerDraft.Cadence.allCases, id: \.self) { cadence in
                            Text(cadence.title).tag(cadence)
                        }
                    }
                    .accessibilityIdentifier("schedule.nativeEdit.cadence")

                    triggerControls

                    Button {
                        isShowingTimeZonePicker = true
                    } label: {
                        LabeledContent("Time Zone") {
                            HStack(spacing: 6) {
                                Text(timeZoneDisplayName(triggerDraft.timeZone))
                                    .foregroundStyle(.themeFg)
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.themeComment)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Choose the schedule time zone")
                    .accessibilityIdentifier("schedule.nativeEdit.timeZone")
                }

                Section("Instructions") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Schedule prompt")
                        .accessibilityIdentifier("schedule.nativeEdit.prompt")
                }

                Section(isNewSessionAction ? "Start New Session" : "Existing Session") {
                    Picker("Workspace", selection: $workspaceId) {
                        if !workspaceStore.workspaces.contains(where: { $0.id == workspaceId }) {
                            Text("Current workspace").tag(workspaceId)
                        }
                        ForEach(workspaceStore.workspaces) { workspace in
                            Text(workspace.name).tag(workspace.id)
                        }
                    }
                    .onChange(of: workspaceId) { _, newWorkspaceId in
                        guard !isNewSessionAction else { return }
                        targetSessionId = sessionStore
                            .listProjectionSessions(workspaceId: newWorkspaceId)
                            .first?.id ?? ""
                    }
                    .accessibilityIdentifier("schedule.nativeEdit.workspace")

                    if isNewSessionAction {
                        Picker("Agent", selection: $agentId) {
                            Text("No saved Agent").tag("")
                            if !agentId.isEmpty, !agents.contains(where: { $0.id == agentId }) {
                                Text("Current saved Agent").tag(agentId)
                            }
                            ForEach(agents) { agent in
                                Text(agent.name).tag(agent.id)
                            }
                        }
                        .accessibilityIdentifier("schedule.nativeEdit.agent")

                        Button {
                            isShowingModelPicker = true
                        } label: {
                            LabeledContent("Model") {
                                Text(modelDisplayName)
                                    .foregroundStyle(.themeFg)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("schedule.nativeEdit.model")

                        if !model.isEmpty {
                            Button("Use Agent or Server Default Model") { model = "" }
                                .foregroundStyle(.themeBlue)
                        }

                        Picker("Thinking", selection: $thinkingLevel) {
                            Text("Agent or server default").tag(ThinkingLevel?.none)
                            ForEach(ThinkingLevel.allCases) { level in
                                Text(level.displayTitle).tag(Optional(level))
                            }
                        }
                        .accessibilityIdentifier("schedule.nativeEdit.thinking")

                        TextField("Session title (optional)", text: $sessionName)
                            .accessibilityIdentifier("schedule.nativeEdit.sessionName")
                    } else {
                        Picker("Session", selection: $targetSessionId) {
                            if !targetSessionId.isEmpty,
                               !availableSessions.contains(where: { $0.id == targetSessionId }) {
                                Text("Current session").tag(targetSessionId)
                            }
                            ForEach(availableSessions) { session in
                                Text(session.displayTitle).tag(session.id)
                            }
                        }
                        .accessibilityIdentifier("schedule.nativeEdit.session")

                        Picker("Delivery", selection: $streamingBehavior) {
                            Text("Automatic").tag(ExistingSessionStreamingBehavior?.none)
                            ForEach(ExistingSessionStreamingBehavior.allCases, id: \.rawValue) { behavior in
                                Text(behavior.displayName).tag(Optional(behavior))
                            }
                        }
                        .accessibilityIdentifier("schedule.nativeEdit.delivery")
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.themeRed)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("Edit Schedule")
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
                    .accessibilityIdentifier("schedule.nativeEdit.save")
                }
            }
            .task { await loadAgents() }
            .interactiveDismissDisabled(isSaving)
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheet(currentModel: model.managementNilIfBlank) { selected in
                model = ModelSwitchPolicy.fullModelID(for: selected)
                AppPreferences.RecentModels.record(model)
            }
        }
        .sheet(isPresented: $isShowingTimeZonePicker) {
            TimeZonePickerView(selection: $triggerDraft.timeZone)
        }
    }

    @ViewBuilder
    private var triggerControls: some View {
        switch triggerDraft.cadence {
        case .oneTime:
            DatePicker(
                "Run At",
                selection: $triggerDraft.oneTimeDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .environment(\.timeZone, triggerTimeZone)
            .accessibilityIdentifier("schedule.nativeEdit.runAt")
        case .interval:
            Picker("Repeat", selection: $triggerDraft.intervalMs) {
                ForEach(intervalOptions, id: \.self) { interval in
                    Text("Every \(AgentScheduleTrigger.intervalSummary(interval))")
                        .tag(interval)
                }
            }
            .accessibilityIdentifier("schedule.nativeEdit.interval")
        case .daily:
            DatePicker("Time", selection: $triggerDraft.timeOfDay, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, triggerTimeZone)
                .accessibilityIdentifier("schedule.nativeEdit.time")
        case .weekly:
            Picker("Day", selection: $triggerDraft.weekday) {
                ForEach(0..<7, id: \.self) { weekday in
                    Text(ScheduleTriggerDraft.weekdayTitle(weekday)).tag(weekday)
                }
            }
            DatePicker("Time", selection: $triggerDraft.timeOfDay, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, triggerTimeZone)
                .accessibilityIdentifier("schedule.nativeEdit.time")
        case .custom:
            VStack(alignment: .leading, spacing: 8) {
                Text("Cron Expression")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.themeFg)

                TextField("0 9 * * 1-5", text: $triggerDraft.customExpression)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Cron expression")
                    .accessibilityHint(triggerDraft.customAccessibilityHint)
                    .accessibilityIdentifier("schedule.nativeEdit.cronExpression")

                Text(triggerDraft.customFieldLabels)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)

                if let expressionError = triggerDraft.customExpressionError {
                    Label(expressionError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                        .accessibilityIdentifier("schedule.nativeEdit.cronError")
                } else {
                    Text(triggerDraft.customGuidanceText)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var triggerTimeZone: TimeZone {
        TimeZone(identifier: triggerDraft.timeZone) ?? .current
    }

    private var modelDisplayName: String {
        guard let model = model.managementNilIfBlank else { return "Agent or server default" }
        return SessionFormatting.shortModelName(model) ?? model
    }

    @MainActor
    private func loadAgents() async {
        guard let apiClient else { return }
        do {
            agents = try await apiClient.listAgents()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }
        guard let trigger = triggerDraft.makeTrigger() else {
            error = "Choose a supported schedule cadence"
            return
        }

        let action: AgentScheduleAction
        switch schedule.action {
        case .newSession(_, _, _, _, _, let worktreeId, _):
            action = .newSession(
                workspaceId: workspaceId,
                prompt: prompt,
                agentId: agentId.managementNilIfBlank,
                model: model.managementNilIfBlank,
                thinkingLevel: thinkingLevel,
                worktreeId: worktreeId,
                name: sessionName.managementNilIfBlank
            )
        case .existingSession:
            action = .existingSession(
                workspaceId: workspaceId,
                sessionId: targetSessionId,
                prompt: prompt,
                streamingBehavior: streamingBehavior
            )
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let summary = try await apiClient.updateAgentScheduleNative(
                scheduleId: schedule.id,
                name: name,
                trigger: trigger,
                action: action
            )
            var updated = schedule
            updated.name = summary.name
            updated.trigger = trigger
            updated.action = action
            updated.updatedAt = summary.updatedAt
            onSaved(updated, summary)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func timeZoneDisplayName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }
}

struct ScheduleTriggerDraft: Equatable {
    enum Cadence: String, CaseIterable, Equatable {
        case oneTime
        case interval
        case daily
        case weekly
        case custom

        var title: String {
            switch self {
            case .oneTime: "One Time"
            case .interval: "Interval"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .custom: "Custom"
            }
        }
    }

    var cadence: Cadence
    var oneTimeDate: Date
    var intervalMs: Int64
    var timeOfDay: Date
    var weekday: Int
    var timeZone: String
    var customExpression: String

    init(trigger: AgentScheduleTrigger, now: Date = Date()) {
        oneTimeDate = now
        intervalMs = 60 * 60_000
        timeOfDay = now
        weekday = 1
        timeZone = trigger.timeZone
        customExpression = ""

        switch trigger {
        case .at(let date, _):
            cadence = .oneTime
            oneTimeDate = date
        case .every(let intervalMs, _):
            cadence = .interval
            self.intervalMs = intervalMs
        case .cron(let expression, let timeZone):
            customExpression = expression
            if let parsed = Self.parseSimpleCron(expression) {
                cadence = parsed.weekday == nil ? .daily : .weekly
                weekday = parsed.weekday ?? 1
                timeOfDay = Self.dateForTime(
                    hour: parsed.hour,
                    minute: parsed.minute,
                    timeZone: timeZone,
                    fallback: now
                )
            } else {
                cadence = .custom
            }
        }
    }

    var customFieldLabels: String {
        hasSecondsField
            ? "second  minute  hour  day  month  weekday"
            : "minute  hour  day  month  weekday"
    }

    var customAccessibilityHint: String {
        hasSecondsField
            ? "Second, minute, hour, day, month, and weekday. Seconds must be zero."
            : "Minute, hour, day, month, and weekday"
    }

    var customGuidanceText: String {
        if hasSecondsField {
            return "Seconds must be 0. Example: 0 0 9 * * 1-5 runs weekdays at 9:00."
        }
        return "Example: 0 9 * * 1-5 runs weekdays at 9:00. */15 * * * * runs every 15 minutes."
    }

    private var hasSecondsField: Bool {
        customExpression.split(whereSeparator: { $0.isWhitespace }).count == 6
    }

    var customExpressionError: String? {
        guard cadence == .custom else { return nil }
        let fields = customExpression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5 || fields.count == 6 else {
            return "Enter 5 fields, or 6 with seconds first."
        }
        // The server accepts six fields for parser compatibility but schedules at minute resolution.
        if fields.count == 6, fields[0] != "0" {
            return "Seconds must be 0 because schedules run at minute resolution."
        }
        let ranges = fields.count == 6
            ? [(0, 0), (0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]
            : [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]
        guard zip(fields, ranges).allSatisfy({
            Self.isValidCronField($0.0, range: $0.1)
        }) else {
            return "Use valid numbers, *, lists, ranges, or / steps for each field."
        }
        return nil
    }

    var canSave: Bool {
        cadence != .custom || customExpressionError == nil
    }

    func makeTrigger() -> AgentScheduleTrigger? {
        switch cadence {
        case .oneTime:
            return .at(oneTimeDate, timeZone: timeZone)
        case .interval:
            return .every(intervalMs: intervalMs, timeZone: timeZone)
        case .daily:
            let time = hourAndMinute()
            return .cron(expression: "\(time.minute) \(time.hour) * * *", timeZone: timeZone)
        case .weekly:
            let time = hourAndMinute()
            return .cron(
                expression: "\(time.minute) \(time.hour) * * \(weekday)",
                timeZone: timeZone
            )
        case .custom:
            guard customExpressionError == nil else { return nil }
            return .cron(
                expression: customExpression.trimmingCharacters(in: .whitespacesAndNewlines),
                timeZone: timeZone
            )
        }
    }

    static func weekdayTitle(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let normalized = min(max(weekday, 0), 6)
        return symbols[normalized]
    }

    private func hourAndMinute() -> (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: timeOfDay)
        return (components.hour ?? 0, components.minute ?? 0)
    }

    private static func parseSimpleCron(_ expression: String) -> (hour: Int, minute: Int, weekday: Int?)? {
        let fields = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 5,
              let minute = Int(fields[0]), (0...59).contains(minute),
              let hour = Int(fields[1]), (0...23).contains(hour),
              fields[2] == "*", fields[3] == "*" else { return nil }
        if fields[4] == "*" {
            return (hour, minute, nil)
        }
        guard let weekday = Int(fields[4]), (0...7).contains(weekday) else { return nil }
        return (hour, minute, weekday == 7 ? 0 : weekday)
    }

    private static func isValidCronField(_ field: String, range: (Int, Int)) -> Bool {
        let segments = field.split(separator: ",", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { segment in
            let stepParts = segment.split(separator: "/", omittingEmptySubsequences: false)
            guard stepParts.count <= 2, let base = stepParts.first, !base.isEmpty else { return false }
            if stepParts.count == 2 {
                guard let step = parseUnsignedCronNumber(stepParts[1]), step > 0 else { return false }
            }
            if base == "*" { return true }

            let rangeParts = base.split(separator: "-", omittingEmptySubsequences: false)
            if rangeParts.count == 2,
               let lower = parseUnsignedCronNumber(rangeParts[0]),
               let upper = parseUnsignedCronNumber(rangeParts[1]) {
                return range.0 <= lower && lower <= upper && upper <= range.1
            }
            guard rangeParts.count == 1,
                  let value = parseUnsignedCronNumber(base) else { return false }
            return (range.0...range.1).contains(value)
        }
    }

    private static func parseUnsignedCronNumber(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }

    private static func dateForTime(
        hour: Int,
        minute: Int,
        timeZone: String,
        fallback: Date
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        var components = calendar.dateComponents([.year, .month, .day], from: fallback)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? fallback
    }
}

private struct TimeZonePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var searchText = ""

    private var identifiers: [String] {
        guard !searchText.isEmpty else { return TimeZone.knownTimeZoneIdentifiers }
        return TimeZone.knownTimeZoneIdentifiers.filter {
            $0.localizedCaseInsensitiveContains(searchText)
                || $0.replacingOccurrences(of: "_", with: " ")
                    .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(identifiers, id: \.self) { identifier in
                Button {
                    selection = identifier
                    dismiss()
                } label: {
                    HStack {
                        Text(identifier.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(.themeFg)
                        Spacer(minLength: 8)
                        if identifier == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.themeBlue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Time Zone")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search time zones")
            .themedListSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
