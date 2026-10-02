import AppIntents
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "StartOppiSessionIntent")

/// App Intent that creates a prompted session in the background and opens the live chat.
struct StartOppiSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Session"
    static let description: IntentDescription = "Start a Pi session with a prompt and open that chat."
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
#if compiler(>=6.4)
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
#endif

    static var parameterSummary: some ParameterSummary {
        Summary("Start a session in \(\.$workspace)") {
            \.$prompt
        }
    }

    @Parameter(
        title: "Prompt",
        requestValueDialog: IntentDialog("What should Pi do?"),
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var prompt: String

    @Parameter(title: "Workspace")
    var workspace: WorkspaceEntity?

    @Parameter(title: "Server")
    var server: PairedServerEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmedPrompt = try await resolvedPrompt()
        guard let trimmedPrompt else {
            return .result(dialog: IntentDialog(stringLiteral: StartOppiSessionDialog.missingPrompt))
        }

        let requestID = IntentSessionOpenTrigger.shared.issueRequestID()
        let launchKey = "ios-siri-start-\(UUID().uuidString)"

        let target: IntentSessionDisambiguation.WorkspaceHit
        switch try await resolveTarget() {
        case .resolved(let hit):
            target = hit
        case .dialog(let dialog):
            return .result(dialog: IntentDialog(stringLiteral: dialog))
        }

        guard let paired = KeychainService.loadServers().first(where: { $0.id == target.serverId }) else {
            return .result(dialog: IntentDialog(stringLiteral: StartOppiSessionDialog.noServer))
        }

        // The prompt can come from a chained Shortcut (untrusted text), so the user
        // confirms the exact prompt and destination before any connection or create.
        let confirmationText = StartOppiSessionConfirmation.dialogText(
            prompt: trimmedPrompt,
            workspaceName: target.workspaceName,
            serverName: target.serverName,
            pairedServerCount: KeychainService.loadServers().count
        )

        let outcome: CreateOutcome?
        do {
            outcome = try await StartOppiSessionConfirmation.gated(
                confirm: {
                    try await requestConfirmation(
                        actionName: .send,
                        dialog: IntentDialog(stringLiteral: confirmationText)
                    )
                },
                proceed: {
                    try await ServerTransportAPIClient.withClient(for: paired) { api in
                        await createSession(
                            api: api,
                            workspaceId: target.workspaceId,
                            prompt: trimmedPrompt,
                            launchKey: launchKey
                        )
                    }
                }
            )
        } catch {
            logger.error("Start-session transport failed before create: \(error.localizedDescription, privacy: .public)")
            return .result(dialog: IntentDialog(stringLiteral: StartOppiSessionDialog.cannotConnect))
        }

        guard let outcome else {
            return .result(dialog: IntentDialog(stringLiteral: StartOppiSessionDialog.declined))
        }

        switch outcome {
        case .failed(let dialog):
            return .result(dialog: IntentDialog(stringLiteral: dialog))
        case .unconfirmed:
            return .result(dialog: IntentDialog(stringLiteral: StartOppiSessionDialog.unconfirmed))
        case .opened(let sessionId, let session, let unsentPrompt):
            AppPreferences.QuickSession.saveWorkspaceId(target.workspaceId)
            IntentSessionOpenTrigger.shared.enqueue(
                IntentSessionOpenTrigger.Receipt(
                    requestID: requestID,
                    serverId: target.serverId,
                    sessionId: sessionId,
                    workspaceId: target.workspaceId,
                    unsentPrompt: unsentPrompt,
                    session: session
                )
            )

            do {
                try await continueInForeground(alwaysConfirm: false)
            } catch {
                logger.notice("Start-session could not come forward after create")
                return .result(
                    dialog: IntentDialog(
                        stringLiteral: StartOppiSessionDialog.startedFollowAlong(workspace: target.workspaceName)
                    )
                )
            }

            if unsentPrompt != nil {
                return .result(dialog: IntentDialog(stringLiteral: StartOppiSessionDialog.promptDidNotSend))
            }
            return .result(dialog: IntentDialog(stringLiteral: "Opening the session in \(target.workspaceName)."))
        }
    }

    private func resolvedPrompt() async throws -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let requested = try await $prompt.requestValue(IntentDialog("What should Pi do?"))
            text = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private func resolveTarget() async throws -> TargetResolution {
        if let workspace {
            return .resolved(
                IntentSessionDisambiguation.WorkspaceHit(
                    serverId: workspace.serverId,
                    serverName: workspace.serverName,
                    workspaceId: workspace.workspaceId,
                    workspaceName: workspace.name
                )
            )
        }

        let pairedServers = KeychainService.loadServers()
        if pairedServers.isEmpty {
            return .dialog(StartOppiSessionDialog.noServer)
        }

        let serverHits = pairedServers.map {
            IntentSessionDisambiguation.ServerHit(serverId: $0.id, serverName: $0.name)
        }
        var selectedServerId = server?.id
        var catalogs: [IntentSessionDisambiguation.Catalog] = []

        func refreshCatalogs() async {
            let snapshots = await IntentPairedWorkspaceCatalog.loadReachable()
            catalogs = snapshots.map { snapshot in
                IntentSessionDisambiguation.Catalog(
                    serverId: snapshot.server.id,
                    serverName: snapshot.server.name,
                    workspaces: snapshot.workspaces.map {
                        IntentSessionDisambiguation.Catalog.WorkspaceRef(id: $0.id, name: $0.name)
                    }
                )
            }
        }

        await refreshCatalogs()

        while true {
            let decision = IntentSessionDisambiguation.decide(
                pairedServers: serverHits,
                catalogs: catalogs,
                namedWorkspace: nil,
                selectedServerId: selectedServerId,
                selectedWorkspace: nil
            )
            switch decision {
            case .resolved(let hit):
                return .resolved(hit)
            case .noServers:
                return .dialog(StartOppiSessionDialog.noServer)
            case .noWorkspaces:
                return .dialog(StartOppiSessionDialog.noWorkspaces)
            case .namedWorkspaceMissing:
                return .dialog("Couldn't find that workspace.")
            case .serverUnreachable:
                return .dialog(StartOppiSessionDialog.cannotConnect)
            case .askServer(let servers):
                let ranked = IntentSessionRanking.rank(
                    servers,
                    id: \.serverId,
                    name: \.serverName,
                    lastUsedId: RestorationState.load()?.activeServerId,
                    defaultId: nil
                )
                let entities = ranked.map { PairedServerEntity(id: $0.serverId, name: $0.serverName) }
                let chosen = try await $server.requestDisambiguation(
                    among: entities,
                    dialog: IntentDialog("Which server?")
                )
                server = chosen
                selectedServerId = chosen.id
                if catalogs.contains(where: { $0.serverId == chosen.id }) == false {
                    await refreshCatalogs()
                }
            case .askWorkspace(let hits, let includeServerSubtitle):
                let ranked = IntentSessionRanking.rank(
                    hits,
                    id: \.workspaceId,
                    name: \.workspaceName,
                    lastUsedId: AppPreferences.QuickSession.lastWorkspaceId,
                    defaultId: AppPreferences.QuickSession.defaultWorkspaceId
                )
                let entities = ranked.map {
                    WorkspaceEntity(
                        serverId: $0.serverId,
                        workspaceId: $0.workspaceId,
                        name: $0.workspaceName,
                        serverName: $0.serverName,
                        showsServerSubtitle: includeServerSubtitle
                    )
                }
                let chosen = try await $workspace.requestDisambiguation(
                    among: entities,
                    dialog: IntentDialog("Which workspace?")
                )
                workspace = chosen
                return .resolved(
                    IntentSessionDisambiguation.WorkspaceHit(
                        serverId: chosen.serverId,
                        serverName: chosen.serverName,
                        workspaceId: chosen.workspaceId,
                        workspaceName: chosen.name
                    )
                )
            }
        }
    }

    private func createSession(
        api: APIClient,
        workspaceId: String,
        prompt: String,
        launchKey: String
    ) async -> CreateOutcome {
        do {
            let response = try await api.createWorkspaceSession(
                workspaceId: workspaceId,
                prompt: prompt,
                launchIdempotencyKey: launchKey
            )
            let prompted = response.prompted ?? false
            if prompted {
                return .opened(sessionId: response.session.id, session: response.session, unsentPrompt: nil)
            }
            return .opened(
                sessionId: response.session.id,
                session: response.session,
                unsentPrompt: prompt
            )
        } catch let conflict as CreateWorkspaceSessionConflict {
            return .opened(sessionId: conflict.sessionId, session: nil, unsentPrompt: prompt)
        } catch {
            if Self.isUnconfirmedCreateError(error) {
                logger.error("Start-session create was unconfirmed: \(error.localizedDescription, privacy: .public)")
                return .unconfirmed
            }
            logger.error("Start-session create failed: \(error.localizedDescription, privacy: .public)")
            return .failed(StartOppiSessionDialog.failed(error.localizedDescription))
        }
    }

    private static func isUnconfirmedCreateError(_ error: Error) -> Bool {
        if error is CreateWorkspaceSessionConflict {
            return false
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .server(let status, _), .codedServer(let status, _, _):
                return status >= 500 || status == 408
            case .invalidResponse:
                return true
            }
        }
        return true
    }

    private enum CreateOutcome: Sendable {
        case opened(sessionId: String, session: Session?, unsentPrompt: String?)
        case unconfirmed
        case failed(String)
    }

    private enum TargetResolution {
        case resolved(IntentSessionDisambiguation.WorkspaceHit)
        case dialog(String)
    }
}

