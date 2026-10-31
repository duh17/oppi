import UIKit

/// Lightweight key of a pushed chat reader route.
/// Large reader bodies stay in ``ChatReaderPayloadStore``, never in the route.
struct ChatReaderNavTarget: Hashable, Identifiable {
    let id: UUID
}

struct AudioLyricsReaderContent {
    let title: String
    let lyrics: String?
    let itemID: String
    let audioPlayer: AudioPlayerService?
    let play: (TimedText.LoadResult?) -> Void
    let openFile: (() -> Void)?
    var shareFileData: (() async throws -> Data)? = nil
    let autoplayOnAppear: Bool
    var timedText: TimedText.LoadResult? = nil
    var sidecarLoader: (() async -> TimedText.LoadResult)? = nil
}

struct ChatReaderVideoContent {
    let source: AuthenticatedMediaSource
    var telemetrySource: String = "authenticated_media"
    var telemetrySessionId: String? = nil
    var startedNs: UInt64? = nil
}

struct ExtensionNativeReaderContent {
    let surface: ExtensionUINativeSurface
    let identifierSuffix: String
    let title: String
    let subtitle: String?
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)? = nil
    /// Current snapshot for the same surface id; the reader follows widget updates through it.
    var liveSurface: (@MainActor () -> ExtensionUINativeSurface?)? = nil
}

/// Timeline/chat reader body. Only the ``ChatReaderNavTarget`` id rides the path.
struct ChatReaderPayload {
    enum Kind {
        case document(
            content: FullScreenCodeContent,
            reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil
        )
        case image(UIImage)
        case imageData(Data, mimeType: String?)
        case audioLyrics(AudioLyricsReaderContent)
        case video(ChatReaderVideoContent)
        case nowPlaying(AudioPlayerService)
        case extensionNative(ExtensionNativeReaderContent)
    }

    var kind: Kind
    /// Origin chat captured at timeline-open time. Nested readers inherit this, including nil.
    var destination: ComposerCanvasDestination? = nil
    /// Lock scope of the origin chat (server, workspace, session), stamped
    /// with `destination`. The reader shows only while that scope is open.
    var lockOrigin: ScopedLockTarget? = nil
    /// The live document behind the bytes, when the origin chat can name one: the
    /// reader's edit entry then edits that file, not the output the row shows.
    var editSubject: DocumentEditSubject? = nil

    init(
        kind: Kind,
        destination: ComposerCanvasDestination? = nil,
        lockOrigin: ScopedLockTarget? = nil,
        editSubject: DocumentEditSubject? = nil
    ) {
        self.kind = kind
        self.destination = destination
        self.lockOrigin = lockOrigin
        self.editSubject = editSubject
    }

    init(
        content: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        destination: ComposerCanvasDestination? = nil,
        editSubject: DocumentEditSubject? = nil
    ) {
        self.init(
            kind: .document(
                content: content,
                reviewCommentSelectionContext: reviewCommentSelectionContext
            ),
            destination: destination,
            editSubject: editSubject
        )
    }

    static func document(
        content: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        destination: ComposerCanvasDestination? = nil,
        editSubject: DocumentEditSubject? = nil
    ) -> Self {
        Self(
            content: content,
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            destination: destination,
            editSubject: editSubject
        )
    }

    static func image(_ image: UIImage) -> Self {
        Self(kind: .image(image))
    }

    static func imageData(_ data: Data, mimeType: String?) -> Self {
        Self(kind: .imageData(data, mimeType: mimeType))
    }

    static func audioLyrics(_ content: AudioLyricsReaderContent) -> Self {
        Self(kind: .audioLyrics(content))
    }

    static func video(_ content: ChatReaderVideoContent) -> Self {
        Self(kind: .video(content))
    }

    static func nowPlaying(_ audioPlayer: AudioPlayerService) -> Self {
        Self(kind: .nowPlaying(audioPlayer))
    }

    static func extensionNative(_ content: ExtensionNativeReaderContent) -> Self {
        Self(kind: .extensionNative(content))
    }

    /// Stamp the origin chat. Nested opens inherit this value, including nil.
    func stamped(
        with destination: ComposerCanvasDestination?,
        lockOrigin: ScopedLockTarget? = nil
    ) -> Self {
        Self(kind: kind, destination: destination, lockOrigin: lockOrigin, editSubject: editSubject)
    }

    func inheritingDestination(from parent: Self) -> Self {
        Self(
            kind: kind,
            destination: parent.destination,
            lockOrigin: parent.lockOrigin,
            editSubject: parent.editSubject
        )
    }

