import UIKit

/// Run Now, from a schedule's detail or the calendar. A run sends the schedule's prompt to
/// its model's provider, so it waits for this device's AI sharing consent first; Not Now runs
/// nothing and answers nil. The request carries a fresh `requestId`, so a retried request
/// makes one run. `willRun` runs once consent is given, before the request: the calendar
/// draws its Starting entry there.
@MainActor
enum ScheduleRunNow {
    static func run(
        _ scheduleId: String,
        modelId: String?,
        apiClient: APIClient,
        connection: ServerConnection,
        from screen: UIViewController?,
        willRun: () -> Void = {}
    ) async throws -> AgentScheduleRunSummary? {
        let allowed = await AISharingConsentPrompt.requestModelSharing(
            modelId: modelId,
            serverId: nil,
            connection: connection,
            from: screen
        )
        guard allowed else { return nil }
        willRun()
        return try await apiClient.runAgentSchedule(scheduleId)
    }
}
