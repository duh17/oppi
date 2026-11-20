import Foundation

/// The sessions a reader read a file in the context of: the session whose chat
/// held the link, and the control session whose directory a relative host path
/// resolves against. The server judges a followed path in that context, so a
/// sandbox session's link never edits a file outside its sandbox.
struct FileEditReadContext: Equatable {
    var sessionId: String?
    var controlSessionId: String?

    init(sessionId: String? = nil, controlSessionId: String? = nil) {
        self.sessionId = sessionId?.isEmpty == false ? sessionId : nil
        self.controlSessionId = controlSessionId?.isEmpty == false ? controlSessionId : nil
    }
}

/// A file the reader browsed. `source` says where it comes from,
/// `fileKind` is what the reader renders it as, and `skillFile` names a
/// host file that is one of an editable Skill's own files. The reader that
/// builds the subject sets `skillFile` only for the file it was opened for,
/// and `ServerSkillFilePresentation.editable` decides whether that Skill is
/// editable at all. A session-touched file's identity is the workspace file
/// its session path names; `worktreeId` is the session's checkout.
/// `context` is the session the file was reached from, if any.
struct DocumentEditFile: Equatable {
    let serverId: String?
    let source: FileBrowserContentSource
    let workspaceId: String
    let worktreeId: String?
    let path: String
    let skillFile: SkillFileEditTarget?
    let fileKind: FileKind
    let context: FileEditReadContext
}

/// What a reader shows under one edit entry. A file opens our editor through
/// `/files/current`; an Agent's prompt and a Schedule's prompt open it through
/// their own record.
enum DocumentEditSubject: Equatable {
    /// A file the reader browsed.
    ///
    /// On a server with `fileEditOrigins` the identity is not the reader's to
    /// choose: the owner reads at `resolutionLocation` and edits through the
    /// origin the server names for the canonical file.
    case file(DocumentEditFile)
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
    static func file(
        serverId: String?,
        source: FileBrowserContentSource,
        workspaceId: String,
        worktreeId: String?,
        path: String,
        skillFile: SkillFileEditTarget?,
        fileKind: FileKind,
        context: FileEditReadContext = FileEditReadContext()
    ) -> Self {
        .file(DocumentEditFile(
            serverId: serverId, source: source, workspaceId: workspaceId, worktreeId: worktreeId,
            path: path, skillFile: skillFile, fileKind: fileKind, context: context
        ))
    }

    /// Where the owner asks the server who edits this file: the origin and path
    /// the reader read it through. A link followed from a session reads in that
    /// session's context; a host path otherwise reads as a host file (relative to
    /// its control session's directory when it has one). Nil for a record's
    /// prompt and a snapshot, which have no file.
    func resolutionLocation(serverId: String?) -> FileEditLocation? {
        switch self {
        case .file(let file):
            let (source, workspaceId, worktreeId, path, skillFile, context) =
                (file.source, file.workspaceId, file.worktreeId, file.path, file.skillFile, file.context)
            guard let fileServerId = file.serverId, !fileServerId.isEmpty, !path.isEmpty else { return nil }
            let origin: APIClient.CurrentFileOrigin
            var readPath = path
            switch source {
            case .workspaceFile:
                guard !workspaceId.isEmpty else { return nil }
                origin = .workspace(workspaceId: workspaceId, worktreeId: worktreeId)
            case .hostFile:
                if let skillFile {
                    origin = .skill(skillId: skillFile.skillId)
                    readPath = skillFile.path
                } else if let controlSessionId = context.controlSessionId {
                    origin = .host(controlSessionId: controlSessionId)
                } else if let sessionId = context.sessionId {
                    origin = .session(sessionId: sessionId)
                } else {
                    origin = .host(controlSessionId: nil)
                }
            case .sessionFile(let sessionId):
                origin = .session(sessionId: sessionId)
            case .sessionTouched(let touched):
                origin = .session(sessionId: touched.sessionId)
            }
            return FileEditLocation(serverId: fileServerId, origin: origin, path: readPath)
        case .piFile(let path, _):
            guard let serverId, !serverId.isEmpty, !path.isEmpty else { return nil }
            return FileEditLocation(serverId: serverId, origin: .pi, path: path)
        case .agentInstructions, .schedulePrompt, .snapshot:
            return nil
        }
    }

    /// The document this subject edits by the reader's own reckoning: a
    /// workspace file by workspace + worktree + path, a host file as its Skill's
    /// own file, or a record's prompt on `serverId` (which a prompt subject does
    /// not carry). The server's resolution overrides it for a file; this is the
    /// identity an unresolved read edits, and the one a deleted file's kept draft
    /// reopens under.
    func editIdentity(serverId: String?) -> WorkspaceFileEditIdentity? {
        switch self {
        case .file(let file):
            let (source, workspaceId, worktreeId, path, skillFile) =
                (file.source, file.workspaceId, file.worktreeId, file.path, file.skillFile)
            guard let fileServerId = file.serverId, !fileServerId.isEmpty else { return nil }
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
    var fileKind: FileKind? {
        switch self {
        case .file(let file): file.fileKind
        case .agentInstructions, .schedulePrompt: .markdown
        case .piFile(let path, _): FileKind.detect(from: path)
        case .snapshot: nil
        }
    }
}
