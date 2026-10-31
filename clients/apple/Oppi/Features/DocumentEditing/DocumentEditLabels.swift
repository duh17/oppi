import Foundation

/// The words and glyphs of one document's edit entry: the pencil that opens
/// our editor, and the "…" that holds Edit with Session. Workspace files,
/// Skill files, and the Agent, Schedule, and Pi readers say the same thing.
enum DocumentEditLabels {
    static let systemImage = "pencil"
    static let edit = String(localized: "Edit")
    static let editFile = String(localized: "Edit File")
    /// An Oppi session revises the document.
    static let editWithSession = String(localized: "Edit with Session")
    static let editWithSessionImage = "text.bubble"
    static let startingSession = String(localized: "Starting…")
    /// The overflow control beside the pencil; its menu holds Edit with Session.
    static let moreImage = "ellipsis.circle"
    static let more = String(localized: "Document Actions")
}

/// Editing a document through an Oppi session instead of the editor.
struct DocumentAgentEditAction {
    /// The session is being created; the action waits.
    var isStarting = false
    let start: @MainActor () -> Void
}
