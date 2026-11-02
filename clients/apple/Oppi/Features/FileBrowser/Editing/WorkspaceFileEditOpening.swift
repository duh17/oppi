import Foundation

/// How a `WorkspaceFileEditSession` opens, decided from what it was given and
/// before anything is written: the buffer, the base its next save is conditioned
/// on, the status, and what to do with a stored draft. Pure, so both of the
/// session's inits reduce to applying one of these.
struct WorkspaceFileEditOpening {
    enum DraftAction: Equatable {
        case keep
        /// Disk already holds exactly the draft's bytes: the draft is saved.
        case remove
        /// The draft cannot be applied: move it aside, never delete it.
        case quarantine
    }

    let bufferText: String
    let baseCondition: WorkspaceFileWriteCondition
    let diskBytes: Data
    let status: WorkspaceFileEditSession.Status
    /// The buffer is a stored draft rather than the disk bytes.
    let recoveredDraft: Bool
    let draftAction: DraftAction

    var draftNotice: String? {
        draftAction == .quarantine ? Self.quarantineNotice : nil
    }

    /// One tagged read, or a read that answered a file the server offers to
    /// create, plus the stored draft. Nil when the server offered neither a
    /// version nor a creation, or the bytes are not exact UTF-8 or exceed
    /// `maxBytes`. A draft on the same base resumes as pending; one on another
    /// base opens in conflict, keeping its own base so a later recovery still
    /// sees the conflict.
    init?(disk: WorkspaceFileDiskSnapshot, storedDraft: WorkspaceFileDraftStore.LoadResult, maxBytes: Int) {
        guard let condition = disk.writeCondition,
              disk.bytes.count <= maxBytes,
              let diskText = WorkspaceFileTextCodec.decode(disk.bytes) else { return nil }
        diskBytes = disk.bytes
        switch storedDraft {
        case .draft(let draft) where draft.bytes != disk.bytes:
            if let text = WorkspaceFileTextCodec.decodeDraft(draft.bytes) {
                bufferText = text
                recoveredDraft = true
                draftAction = .keep
                if draft.baseEtag == condition.storedTag {
                    baseCondition = condition
                    status = .pending
                } else {
                    baseCondition = WorkspaceFileWriteCondition(storedTag: draft.baseEtag)
                    status = .conflict
                }
                return
            }
            draftAction = .quarantine
        case .draft:
            draftAction = .remove
        case .unreadable:
            draftAction = .quarantine
        case .none:
            draftAction = .keep
        }
        bufferText = diskText
        baseCondition = condition
        status = .saved
        recoveredDraft = false
    }

    /// A kept draft whose file is gone (404): the session opens deleted and
    /// never writes, since Replace needs a reviewed disk version.
    init?(identity: WorkspaceFileEditIdentity, deletedFileDraft draft: WorkspaceFileDraft) {
        guard draft.identity == identity,
              let text = WorkspaceFileTextCodec.decodeDraft(draft.bytes) else { return nil }
        bufferText = text
        baseCondition = WorkspaceFileWriteCondition(storedTag: draft.baseEtag)
        diskBytes = Data()
        status = .deleted
        recoveredDraft = true
        draftAction = .keep
    }

    private static let quarantineNotice = String(
        localized: "A stored draft for this file could not be read. It was moved aside on this device and not applied."
    )
}