/// Confirmation gate for Start Session: nothing connects, creates, or sends until the
/// user confirms. A declined, cancelled, or failed confirmation never proceeds.
enum StartOppiSessionConfirmation {
    static let maxPromptCharacters = 280

    static func dialogText(
        prompt: String,
        workspaceName: String,
        serverName: String,
        pairedServerCount: Int
    ) -> String {
        let shown = prompt.count > maxPromptCharacters
            ? String(prompt.prefix(maxPromptCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            : prompt
        let destination = pairedServerCount > 1
            ? "\(workspaceName) on \(serverName)"
            : workspaceName
        return "Start a session in \(destination) and send this prompt?\n\n\(shown)"
    }

    /// Runs `proceed` only after `confirm` returns normally. Returns nil when the user
    /// declined (or the confirmation could not complete); errors from `proceed` propagate.
    @MainActor
    static func gated<T>(
        confirm: () async throws -> Void,
        proceed: () async throws -> T
    ) async rethrows -> T? {
        do {
            try await confirm()
        } catch {
            return nil
        }
        return try await proceed()
    }
}

private enum StartOppiSessionDialog {
    static let declined = "Canceled. Nothing was sent."
    static let missingPrompt = "What should Pi do?"
    static let noServer = "No paired server found. Open Oppi to pair first."
    static let noWorkspaces = "No workspaces configured on the server."
    static let cannotConnect = "Could not connect to server."
    static let unconfirmed = "Couldn't confirm whether it started. Check Oppi before retrying."
    static let promptDidNotSend = "Opened the session, but the prompt didn't send."

    static func startedFollowAlong(workspace: String) -> String {
        "Started in \(workspace). Open Oppi to follow along."
    }

    static func failed(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Couldn't start the session."
        }
        return "Couldn't start the session: \(trimmed)"
    }
}
