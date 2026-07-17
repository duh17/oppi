import AppIntents
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AskOppiIntent")

/// App Intent that sends a prompt to the server without opening the app.
struct AskOppiIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Oppi"
    // periphery:ignore
    static let description: IntentDescription = "Send a message to start a new agent session without opening the app." // periphery:ignore

    static let openAppWhenRun = false

    @Parameter(title: "Message", inputConnectionBehavior: .connectToPreviousIntentResult)
    var message: String

    @Parameter(title: "Workspace")
    var workspace: WorkspaceEntity?

    @Parameter(title: "Model")
    var model: String?

    @Parameter(title: "Thinking Level")
    var thinking: ThinkingLevelEnum?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let server = loadPairedServer() else {
            return .result(dialog: "No paired server found. Open Oppi to pair first.")
        }

        do {
            let message = try await ServerTransportAPIClient.withClient(for: server) { api in
                await performRequest(api: api)
            }
            return .result(dialog: IntentDialog(stringLiteral: message))
        } catch {
            logger.error("Failed to prepare intent transport: \(error)")
            return .result(dialog: "Could not connect to server.")
        }
    }

    @MainActor
    private func performRequest(api: APIClient) async -> String {
        let targetWorkspaceId: String
        let workspaceSelectionSource: String
        if let workspace {
            targetWorkspaceId = workspace.id
            workspaceSelectionSource = "explicit"
        } else {
            do {
                let workspaces = try await api.listWorkspaces()
                guard !workspaces.isEmpty else {
                    return "No workspaces configured on the server."
                }

                if let preferred = AppPreferences.QuickSession.preferredWorkspaceSelection(
                    in: workspaces.map { (id: $0.id, name: $0.name) }
                ) {
                    targetWorkspaceId = preferred.id
                    workspaceSelectionSource = preferred.source
                } else {
                    targetWorkspaceId = workspaces[0].id
                    workspaceSelectionSource = "first_available"
                }
            } catch {
                logger.error("Failed to list workspaces: \(error)")
                return "Could not connect to server."
            }
        }

        let telemetryStartedAtMs = ChatSessionTelemetry.nowMs()
        let telemetryTags = [
            "source": "intent",
            "selection": workspaceSelectionSource,
            "has_message": message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0" : "1",
            "has_model": model == nil ? "0" : "1",
        ]

        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: targetWorkspaceId,
                model: model,
                prompt: message,
                thinking: thinking?.rawValue
            )
            let prompted = response.prompted ?? false
            let sessionName = response.session.name ?? response.session.id
            ChatSessionTelemetry.recordTimingMetric(
                .quickSessionCreateMs,
                durationMs: max(0, ChatSessionTelemetry.nowMs() - telemetryStartedAtMs),
                workspaceId: targetWorkspaceId,
                tags: telemetryTags.merging([
                    "status": prompted ? "ok" : "error",
                    "delivery": prompted ? "prompted" : "created_only",
                ]) { _, new in new }
            )
            if prompted {
                logger.error("Quick dispatch succeeded: session=\(response.session.id)")
                return "Session started: \(sessionName)"
            }

            ChatSessionTelemetry.recordCountMetric(
                .quickSessionError,
                workspaceId: targetWorkspaceId,
                tags: [
                    "source": "intent",
                    "selection": workspaceSelectionSource,
                    "error_kind": "prompt_delivery",
                ]
            )
            logger.warning("Session created but prompt delivery failed: \(response.session.id)")
            return "Session created but agent failed to start. Open Oppi to retry."
        } catch {
            let errorKind = ChatSessionTelemetry.metricErrorKind(for: error)
            ChatSessionTelemetry.recordTimingMetric(
                .quickSessionCreateMs,
                durationMs: max(0, ChatSessionTelemetry.nowMs() - telemetryStartedAtMs),
                workspaceId: targetWorkspaceId,
                tags: telemetryTags.merging([
                    "status": "error",
                    "error_kind": errorKind,
                ]) { _, new in new }
            )
            ChatSessionTelemetry.recordCountMetric(
                .quickSessionError,
                workspaceId: targetWorkspaceId,
                tags: [
                    "source": "intent",
                    "selection": workspaceSelectionSource,
                    "error_kind": errorKind,
                ]
            )
            logger.error("Quick dispatch failed: \(error)")
            return "Failed to create session: \(error.localizedDescription)"
        }
    }

    /// Load the first paired server from Keychain (shared access group).
    private func loadPairedServer() -> PairedServer? {
        KeychainService.loadServers().first
    }
}
