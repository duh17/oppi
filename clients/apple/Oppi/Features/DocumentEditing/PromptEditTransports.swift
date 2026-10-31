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
    /// `GET /agents/:id`: bytes are `instructions.text` (an Agent with no custom
    /// prompt reads as empty), the tag is the version. The mode read with that
    /// version is kept, so a write sends the record's own mode and never this
    /// device's guess — one read carries both.
    static func agentInstructions(api: APIClient, agentId: String) -> WorkspaceFileEditTransport {
        let mode = AgentPromptMode()
        return WorkspaceFileEditTransport(
            read: { _ in
                do {
                    let agent = try await api.getAgent(agentId)
                    await mode.record(agent.definition.instructions?.mode ?? .append)
                    let text = agent.definition.instructions?.text ?? ""
                    return .snapshot(WorkspaceFileDiskSnapshot(
                        bytes: WorkspaceFileTextCodec.encode(text),
                        etag: String(agent.version)
                    ))
                } catch {
                    return readFailure(error)
                }
            },
            write: { _, bytes, ifMatch in
                guard let version = Int(ifMatch) else {
                    return .rejected(status: 0, message: String(localized: "The Agent's version could not be read."))
                }
                let text = WorkspaceFileTextCodec.decodeDraft(bytes) ?? ""
                do {
                    let saved = try await api.updateAgentInstructions(
                        agentId: agentId,
                        expectedVersion: version,
                        mode: await mode.mode(),
                        text: text
                    )
                    return .saved(etag: String(saved.version))
                } catch {
                    return writeFailure(error)
                }
            }
        )
    }

    /// `GET /schedules/:id`: bytes are the action's prompt, the tag is the
    /// version. A write is `PATCH /schedules/:id?expectedVersion=` with the
    /// prompt. The prompt is required, so the server refuses an empty one.
    static func schedulePrompt(api: APIClient, scheduleId: String) -> WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { _ in
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

/// The mode the record held when the transport last read it. Every read (open,
/// Review, Use Disk Version) goes through this transport and records it, and the
/// version that read returned is the one the next write extends, so a write sends
/// the record's own mode — an Agent that replaced Pi's prompt is never turned
/// into one that appends by a stale local choice.
private actor AgentPromptMode {
    private var value: AgentInstructionMode = .append

    func record(_ mode: AgentInstructionMode) {
        value = mode
    }

    func mode() -> AgentInstructionMode {
        value
    }
}