    var content: FullScreenCodeContent {
        switch kind {
        case .document(let content, _):
            return content
        case .image, .imageData, .audioLyrics, .video, .nowPlaying, .extensionNative:
            preconditionFailure("ChatReaderPayload.content requires a document")
        }
    }

    var reviewCommentSelectionContext: ReviewCommentSelectionContext? {
        switch kind {
        case .document(_, let context):
            return context
        case .image, .imageData, .audioLyrics, .video, .nowPlaying, .extensionNative:
            return nil
        }
    }

    /// The file the document names, when it names one.
    var contentFilePath: String? {
        switch kind {
        case .document(let content, _):
            return content.filePath
        case .image, .imageData, .audioLyrics, .video, .nowPlaying, .extensionNative:
            return nil
        }
    }

    /// The same reader, with the live document behind it when none was named.
    func withLiveFileSubject(_ subject: DocumentEditSubject?) -> Self {
        guard let subject, editSubject == nil else { return self }
        return Self(kind: kind, destination: destination, lockOrigin: lockOrigin, editSubject: subject)
    }
}

/// Walk-up opener so nested UIKit rows can push without stuffing bodies into the path.
@MainActor
enum ChatReaderOpenLookup {
    private static var key: UInt8 = 0

    private final class Box: NSObject {
        let open: (ChatReaderPayload) -> Void
        init(_ open: @escaping (ChatReaderPayload) -> Void) {
            self.open = open
        }
    }

