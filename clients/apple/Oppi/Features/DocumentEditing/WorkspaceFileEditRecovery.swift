import Foundation

/// Open-time recovery when the file itself is gone. The edit entry's read calls
/// this on a 404, so a kept draft reopens in the non-writing deleted state
/// instead of an error page.
@MainActor
enum WorkspaceFileEditRecovery {
    /// A 404 on open: move a live session with unsaved edits into the
    /// non-writing deleted state, or reopen a kept draft in that state. An
    /// unreadable draft is left in place untouched. Nil means there is nothing
    /// to recover.
    static func sessionForMissingFile(
        identity: WorkspaceFileEditIdentity,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        registry: WorkspaceFileEditSessionRegistry = .shared,
        draftStore: WorkspaceFileDraftStore = .shared,
        isAutoSaveOn: @MainActor @escaping () -> Bool = { CodeEditorPreferences.shared.autoSaves }
    ) -> WorkspaceFileEditSession? {
        if let live = registry.session(for: identity), live.hasUnsavedChanges {
            live.noteFileMissing()
            return live
        }
        guard case .draft(let draft) = draftStore.loadResult(identity),
              let session = WorkspaceFileEditSession(
                  identity: identity,
                  deletedFileDraft: draft,
                  maxBytes: maxBytes,
                  transport: transport,
                  draftStore: draftStore,
                  isAutoSaveOn: isAutoSaveOn
              ) else { return nil }
        registry.register(session)
        return session
    }
}
