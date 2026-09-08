import Foundation
import OSLog

private let catalogLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacCatalogStore"
)

@MainActor
@Observable
final class MacCatalogStore {
    static let shared = MacCatalogStore()

    var agents: [AgentDefinitionSummary] = []
    var selectedAgentID: String?
    var loadedAgent: StoredAgentDefinition?
    var agentDraft: MacAgentEditorDraft?
    var isCreatingAgent = false

    var schedules: [AgentScheduleSummary] = []
    var scheduleStatusFilter: AgentScheduleStatus = .active
    var selectedScheduleID: String? {
        didSet {
            guard oldValue != selectedScheduleID else { return }
            scheduleSelectionGeneration &+= 1
            scheduleHistoryGeneration &+= 1
            loadedSchedule = nil
            scheduleDraft = nil
            scheduleRuns = []
            scheduleRunError = nil
            scheduleRunMessage = nil
            scheduleHistoryError = nil
            scheduleOpenError = nil
            openingScheduleRunID = nil
            isLoadingScheduleRuns = false
            hasLoadedScheduleRuns = false
        }
    }
    private(set) var scheduleRuns: [AgentScheduleRunSummary] = []
    private(set) var scheduleRunError: String?
    private(set) var scheduleRunMessage: String?
    private(set) var scheduleHistoryError: String?
    private(set) var scheduleOpenError: String?
    private(set) var openingScheduleRunID: String?
    private(set) var isLoadingScheduleRuns = false
    private(set) var hasLoadedScheduleRuns = false
    private var pendingScheduleIDs: Set<String> = []
    private var scheduleSelectionGeneration: UInt64 = 0
    private var scheduleHistoryGeneration: UInt64 = 0
    private var scheduleDetailGeneration: UInt64 = 0

    var isRunningSchedule: Bool {
        selectedScheduleID.map { pendingScheduleIDs.contains($0) } ?? false
    }

    var canRunSelectedSchedule: Bool {
        !isCreatingSchedule && selectedSchedule != nil && selectedSchedule?.status != .archived
            && !isSaving && !isRunningSchedule && openingScheduleRunID == nil
    }
    var loadedSchedule: AgentSchedule?
    var scheduleDraft: MacScheduleEditorDraft?
    var isCreatingSchedule = false
    var workspaces: [Workspace] = []

    var skills: [ServerSkillSummary] = []
    var selectedSkillID: String?
    var loadedSkill: ServerSkillDetail?

    var extensions: [ServerExtensionSummary] = []
    var selectedExtensionID: String?
    var loadedExtension: ServerExtensionDetail?

    var query = ""
    var controlLaunchDraft: MacControlSessionLaunchDraft?
    var controlLaunchError: String?
    private(set) var isSaving = false
    private(set) var isLaunchingControlSession = false

    private var loadedSections: Set<MacSidebarSection> = []
    private var loadingSections: Set<MacSidebarSection> = []
    private var errors: [MacSidebarSection: String] = [:]
    private var generation: UInt64 = 0
    private var frozenControlLaunchRequest: MacWorkspaceClient.CreateControlSessionRequest?
    private var frozenControlLaunchDraft: MacControlSessionLaunchDraft?

    private let makeClient: () -> MacWorkspaceClient?

    init(client: MacWorkspaceClient? = nil) {
        if let client {
            makeClient = { client }
        } else {
            makeClient = { MacWorkspaceClient.localOwner() }
        }
    }

    var selectedAgent: AgentDefinitionSummary? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    var selectedSchedule: AgentScheduleSummary? {
        guard let selectedScheduleID else { return nil }
        return schedules.first { $0.id == selectedScheduleID }
    }

    var selectedSkill: ServerSkillSummary? {
        guard let selectedSkillID else { return nil }
        return skills.first { $0.id == selectedSkillID }
    }

    var selectedExtension: ServerExtensionSummary? {
        guard let selectedExtensionID else { return nil }
        return extensions.first { $0.id == selectedExtensionID }
    }

    func lastError(for section: MacSidebarSection) -> String? {
        errors[section]
    }

    func isLoading(_ section: MacSidebarSection) -> Bool {
        loadingSections.contains(section)
    }

