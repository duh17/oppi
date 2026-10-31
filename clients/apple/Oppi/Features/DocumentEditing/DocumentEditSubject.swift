import Foundation

/// What a reader shows under one edit entry. A file opens our editor through
/// `/files/current`; an Agent's prompt and a Schedule's prompt open it through
/// their own record; nothing else is editable in this slice.
enum DocumentEditSubject: Equatable {
    /// A file the reader browsed. `source` says where it comes from,
    /// `fileType` is what the reader renders it as, and `skillFile` names a
    /// host file that is one of an editable Skill's own files. The reader that
    /// builds the subject sets `skillFile` only for the file it was opened for,
    /// and `ServerSkillFilePresentation.editable` decides whether that Skill is
    /// editable at all. A session-touched file's identity is the workspace file
    /// its session path names; `worktreeId` is the session's checkout.
    case file(
        serverId: String?,
        source: FileBrowserContentSource,
        workspaceId: String,
        worktreeId: String?,
        path: String,
        skillFile: SkillFileEditTarget?,
        fileType: FileType
    )
    /// An Agent's custom prompt (`instructions.text`), edited in place. The
    /// server comes from the owner, since the record id alone does not name it.
    case agentInstructions(agentId: String)
    /// A Schedule's prompt (`action.prompt`), edited in place.
    case schedulePrompt(scheduleId: String)
    /// One of Pi's own agent files (`SYSTEM.md`, `prompts/`), by
    /// Pi-agent-relative path: the host home's one writable spot, allowlisted by
    /// the server. The reader that shows it names the file it read, and supplies
    /// `seedText`: the text a *missing* file starts from. `SYSTEM.md` replaces
    /// Pi's built-in prompt, so its seed is that prompt — an editor opened empty
    /// there would replace it with nothing — and a prompt template has none.
    case piFile(path: String, seedText: String?)
    /// Bytes the app holds with no file behind them: the Pi prompt readers, a
    /// tool row. A snapshot is never editable; it may still offer Edit with
    /// Session.
    case snapshot
}

extension DocumentEditSubject {
    /// The document this subject edits: a workspace file by workspace + worktree
    /// + path, a host file as its Skill's own file, or a record's prompt on
    /// `serverId` (which a prompt subject does not carry). A host file outside an
    /// editable Skill, a session file, and a snapshot have no identity, so they
    /// can never open the editor.
    func editIdentity(serverId: String?) -> WorkspaceFileEditIdentity? {
        switch self {
        case let .file(fileServerId, source, workspaceId, worktreeId, path, skillFile, _):
            guard let fileServerId, !fileServerId.isEmpty else { return nil }
            switch source {
            case .workspaceFile:
                guard !workspaceId.isEmpty else { return nil }
                return WorkspaceFileEditIdentity(
                    serverId: fileServerId,
                    workspaceId: workspaceId,
                    worktreeId: worktreeId,
                    path: path
                )
            case .hostFile:
                guard let skillFile else { return nil }
                return WorkspaceFileEditIdentity(serverId: fileServerId, skillId: skillFile.skillId, path: skillFile.path)
            case .sessionFile:
                return nil
            case .sessionTouched(let origin):
                // The session's copy of a workspace file edits as that file: the
                // pencil opens the live one through its workspace path.
                guard !workspaceId.isEmpty,
                      let workspacePath = WorkspaceFileEditPath.reportedPath(
                          path,
                          runtime: origin.workspaceRuntime,
                          hostMount: origin.hostMount,
                          worktreeId: worktreeId
                      ) else { return nil }
                return WorkspaceFileEditIdentity(
                    serverId: fileServerId,
                    workspaceId: workspaceId,
                    worktreeId: worktreeId,
                    path: workspacePath
                )
            }
        case .agentInstructions(let agentId):
            guard let serverId, !serverId.isEmpty else { return nil }
            return WorkspaceFileEditIdentity(serverId: serverId, agentId: agentId)
        case .schedulePrompt(let scheduleId):
            guard let serverId, !serverId.isEmpty else { return nil }
            return WorkspaceFileEditIdentity(serverId: serverId, scheduleId: scheduleId)
        case .piFile(let path, _):
            guard let serverId, !serverId.isEmpty, !path.isEmpty else { return nil }
            return WorkspaceFileEditIdentity(serverId: serverId, piPath: path)
        case .snapshot:
            return nil
        }
    }

    /// The text an editor starts from when the document does not exist yet. Only
    /// Pi's own `SYSTEM.md` has one: it replaces Pi's built-in prompt, so the
    /// editor starts from that prompt and a save that changes nothing writes
    /// nothing.
    var creatableSeedText: String? {
        switch self {
        case .piFile(_, let seedText): seedText
        case .file, .agentInstructions, .schedulePrompt, .snapshot: nil
        }
    }

    /// The type the reader renders the bytes as; nil for a snapshot. A record's
    /// prompt is Markdown, as the reader shows it.
    var fileType: FileType? {
        switch self {
        case .file(_, _, _, _, _, _, let fileType): fileType
        case .agentInstructions, .schedulePrompt: .markdown
        case .piFile(let path, _): FileType.detect(from: path)
        case .snapshot: nil
        }
    }
}
