import UIKit

/// What a drawer opens and reads outside itself.
@MainActor
struct ExtensionSurfaceDrawerActions {
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)?
    /// Opens the chat's reader (a native surface or a terminal widget full screen).
    var openReader: (ChatReaderPayload) -> Void
    /// The session's current snapshot of a native surface, by protocol id, so
    /// the reader follows updates the drawer would show.
    var liveSurface: ((String) -> ExtensionUINativeSurface?)?
    /// Sends one action on a composable surface. The host mints the request id and
    /// shows the action's declared pending state until the server settles it.
    var sendAction: ((ExtensionSurfaceActionIntent) -> Void)?
    /// The session's current snapshot of a composable surface, by protocol id, so its reader
    /// follows the replacements the drawer would draw.
    var liveComposableSurface: ((String) -> ExtensionUISurface?)?
    /// The composable surface action waiting on the server, read as the reader draws.
    var pendingAction: (@MainActor @Sendable () -> ExtensionSurfacePendingAction?)?
    /// The menu of a session an activity row links to (`ExtensionNativeBlockContext.sessionMenu`).
    var sessionMenu: (@MainActor (_ sessionId: String, _ url: URL, _ rowState: String?) -> UIMenu?)?
    /// The reader opens in the attached leaf beside the chat rather than over it.
    var readerOpensBeside = false
    /// Opens a surface, by id, in its panel pane beside the chat (full screen on a narrow one).
    var openPanel: ((String) -> Void)?
    /// Focuses the panel pane beside the chat, for a pill whose surface it already shows.
    var focusPanel: (() -> Void)?
    /// The chat's server, where a surface's tiles read and open their places.
    var server: ExtensionSurfaceServer?
}

/// The server a surface's session lives on, as the chat that shows the surface holds it: where a
/// `tiles` node reads its places' previews and opens them.
struct ExtensionSurfaceServer {
    let id: String
    weak var connection: ServerConnection?
}
