import AppIntents
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "AskOppiIntent")

/// App Intent that sends a prompt to the server without opening the app.
///
/// Creates a session, auto-resumes it, and delivers the prompt — all
/// server-side via a single REST call. The agent starts working in the
/// background; check the result in Oppi whenever.
///
/// Works from:
/// - Shortcuts app
/// - Siri voice
/// - Action Button (via Shortcut assignment)
/// - Automations
struct AskOppiIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Oppi"
    static let description: IntentDescription = "Send a message to start a new agent session without opening the app."

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

        guard let baseURL = server.baseURL else {
            return .result(dialog: "Invalid server configuration.")
        }

        let api = APIClient(
            baseURL: baseURL,
            token: server.token,
            tlsCertFingerprint: server.tlsCertFingerprint
        )

        let targetWorkspaceId: String
        if let workspace {
            targetWorkspaceId = workspace.id
        } else {
            do {
                let workspaces = try await api.listWorkspaces()
                guard !workspaces.isEmpty else {
                    return .result(dialog: "No workspaces configured on the server.")
                }

                if let lastId = QuickSessionDefaults.lastWorkspaceId,
                   workspaces.contains(where: { $0.id == lastId }) {
                    targetWorkspaceId = lastId
                } else {
                    targetWorkspaceId = workspaces[0].id
                }
            } catch {
                logger.error("Failed to list workspaces: \(error)")
                return .result(dialog: "Could not connect to server.")
            }
        }

        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: targetWorkspaceId,
                model: model,
                prompt: message,
                thinking: thinking?.rawValue
            )
            let prompted = response.prompted ?? false
            let sessionName = response.session.name ?? response.session.id
            if prompted {
                logger.info("Quick dispatch succeeded: session=\(response.session.id)")
                return .result(dialog: "Session started: \(sessionName)")
            } else {
                logger.warning("Session created but prompt delivery failed: \(response.session.id)")
                return .result(dialog: "Session created but agent failed to start. Open Oppi to retry.")
            }
        } catch {
            logger.error("Quick dispatch failed: \(error)")
            return .result(dialog: "Failed to create session: \(error.localizedDescription)")
        }
    }

    /// Load the first paired server from Keychain (shared access group).
    private func loadPairedServer() -> PairedServer? {
        let servers = KeychainService.loadServers()
        return servers.first
    }
}