    func hasLoaded(_ section: MacSidebarSection) -> Bool {
        loadedSections.contains(section)
    }

    func contentState(for section: MacSidebarSection) -> MacCatalogContentState {
        let hasVisibleRows: Bool
        let isFilteredNoResults: Bool
        switch section {
        case .agents:
            let presentation = MacCatalogAgentListPresentation(agents: agents, query: query)
            hasVisibleRows = !presentation.rows.isEmpty
            isFilteredNoResults = presentation.isFilteredNoResults
        case .schedules:
            let presentation = MacCatalogScheduleListPresentation(
                schedules: schedules,
                status: scheduleStatusFilter,
                query: query
            )
            hasVisibleRows = !presentation.rows.isEmpty
            isFilteredNoResults = presentation.isFilteredNoResults
        case .skills:
            let presentation = MacCatalogSkillListPresentation(skills: skills, query: query)
            hasVisibleRows = !presentation.visible.isEmpty
            isFilteredNoResults = presentation.isFilteredNoResults
        case .extensions:
            let presentation = MacCatalogExtensionListPresentation(extensions: extensions, query: query)
            hasVisibleRows = !presentation.visible.isEmpty
            isFilteredNoResults = presentation.isFilteredNoResults
        default:
            hasVisibleRows = false
            isFilteredNoResults = false
        }
        return .resolve(
            hasLoaded: hasLoaded(section),
            isLoading: isLoading(section),
            lastError: lastError(for: section),
            hasVisibleRows: hasVisibleRows,
            isFilteredNoResults: isFilteredNoResults
        )
    }

