import Foundation

/// The Agent prompt and the Schedule prompt as editable documents.
///
/// Neither is a file: each is a field on a record the server keeps with a
/// version, so their transports read the record and write it back conditioned
/// on that version. They answer the same `WorkspaceFileReadOutcome` and
/// `WorkspaceFileWriteOutcome` as `/files/current`, so the editor, its drafts,
/// its conflict banner, and its status words need nothing new: the record's
/// version is the etag, a 409 is `.stale`, and a record that is gone is
/// `.missing`.
extension WorkspaceFileEditTransport {
    /// Reads `GET /agents/:id` (bytes are `instructions.text`, the tag is the
    /// version; an Agent with no custom prompt reads as empty) and writes
    /// `PATCH /agents/:id?expectedVersion=` with the prompt and its mode.
    ///
    /// `mode` is read when the write runs, because the editor's mode control is
    /// the only writer and it changes after the session exists.
    static func agentInstructions(
        api: APIClient,
        agentId: String,
        mode: @escaping @Sendable () async -> AgentInstructionMode
    ) -> WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { _ in
                do {
                    let agent = try await api.getAgent(agentId)
                    let text = agent.definition.instructions?.text ?? ""
                    return .snapshot(WorkspaceFileDiskSnapshot(
                        bytes: WorkspaceFileTextCodec.encode(text),
                        etag: String(agent.version)
                    ))
                } catch {
                    return Self.readFailure(error)
                }
            },
            write: { _, bytes, ifMatch in
                guard let version = Int(ifMatch) else {
                    return .rejected(status: 0, message: String(localized: "The Agent's version could not be read."))
                }
                let text = WorkspaceFileTextCodec.decodeDraft(bytes) ?? ""
                let instructionMode = await mode()
                do {
                    let saved = try await api.updateAgentInstructions(
                        agentId: agentId,
                        expectedVersion: version,
                        mode: instructionMode,
                        text: text
                    )
                    return .saved(etag: String(saved.version))
                } catch {
                    return Self.writeFailure(error)
                }
            }
        )
    }

    /// Reads `GET /schedules/:id` (bytes are the action's prompt, the tag is the
    /// version) and writes `PATCH /schedules/:id?expectedVersion=` with the prompt.
    static func schedulePrompt(api: APIClient, scheduleId: String) -> WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { _ in
                do {
                    let schedule = try await api.getAgentSchedule(scheduleId)
                    return .snapshot(WorkspaceFileDiskSnapshot(
                        bytes: WorkspaceFileTextCodec.encode(SchedulePresentation.prompt(in: schedule.action)),
                        etag: String(schedule.version)
                    ))
                } catch {
                    return Self.readFailure(error)
                }
            },
            write: { _, bytes, ifMatch in
                guard let version = Int(ifMatch) else {
                    return .rejected(status: 0, message: String(localized: "The schedule's version could not be read."))
                }
                let prompt = WorkspaceFileTextCodec.decodeDraft(bytes) ?? ""
                do {
                    let saved = try await api.updateAgentSchedulePrompt(
                        scheduleId: scheduleId,
                        expectedVersion: version,
                        prompt: prompt
                    )
                    return .saved(etag: String(saved.version))
                } catch {
                    return Self.writeFailure(error)
                }
            }
        )
    }

    /// The server's version conflict codes, which mean "someone else wrote it".
    private static let versionConflictCodes: Set<String> = [
        "AGENT_VERSION_CONFLICT",
        "SCHEDULE_VERSION_CONFLICT",
    ]

    private static func readFailure(_ error: Error) -> WorkspaceFileReadOutcome {
        status(of: error) == 404 ? .missing : .failed
    }

    private static func writeFailure(_ error: Error) -> WorkspaceFileWriteOutcome {
        if let coded = error as? APIError, case .codedServer(_, let message, let code) = coded,
           versionConflictCodes.contains(code) {
            return .stale
        }
        guard let status = status(of: error) else {
            return WorkspaceFileWriteFailureClassifier.outcome(for: error)
        }
        switch status {
        case 404:
            return .missing
        case 409:
            // A version conflict the server answered without its code.
            return .stale
        default:
            let message = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return .rejected(status: status, message: message)
        }
    }

    private static func status(of error: Error) -> Int? {
        guard let apiError = error as? APIError else { return nil }
        switch apiError {
        case .server(let status, _), .codedServer(let status, _, _): return status
        case .invalidResponse: return nil
        }
    }
}
