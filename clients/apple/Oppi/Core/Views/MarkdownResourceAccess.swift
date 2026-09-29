import Foundation

/// Source identity plus deferred resource providers for one Markdown document.
///
/// The owner that knows a document's source (a timeline row, the file browser, a
/// touched-file reader) builds one value. Every renderer that hosts the document
/// (assistant prose, expanded tool Markdown, the full-screen reader, and its
/// streaming-to-complete swap) receives that same value and reads it. Renderers
/// never re-derive identity from whichever session, server, or workspace is
/// active when a callback fires.
///
/// The document's own location (`sourceFilePath`, line anchors) is deliberately
/// not part of this value. Relative links and images keep resolving against the
/// file that contains them, whatever origin later serves the bytes.
///
/// ## Identity
///
/// ``Identity`` is plain, `Equatable`, `Sendable` data fixed when the owner builds
/// the value. Renderers compare it to decide whether a re-render is needed, and
/// detached parsing captures it. Its fields are optional because owners do not
/// all know everything at once:
///
/// - a cached row can exist before the client or the workspace catalog is ready
///   (`serverBaseURL` and `workspaceID` unset);
/// - a control session has a session and server but no workspace;
/// - a plain file, an export, or an ask card has no server context (``empty``).
///
/// ## Providers
///
/// Providers are closures that read one origin's bytes or media. `nil` means that
/// origin is unavailable to the owner, and the renderer shows its own unavailable
/// state. Availability is per provider: an unresolved workspace never removes the
/// host-file, session-file, or media providers.
///
/// Readiness classes are separate on purpose:
/// - Providers backed by `SessionContentAccess` resolve the client and the catalog
///   runtime when they run, so a row built before the client exists can still load
///   once it arrives. The source session's checkout is captured at construction; a
///   fetch-time lookup happens only when that captured worktree is nil. The workspace
///   is never re-derived from the session.
/// - `serverBaseURL` and a client-capturing `fetchWorkspaceFile` are fixed when the
///   owner builds the value. Workspace-relative image URLs need both, so an owner
///   without a client leaves them unset and builds a fresh value once one exists.
///
/// The value adds no lifecycle. Whatever retains it (a row configuration, a reader
/// payload, a reader body) retains its providers, which retain their owner's
/// adapter or client and nothing else.
///
/// It is deliberately not `Sendable`: providers are closures created and awaited by
/// main-actor UI code. Only ``Identity`` is `Sendable`, so detached parsing captures
/// that instead of the whole value.
struct MarkdownResourceAccess {
    /// Source identity bound at construction. Never mutated after an owner hands it out.
    struct Identity: Equatable, Sendable {
        let serverID: String?
        let workspaceID: String?
        /// Source-session checkout for workspace-origin URLs. Nil and `main` omit the query.
        let worktreeId: String?
        let sessionID: String?
        /// Sandbox origin keeps guest `/workspace/...` children on the session origin.
        let workspaceRuntime: WorkspaceRuntime?
        let serverBaseURL: URL?
        /// Reader-only: links inside the document keep the exact source-session file route
        /// instead of being reclassified against the active workspace.
        let routesFileReferencesThroughSession: Bool

        init(
            serverID: String? = nil,
            workspaceID: String? = nil,
            worktreeId: String? = nil,
            sessionID: String? = nil,
            workspaceRuntime: WorkspaceRuntime? = nil,
            serverBaseURL: URL? = nil,
            routesFileReferencesThroughSession: Bool = false
        ) {
            self.serverID = serverID
            self.workspaceID = workspaceID
            self.worktreeId = worktreeId
            self.sessionID = sessionID
            self.workspaceRuntime = workspaceRuntime
            self.serverBaseURL = serverBaseURL
            self.routesFileReferencesThroughSession = routesFileReferencesThroughSession
        }
    }

    let identity: Identity
    /// Workspace-relative image bytes for `(workspaceID, path)`.
    let fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    /// Session-file image bytes for `(workspaceID, sessionID, path)`.
    let fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    /// Owner-host image bytes. Sandbox owners remap guest POSIX paths.
    let fetchHostFile: ((_ path: String) async throws -> Data)?
    let makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?
    let makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider?
    let makeMarkdownUSDZFile: MarkdownUSDZFileProvider?
    let makeTimedTextSidecar: TimedTextSidecarProvider?
    /// Shared playback owner for Markdown audio strips.
    let audioPlayer: AudioPlayerService?

    init(
        identity: Identity = Identity(),
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? = nil,
        fetchHostFile: ((_ path: String) async throws -> Data)? = nil,
        makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider? = nil,
        makeMarkdownAudioSource: MarkdownAudioMediaSourceProvider? = nil,
        makeMarkdownUSDZFile: MarkdownUSDZFileProvider? = nil,
        makeTimedTextSidecar: TimedTextSidecarProvider? = nil,
        audioPlayer: AudioPlayerService? = nil
    ) {
        self.identity = identity
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        self.fetchHostFile = fetchHostFile
        self.makeMarkdownVideoSource = makeMarkdownVideoSource
        self.makeMarkdownAudioSource = makeMarkdownAudioSource
        self.makeMarkdownUSDZFile = makeMarkdownUSDZFile
        self.makeTimedTextSidecar = makeTimedTextSidecar
        self.audioPlayer = audioPlayer
    }

    /// No source and no providers: export, ask cards, and plain files.
    static var empty: Self { Self() }
}
