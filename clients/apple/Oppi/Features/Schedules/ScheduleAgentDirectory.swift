import Foundation
import Observation

/// The saved Agents the Schedules screen names on its rows, archived ones included (a
/// schedule can still launch one). One per Schedules container, shared by the list and
/// every calendar view; read again each time the screen appears. A failed read leaves the
/// rows naming the workspace, as they do for a schedule with no Agent.
@MainActor
@Observable
final class ScheduleAgentDirectory {
    private(set) var agents: [AgentDefinitionSummary] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoaded = false

    /// Reads the Agents: always with `refresh`, otherwise only the first time a client is
    /// there. A read already out is the answer to both; a failed one waits for the next
    /// appearance.
    func load(_ apiClient: APIClient?, refresh: Bool) {
        guard let apiClient, loadTask == nil, refresh || !hasLoaded else { return }
        hasLoaded = true
        loadTask = Task { [weak self] in
            let loaded = try? await apiClient.listAgents(includeArchived: true)
            guard let self else { return }
            if let loaded, loaded != agents { agents = loaded }
            loadTask = nil
        }
    }
}