    static func install(_ open: ((ChatReaderPayload) -> Void)?, on view: UIView) {
        objc_setAssociatedObject(
            view,
            &key,
            open.map(Box.init),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func resolve(from view: UIView) -> ((ChatReaderPayload) -> Void)? {
        if let found = resolveWalkingResponders(from: view) {
            return found
        }
        return resolveWalkingDescendants(from: view)
    }

    private static func resolveWalkingResponders(from view: UIView) -> ((ChatReaderPayload) -> Void)? {
        var current: UIResponder? = view
        while let node = current {
            if let asView = node as? UIView,
               let box = objc_getAssociatedObject(asView, &key) as? Box {
                return box.open
            }
            current = node.next
        }
        return nil
    }

    private static func resolveWalkingDescendants(from view: UIView) -> ((ChatReaderPayload) -> Void)? {
        var stack = view.subviews
        while let next = stack.popLast() {
            if let box = objc_getAssociatedObject(next, &key) as? Box {
                return box.open
            }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }

    @discardableResult
    static func open(_ payload: ChatReaderPayload, from view: UIView) -> Bool {
        guard let open = resolve(from: view) else { return false }
        open(payload)
        return true
    }

    @discardableResult
    static func open(_ payload: ChatReaderPayload, from controller: UIViewController) -> Bool {
        var current: UIViewController? = controller
        while let node = current {
            if open(payload, from: node.view) {
                return true
            }
            current = node.parent
        }
        return false
    }
}

/// Wiki/file-link intercept for a pushed reader so Back returns to that reader.
@MainActor
enum ChatReaderLinkIntercept {
    private static var key: UInt8 = 0

    private final class Box: NSObject {
        let handle: (AppOpenRequest?) -> Bool
        init(_ handle: @escaping (AppOpenRequest?) -> Bool) {
            self.handle = handle
        }
    }

    static func install(_ handle: ((AppOpenRequest?) -> Bool)?, on view: UIView) {
        objc_setAssociatedObject(
            view,
            &key,
            handle.map(Box.init),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func canHandle(from view: UIView) -> Bool {
        resolve(from: view) != nil
    }

    @discardableResult
    static func handle(_ request: AppOpenRequest?, from view: UIView) -> Bool {
        guard let handle = resolve(from: view) else { return false }
        return handle(request)
    }

    private static func resolve(from view: UIView) -> ((AppOpenRequest?) -> Bool)? {
        var current: UIView? = view
        while let node = current {
            if let box = objc_getAssociatedObject(node, &key) as? Box {
                return box.handle
            }
            current = node.superview
        }
        return nil
    }
}

enum ChatReaderLinkedFileRouting {
    static func target(
        for request: AppOpenRequest?,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        workspaceRuntime: WorkspaceRuntime? = nil
    ) -> WorkspaceLinkedFileNavTarget? {
        switch request {
        case .sessionFile(let reference)?:
            return sessionFileTarget(for: reference)
        case .fileLink(let payload)?:
            guard let serverID, !serverID.isEmpty else { return nil }
            return .workspaceFile(
                serverId: serverID,
                workspaceId: payload.workspaceID,
                path: payload.filePath,
                sourceSessionId: sessionID
            )
        case .resourceReference(let reference):
            return resourceFileTarget(
                reference,
                serverID: serverID,
                workspaceID: workspaceID,
                sessionID: sessionID,
                workspaceRuntime: workspaceRuntime
            )
        default:
            return nil
        }
    }

    private static func sessionFileTarget(
        for reference: ResourceReference
    ) -> WorkspaceLinkedFileNavTarget? {
        AppOpener.sessionFileTarget(for: reference)
    }

    private static func resourceFileTarget(
        _ reference: ResourceReference,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        workspaceRuntime: WorkspaceRuntime?
    ) -> WorkspaceLinkedFileNavTarget? {
        let serverID = reference.sourceServerID ?? serverID
        let workspaceID = reference.workspaceID ?? workspaceID
        let sessionID = reference.sourceSessionID ?? sessionID
        guard let serverID, !serverID.isEmpty,
              let path = reference.fileCandidatePath, !path.isEmpty else {
            return nil
        }
        if workspaceRuntime != .host,
           let sessionID, !sessionID.isEmpty,
           let workspaceID, !workspaceID.isEmpty {
            return .sessionFile(
                serverId: serverID,
                workspaceId: workspaceID,
                sessionId: sessionID,
                path: path,
                lineAnchor: reference.lineAnchor,
                sourceSessionId: sessionID
            )
        }
        if reference.kind == .hostFile {
            return .hostFile(
                serverId: serverID,
                workspaceId: workspaceID ?? "",
                path: path,
                lineAnchor: reference.lineAnchor,
                sourceSessionId: sessionID
            )
        }
        if let sessionID, !sessionID.isEmpty,
           let workspaceID, !workspaceID.isEmpty {
            return .sessionFile(
                serverId: serverID,
                workspaceId: workspaceID,
                sessionId: sessionID,
                path: path,
                lineAnchor: reference.lineAnchor,
                sourceSessionId: sessionID
            )
        }
        if let workspaceID, !workspaceID.isEmpty {
            return .workspaceFile(
                serverId: serverID,
                workspaceId: workspaceID,
                path: path,
                lineAnchor: reference.lineAnchor,
                sourceSessionId: sessionID
            )
        }
        return .hostFile(
            serverId: serverID,
            workspaceId: workspaceID ?? "",
            path: path,
            lineAnchor: reference.lineAnchor,
            sourceSessionId: sessionID
        )
    }
}

/// Session-scoped store for timeline-originated readers.
@MainActor
final class ChatReaderPayloadStore {
    private var payloads: [UUID: ChatReaderPayload] = [:]

    func store(_ payload: ChatReaderPayload) -> ChatReaderNavTarget {
        let target = ChatReaderNavTarget(id: UUID())
        payloads[target.id] = payload
        return target
    }

    func store(
        _ payload: ChatReaderPayload,
        retaining stacked: (ChatReaderNavTarget) -> Bool
    ) -> ChatReaderNavTarget {
        for id in Array(payloads.keys) where !stacked(ChatReaderNavTarget(id: id)) {
            payloads[id] = nil
        }
        return store(payload)
    }

    func payload(for id: UUID) -> ChatReaderPayload? {
        payloads[id]
    }

    func remove(_ target: ChatReaderNavTarget) {
        payloads[target.id] = nil
    }

    func removeAll() {
        payloads.removeAll()
    }
}

/// Keeps the first successful store lookup so a later eviction cannot blank
/// a reader that is already on screen.
@MainActor
final class ChatReaderPayloadHolder {
    private var held: ChatReaderPayload?

    func resolve(from store: ChatReaderPayloadStore, target: ChatReaderNavTarget) -> ChatReaderPayload? {
        if let held {
            return held
        }
        guard let payload = store.payload(for: target.id) else {
            return nil
        }
        held = payload
        return payload
    }
}

/// Viewport captured when a linked markdown reader is covered by another file.
///
/// Restore key is the reader's file path so a sibling file in the same
/// destination cannot inherit the offset. A later laid-out `.top` replaces a
/// stored mid-document intent; unlaid-out remakes must not emit `.top`.
struct FullScreenMarkdownViewportRestoreState: Equatable {
    private var intentsByFilePath: [String: FullScreenMarkdownViewportIntent] = [:]

    static func key(filePath: String) -> String {
        filePath
    }

    subscript(filePath: String) -> FullScreenMarkdownViewportIntent? {
        get { intentsByFilePath[Self.key(filePath: filePath)] }
        set { intentsByFilePath[Self.key(filePath: filePath)] = newValue }
    }
}
