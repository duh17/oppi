import Foundation

/// An Agent's prompt and a Schedule's prompt as editable documents.
///
/// Neither is a file: each is a field on a record the server keeps with a
/// version, so their transport reads the record and writes it back conditioned
/// on that version. They answer the same `WorkspaceFileReadOutcome` and
/// `WorkspaceFileWriteOutcome` as `/files/current`, so the editor, its drafts,
/// its conflict banner, and its status words need nothing new: the record's
/// version is the etag, a 409 is `.stale`, and a record that is gone is
/// `.missing`.
extension WorkspaceFileEditTransport {
    /// A record's prompt: the two calls are all that differ between an Agent
    /// and a schedule, so the outcome mapping lives here once.
    static func recordPrompt(
        read: @escaping @Sendable () async -> WorkspaceFileReadOutcome,
        write: @escaping @Sendable (WorkspaceFileWriteRequest) async -> WorkspaceFileWriteOutcome
    ) -> WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(read: { _ in await read() }, write: { _, request in await write(request) })
    }

    /// `GET /agents/:id`: bytes are `instructions.text` (an Agent with no custom
    /// prompt reads as empty), the tag is the version. A write is
    /// `PATCH /agents/:id?expectedVersion=` with the prompt and its mode.
    static func agentInstructions(api: APIClient, agentId: String) -> WorkspaceFileEditTransport {
        recordPrompt(
            read: {
                do {
                    let agent = try await api.getAgent(agentId)
                    let text = agent.definition.instructions?.text ?? ""
                    return .snapshot(WorkspaceFileDiskSnapshot(
                        bytes: WorkspaceFileTextCodec.encode(text),
                        etag: String(agent.version)
                    ))
                } catch {
                    return readFailure(error)
                }
            },
            write: { request in
                guard let version = Int(request.ifMatch) else {
                    return .rejected(status: 0, message: String(localized: "The Agent's version could not be read."))
                }
                let text = WorkspaceFileTextCodec.decodeDraft(request.bytes) ?? ""
                do {
                    let saved = try await api.updateAgentInstructions(
                        agentId: agentId,
                        expectedVersion: version,
                        mode: request.instructionMode ?? .append,
                        text: text
                    )
                    return .saved(etag: String(saved.version))
                } catch {
                    return writeFailure(error)
                }
            }
        )
    }

    /// The mode the Agent's record holds now, for a document that took the disk
    /// version: the next save must not carry this device's older choice.
    static func agentPromptMode(api: APIClient, agentId: String) async -> AgentInstructionMode? {
        try? await api.getAgent(agentId).definition.instructions?.mode
    }

    /// `GET /schedules/:id`: bytes are the action's prompt, the tag is the
    /// version. A write is `PATCH /schedules/:id?expectedVersion=` with the
    /// prompt. The prompt is required, so the server refuses an empty one.
    static func schedulePrompt(api: APIClient, scheduleId: String) -> WorkspaceFileEditTransport {
        recordPrompt(
            read: {
                do {
                    let schedule = try await api.getAgentSchedule(scheduleId)
                    return .snapshot(WorkspaceFileDiskSnapshot(
                        bytes: WorkspaceFileTextCodec.encode(SchedulePresentation.prompt(in: schedule.action)),
                        etag: schedule.version.map(String.init)
                    ))
                } catch {
                    return readFailure(error)
                }
            },
            write: { request in
                guard let version = Int(request.ifMatch) else {
                    return .rejected(status: 0, message: String(localized: "The schedule's version could not be read."))
                }
                let prompt = WorkspaceFileTextCodec.decodeDraft(request.bytes) ?? ""
                do {
                    let saved = try await api.updateAgentSchedulePrompt(
                        scheduleId: scheduleId,
                        expectedVersion: version,
                        prompt: prompt
                    )
                    // A server without versions answers no tag: the editor re-reads
                    // before any retry rather than inventing one.
                    guard let newVersion = saved.version else { return .unknown }
                    return .saved(etag: String(newVersion))
                } catch {
                    return writeFailure(error)
                }
            }
        )
    }

    private static func readFailure(_ error: Error) -> WorkspaceFileReadOutcome {
        status(of: error) == 404 ? .missing : .failed
    }

    private static func writeFailure(_ error: Error) -> WorkspaceFileWriteOutcome {
        if RecordVersionConflict.isVersionConflict(error) {
            return .stale
        }
        guard let status = status(of: error) else {
            return WorkspaceFileWriteFailureClassifier.outcome(for: error)
        }
        switch status {
        case 404:
            return .missing
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