    func load(_ section: MacSidebarSection) async {
        generation &+= 1
        let requestGeneration = generation
        loadingSections.insert(section)
        errors[section] = nil

        guard let client = makeClient() else {
            loadingSections.remove(section)
            errors[section] = "Local server is unavailable."
            return
        }

        do {
            switch section {
            case .agents:
                let rows = try await client.listAgents()
                guard requestGeneration == generation else { return }
                agents = rows
                if selectedAgentID == nil && !isCreatingAgent {
                    selectedAgentID = MacCatalogAgentRow.pi.id
                }
            case .schedules:
                async let fetchedSchedules = client.listAgentSchedules()
                async let fetchedWorkspaces = client.listWorkspaceCatalog()
                let (rows, catalog) = try await (fetchedSchedules, fetchedWorkspaces)
                guard requestGeneration == generation else { return }
                schedules = rows
                workspaces = catalog.workspaces
                if selectedScheduleID == nil && !isCreatingSchedule {
                    selectedScheduleID = MacCatalogScheduleListPresentation(
                        schedules: rows,
                        status: scheduleStatusFilter,
                        query: query
                    ).rows.first?.id
                }
            case .skills:
                let rows = try await client.listServerSkills()
                guard requestGeneration == generation else { return }
                skills = rows
                if selectedSkillID == nil {
                    selectedSkillID = MacCatalogSkillListPresentation(skills: rows, query: query).visible.first?.id
                }
            case .extensions:
                let catalog = try await client.listServerExtensions()
                guard requestGeneration == generation else { return }
                extensions = catalog.extensions
                if selectedExtensionID == nil {
                    selectedExtensionID = MacCatalogExtensionListPresentation(
                        extensions: catalog.extensions,
                        query: query
                    ).visible.first?.id
                }
            default:
                break
            }
            loadedSections.insert(section)
            loadingSections.remove(section)
        } catch {
            guard requestGeneration == generation else { return }
            loadingSections.remove(section)
            errors[section] = error.localizedDescription
            catalogLogger.error("Catalog load failed for \(section.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectAgent(_ id: String?) {
        isCreatingAgent = false
        selectedAgentID = id
        loadedAgent = nil
        agentDraft = id == MacCatalogAgentRow.pi.id ? nil : nil
        if id == MacCatalogAgentRow.pi.id {
            agentDraft = nil
        }
    }

    func beginCreateAgent() {
        isCreatingAgent = true
        selectedAgentID = nil
        loadedAgent = nil
        agentDraft = .blank()
    }

    func loadSelectedAgent() async {
        guard !isCreatingAgent,
              let requestedID = selectedAgentID,
              requestedID != MacCatalogAgentRow.pi.id,
              let client = makeClient() else { return }
        do {
            let agent = try await client.getAgent(requestedID)
            guard !isCreatingAgent, selectedAgentID == requestedID else { return }
            loadedAgent = agent
            agentDraft = .from(agent)
        } catch {
            guard !isCreatingAgent, selectedAgentID == requestedID else { return }
            errors[.agents] = error.localizedDescription
        }
    }

    func saveAgent(_ draft: MacAgentEditorDraft) async throws {
        guard draft.canSave, let client = makeClient() else { return }
        isSaving = true
        defer { isSaving = false }
        if isCreatingAgent {
            let created = try await client.createAgent(draft.makeDefinition())
            upsert(created)
            isCreatingAgent = false
            selectedAgentID = created.id
            loadedAgent = created
            agentDraft = .from(created)
            return
        }
        guard let selectedAgentID, let loadedAgent else { return }
        let updated = try await client.updateAgent(
            agentId: selectedAgentID,
            definition: draft.makeDefinition(preserving: loadedAgent.definition)
        )
        upsert(updated)
        self.loadedAgent = updated
        agentDraft = .from(updated)
    }

    func archiveSelectedAgent() async throws {
        guard let selectedAgentID,
              selectedAgentID != MacCatalogAgentRow.pi.id,
              let client = makeClient() else { return }
        isSaving = true
        defer { isSaving = false }
        _ = try await client.archiveAgent(agentId: selectedAgentID)
        agents.removeAll { $0.id == selectedAgentID }
        self.selectedAgentID = MacCatalogAgentRow.pi.id
        loadedAgent = nil
        agentDraft = nil
    }

    func applyScheduleStatusFilter(_ status: AgentScheduleStatus) {
        if scheduleStatusFilter != status {
            scheduleStatusFilter = status
        }
        let nextID = MacCatalogScheduleListPresentation(
            schedules: schedules,
            status: status,
            query: query
        ).selectedID(keeping: selectedScheduleID)
        guard selectedScheduleID != nextID else { return }
        selectedScheduleID = nextID
        if nextID != nil {
            isCreatingSchedule = false
        }
    }

    func selectSchedule(_ id: String?) {
        isCreatingSchedule = false
        selectedScheduleID = id
        loadedSchedule = nil
        scheduleDraft = nil
    }

    func beginCreateSchedule() {
        isCreatingSchedule = true
        selectedScheduleID = nil
        loadedSchedule = nil
        scheduleDraft = .blank(workspaceId: workspaces.first?.id ?? "")
    }

    func loadSelectedSchedule() async {
        guard !isCreatingSchedule, let requestedID = selectedScheduleID, let client = makeClient() else { return }
        let selection = scheduleSelectionGeneration
        scheduleDetailGeneration &+= 1
        let detail = scheduleDetailGeneration
        async let history: Void = refreshScheduleRuns()
        do {
            let schedule = try await client.getAgentSchedule(requestedID)
            guard !Task.isCancelled, selection == scheduleSelectionGeneration,
                  detail == scheduleDetailGeneration, !isCreatingSchedule else { return }
            loadedSchedule = schedule
            scheduleDraft = .from(schedule, fallbackWorkspaceId: workspaces.first?.id ?? "")
        } catch {
            guard !Task.isCancelled, selection == scheduleSelectionGeneration,
                  detail == scheduleDetailGeneration else { return }
            errors[.schedules] = error.localizedDescription
        }
        await history
    }

    func refreshScheduleRuns() async {
        guard !isCreatingSchedule, let id = selectedScheduleID else { return }
        scheduleHistoryGeneration &+= 1
        let request = scheduleHistoryGeneration
        let selection = scheduleSelectionGeneration
        isLoadingScheduleRuns = true
        scheduleHistoryError = nil
        defer {
            if request == scheduleHistoryGeneration { isLoadingScheduleRuns = false }
        }
        guard let client = makeClient() else {
            scheduleHistoryError = "Local server is unavailable."
            return
        }
        do {
            let runs = try await client.listAgentScheduleRuns(scheduleId: id)
            guard !Task.isCancelled, request == scheduleHistoryGeneration,
                  selection == scheduleSelectionGeneration else { return }
            scheduleRuns = runs
            hasLoadedScheduleRuns = true
        } catch {
            guard !Task.isCancelled, request == scheduleHistoryGeneration,
                  selection == scheduleSelectionGeneration else { return }
            scheduleHistoryError = error.localizedDescription
        }
    }

    func runSelectedScheduleNow() async -> MacSelectedSessionTarget? {
        guard canRunSelectedSchedule, let id = selectedScheduleID else { return nil }
        guard let client = makeClient() else {
            scheduleRunError = "Local server is unavailable."
            return nil
        }
        let selection = scheduleSelectionGeneration
        // Keep the per-schedule guard even when selection changes. Cancelling a
        // view task cannot undo a POST that the server may already have accepted.
        pendingScheduleIDs.insert(id)
        scheduleRunError = nil
        scheduleRunMessage = nil
        scheduleOpenError = nil
        defer { pendingScheduleIDs.remove(id) }
        do {
            let run = try await client.runAgentSchedule(id)
            // Identity settles the mutation; generation represents navigation
            // intent. Returning to A may show A's result, but must not steal focus.
            // No newer attempt for this ID can exist until this defer releases it.
            guard !Task.isCancelled, selectedScheduleID == id else { return nil }
            // A GET begun before this acknowledgement must not erase the new run.
            scheduleHistoryGeneration &+= 1
            isLoadingScheduleRuns = false
            scheduleRuns = Array(([run] + scheduleRuns.filter { $0.id != run.id }).sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id > $1.id
            }.prefix(20))
            hasLoadedScheduleRuns = true
            scheduleRunMessage = "Run \(run.status.rawValue)."
            guard selection == scheduleSelectionGeneration else { return nil }
            return await resolveScheduleRunSession(run)
        } catch {
            guard !Task.isCancelled, selectedScheduleID == id else { return nil }
            scheduleRunError = "\(error.localizedDescription) Check recent runs before trying again; the request may have reached the server."
            return nil
        }
    }

    func openScheduleRun(_ run: AgentScheduleRunSummary) async -> MacSelectedSessionTarget? {
        guard !isRunningSchedule else { return nil }
        return await resolveScheduleRunSession(run)
    }

    private func resolveScheduleRunSession(_ run: AgentScheduleRunSummary) async -> MacSelectedSessionTarget? {
        guard run.scheduleId == selectedScheduleID, let sessionID = run.sessionId,
              openingScheduleRunID == nil else { return nil }
        guard let client = makeClient() else {
            scheduleOpenError = "Local server is unavailable."
            return nil
        }
        let selection = scheduleSelectionGeneration
        openingScheduleRunID = run.id
        scheduleOpenError = nil
        defer {
            if selection == scheduleSelectionGeneration { openingScheduleRunID = nil }
        }
        do {
            let session = try await client.getSessionRecord(sessionId: sessionID)
            guard !Task.isCancelled, selection == scheduleSelectionGeneration else { return nil }
            guard session.id == sessionID, let target = MacSelectedSessionTarget.from(session: session) else {
                scheduleOpenError = "The run session is unavailable. Refresh recent runs and try again."
                return nil
            }
            return target
        } catch {
            guard !Task.isCancelled, selection == scheduleSelectionGeneration else { return nil }
            scheduleOpenError = "Could not open run session: \(error.localizedDescription)"
            return nil
        }
    }

    func saveSchedule(_ draft: MacScheduleEditorDraft) async throws {
        guard draft.canSave, let client = makeClient() else { return }
        isSaving = true
        defer { isSaving = false }
        if isCreatingSchedule {
            let created = try await client.createAgentSchedule(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                trigger: draft.trigger,
                action: draft.action
            )
            upsert(created)
            isCreatingSchedule = false
            selectedScheduleID = created.id
            scheduleStatusFilter = created.status
            await loadSelectedSchedule()
            return
        }
        guard let selectedScheduleID else { return }
        let updated = try await client.updateAgentSchedule(
            scheduleId: selectedScheduleID,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            trigger: draft.trigger,
            action: draft.action
        )
        upsert(updated)
        scheduleStatusFilter = updated.status
        await loadSelectedSchedule()
    }

    func setSelectedScheduleStatus(_ status: AgentScheduleStatus) async throws {
        guard let selectedScheduleID, let client = makeClient() else { return }
        isSaving = true
        defer { isSaving = false }
        let current = selectedSchedule?.status
        let updated: AgentScheduleSummary
        if status == .active, current == .archived {
            updated = try await client.restoreAgentSchedule(selectedScheduleID)
        } else {
            updated = try await client.setAgentScheduleStatus(scheduleId: selectedScheduleID, status: status)
        }
        upsert(updated)
        scheduleStatusFilter = updated.status
        if loadedSchedule?.id == updated.id {
            await loadSelectedSchedule()
        }
    }

    func selectSkill(_ id: String?) {
        selectedSkillID = id
        loadedSkill = nil
    }

    func loadSelectedSkill() async {
        guard let requestedID = selectedSkillID, let client = makeClient() else { return }
        do {
            let detail = try await client.getServerSkill(id: requestedID)
            guard selectedSkillID == requestedID else { return }
            loadedSkill = detail
        } catch {
            guard selectedSkillID == requestedID else { return }
            errors[.skills] = error.localizedDescription
        }
    }

    func setSelectedSkillEnabled(_ enabled: Bool) async throws {
        guard let selectedSkillID, let client = makeClient() else { return }
        isSaving = true
        defer { isSaving = false }
        let updated = try await client.setServerSkillEnabled(id: selectedSkillID, enabled: enabled)
        upsert(updated)
        if loadedSkill?.summary.id == updated.id {
            loadedSkill = ServerSkillDetail(
                summary: updated,
                skillMarkdown: loadedSkill?.skillMarkdown ?? "",
                files: loadedSkill?.files ?? []
            )
        }
    }

    func selectExtension(_ id: String?) {
        selectedExtensionID = id
        loadedExtension = nil
    }

    func loadSelectedExtension() async {
        guard let requestedID = selectedExtensionID, let client = makeClient() else { return }
        do {
            let detail = try await client.getServerExtension(id: requestedID)
            guard selectedExtensionID == requestedID else { return }
            loadedExtension = detail
        } catch {
            guard selectedExtensionID == requestedID else { return }
            errors[.extensions] = error.localizedDescription
        }
    }

    func beginCreateAgentControlSession() async {
        await presentControlLaunch {
            MacControlSessionLaunchPresentation.createAgent(workspace: workspaces.first)
        }
    }

    func beginReviseSelectedAgentControlSession() async {
        guard let selectedAgent,
              selectedAgentID != MacCatalogAgentRow.pi.id else { return }
        await presentControlLaunch {
            MacControlSessionLaunchPresentation.reviseAgent(
                selectedAgent,
                workspace: workspaces.first
            )
        }
    }

    func beginCreateScheduleControlSession() async {
        await presentControlLaunch {
            MacControlSessionLaunchPresentation.createSchedule(workspace: workspaces.first)
        }
    }

    func beginReviseSelectedScheduleControlSession() async {
        guard let selectedSchedule else { return }
        await presentControlLaunch {
            MacControlSessionLaunchPresentation.reviseSchedule(
                selectedSchedule,
                workspace: workspaces.first
            )
        }
    }

    func beginCreateWorkspaceControlSession() async {
        await presentControlLaunch {
            MacControlSessionLaunchPresentation.createWorkspace(workspace: nil)
        }
    }

    func beginReviseWorkspaceControlSession(_ workspace: Workspace) async {
        await presentControlLaunch {
            MacControlSessionLaunchPresentation.reviseWorkspace(workspace)
        }
    }

    func cancelControlSessionLaunch() {
        guard !isLaunchingControlSession else { return }
        frozenControlLaunchRequest = nil
        frozenControlLaunchDraft = nil
        controlLaunchDraft = nil
        controlLaunchError = nil
    }

    func selectControlLaunchWorkspace(_ workspace: Workspace) {
        guard !isLaunchingControlSession else { return }
        controlLaunchDraft?.workspaceId = workspace.id
        controlLaunchDraft?.workspaceName = workspace.name
        controlLaunchError = nil
    }

    func launchControlSession() async throws -> MacSelectedSessionTarget {
        guard !isLaunchingControlSession else { throw CancellationError() }
        guard let draft = controlLaunchDraft else {
            throw MacControlSessionLaunchError.missingRequest
        }
        if draft.domain != .workspaces {
            guard !draft.workspaceId.isEmpty else {
                throw MacControlSessionLaunchError.missingWorkspace
            }
        }
        guard draft.canSubmit else {
            throw MacControlSessionLaunchError.missingRequest
        }
        guard let client = makeClient() else {
            throw MacControlSessionLaunchError.unavailable
        }

        isLaunchingControlSession = true
        defer { isLaunchingControlSession = false }
        // Freeze every POST field and its source draft before the first network
        // attempt. A lost response retries those exact bytes and key, while a
        // successful retry can distinguish later unsent edits.
        let request: MacWorkspaceClient.CreateControlSessionRequest
        let sourceDraft: MacControlSessionLaunchDraft
        if let frozenControlLaunchRequest, let frozenControlLaunchDraft {
            request = frozenControlLaunchRequest
            sourceDraft = frozenControlLaunchDraft
        } else {
            request = .init(
                domain: draft.domain,
                intent: draft.intent,
                targetId: draft.targetId,
                targetName: draft.targetName,
                name: draft.sessionName,
                prompt: draft.prompt,
                launchIdempotencyKey: UUID().uuidString
            )
            sourceDraft = draft
            frozenControlLaunchRequest = request
            frozenControlLaunchDraft = draft
        }
        let response = try await client.createControlSession(request)
        guard response.session.control != nil else {
            throw MacControlSessionLaunchError.missingControlMetadata
        }
        let target = MacSelectedSessionTarget.from(session: response.session) ?? MacSelectedSessionTarget(
            workspaceId: response.session.workspaceId ?? "",
            sessionId: response.session.id,
            summary: SessionSummary(from: response.session)
        )
        frozenControlLaunchRequest = nil
        frozenControlLaunchDraft = nil
        if controlLaunchDraft == sourceDraft {
            controlLaunchDraft = nil
            controlLaunchError = nil
        } else if controlLaunchDraft != nil {
            controlLaunchError = "Your earlier request was delivered. Your revised request is still here—send it when ready."
        }
        return target
    }

    private func presentControlLaunch(_ makeDraft: () -> MacControlSessionLaunchDraft) async {
        guard !isLaunchingControlSession else { return }
        frozenControlLaunchRequest = nil
        frozenControlLaunchDraft = nil
        controlLaunchError = nil
        await ensureWorkspacesLoaded()
        controlLaunchDraft = makeDraft()
    }

    private func ensureWorkspacesLoaded() async {
        guard workspaces.isEmpty, let client = makeClient() else { return }
        do {
            workspaces = try await client.listWorkspaceCatalog().workspaces
        } catch {
            controlLaunchError = error.localizedDescription
        }
    }

    func setSelectedExtensionEnabled(_ enabled: Bool) async throws {
        guard let selectedExtensionID, let client = makeClient() else { return }
        isSaving = true
        defer { isSaving = false }
        let updated = try await client.setServerExtensionEnabled(id: selectedExtensionID, enabled: enabled)
        upsert(updated)
        if loadedExtension?.summary.id == updated.id {
            loadedExtension = ServerExtensionDetail(
                summary: updated,
                contributedTools: loadedExtension?.contributedTools,
                contributedToolDetails: loadedExtension?.contributedToolDetails,
                contributedCommands: loadedExtension?.contributedCommands
            )
        }
    }

    private func upsert(_ agent: StoredAgentDefinition) {
        let summary = AgentDefinitionSummary(
            id: agent.id,
            name: agent.name,
            icon: agent.icon,
            description: agent.description,
            launchConstraints: agent.definition.launchConstraints,
            status: agent.status,
            version: agent.version,
            createdAt: agent.createdAt,
            updatedAt: agent.updatedAt,
            archivedAt: agent.archivedAt
        )
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = summary
        } else {
            agents.append(summary)
        }
    }

    private func upsert(_ schedule: AgentScheduleSummary) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    private func upsert(_ skill: ServerSkillSummary) {
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
        }
    }

    private func upsert(_ resource: ServerExtensionSummary) {
        if let index = extensions.firstIndex(where: { $0.id == resource.id }) {
            extensions[index] = resource
        } else {
            extensions.append(resource)
        }
    }
}
