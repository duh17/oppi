import Foundation

/// What a reader shows under one edit entry. Only a file can open our editor;
/// nothing else is editable in this slice.
enum DocumentEditSubject: Equatable {
    /// A file the reader browsed. `source` says where it comes from,
    /// `fileType` is what the reader renders it as, and `skillFile` names a
    /// host file that is one of an editable Skill's own files. The reader that
    /// builds the subject sets `skillFile` only for the file it was opened for,
    /// and `ServerSkillFilePresentation.editable` decides whether that Skill is
    /// editable at all.
    case file(
        serverId: String?,
        source: FileBrowserContentSource,
        workspaceId: String,
        worktreeId: String?,
        path: String,
        skillFile: SkillFileEditTarget?,
        fileType: FileType
    )
    /// Bytes the app holds with no file behind them: the Agent, Schedule, and
    /// Pi prompt readers. A snapshot is never editable; it may still offer
    /// Edit with Session.
    case snapshot
}

extension DocumentEditSubject {
    /// The file this subject edits: a workspace file by workspace + worktree +
    /// path, or a host file as its Skill's own file. A host file outside an
    /// editable Skill, a session file, and a snapshot have no identity, so
    /// they can never open the editor.
    var editIdentity: WorkspaceFileEditIdentity? {
        guard case let .file(serverId, source, workspaceId, worktreeId, path, skillFile, _) = self,
              let serverId, !serverId.isEmpty else { return nil }
        switch source {
        case .workspaceFile:
            guard !workspaceId.isEmpty else { return nil }
            return WorkspaceFileEditIdentity(
                serverId: serverId,
                workspaceId: workspaceId,
                worktreeId: worktreeId,
                path: path
            )
        case .hostFile:
            guard let skillFile else { return nil }
            return WorkspaceFileEditIdentity(serverId: serverId, skillId: skillFile.skillId, path: skillFile.path)
        case .sessionFile, .sessionTouched:
            return nil
        }
    }

    /// The type the reader renders the bytes as; nil for a snapshot.
    var fileType: FileType? {
        guard case .file(_, _, _, _, _, _, let fileType) = self else { return nil }
        return fileType
    }
}
