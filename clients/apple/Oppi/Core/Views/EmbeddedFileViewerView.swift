import SwiftUI

/// Lightweight NavigationPath / `navigationDestination(item:)` key.
/// Large reader bodies stay in ``ChatReaderPayloadStore``, never in the path.
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
    let statusText: String?
    var linkContext: ExtensionSurfaceLinkContext = .empty
    var onOpenURL: ((URL) -> Bool)? = nil
}

/// Timeline/chat reader body. Only the ``ChatReaderNavTarget`` id rides the path.
enum ChatReaderPayload {
    case document(
        content: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil
    )
    case image(UIImage, addToChatDestination: ComposerCanvasDestination? = nil)
    case imageData(Data, mimeType: String?, addToChatDestination: ComposerCanvasDestination? = nil)
    case audioLyrics(AudioLyricsReaderContent)
    case video(ChatReaderVideoContent)
    case nowPlaying(AudioPlayerService)
    case extensionNative(ExtensionNativeReaderContent)

    init(
        content: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil
    ) {
        self = .document(
            content: content,
            reviewCommentSelectionContext: reviewCommentSelectionContext
        )
    }

    var content: FullScreenCodeContent {
        switch self {
        case .document(let content, _):
            return content
        case .image, .imageData, .audioLyrics, .video, .nowPlaying, .extensionNative:
            preconditionFailure("ChatReaderPayload.content requires a document")
        }
    }

    var reviewCommentSelectionContext: ReviewCommentSelectionContext? {
        switch self {
        case .document(_, let context):
            return context
        case .image, .imageData, .audioLyrics, .video, .nowPlaying, .extensionNative:
            return nil
        }
    }
}

struct ChatReaderOpenAction {
    let handler: (ChatReaderPayload) -> Void

    func callAsFunction(_ payload: ChatReaderPayload) {
        handler(payload)
    }
}

private struct ChatReaderOpenActionKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ChatReaderOpenAction? = nil
}

extension EnvironmentValues {
    var openChatReader: ChatReaderOpenAction? {
        get { self[ChatReaderOpenActionKey.self] }
        set { self[ChatReaderOpenActionKey.self] = newValue }
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
            current = node.parent ?? node.presentingViewController
        }
        return false
    }
}

/// Wiki/file-link intercept for a pushed reader so Back returns to that reader.
@MainActor
enum ChatReaderLinkIntercept {
    private static var key: UInt8 = 0

    private final class Box: NSObject {
        let handle: (LinkAction) -> Bool
        init(_ handle: @escaping (LinkAction) -> Bool) {
            self.handle = handle
        }
    }

    static func install(_ handle: ((LinkAction) -> Bool)?, on view: UIView) {
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
    static func handle(_ action: LinkAction, from view: UIView) -> Bool {
        guard let handle = resolve(from: view) else { return false }
        return handle(action)
    }

    private static func resolve(from view: UIView) -> ((LinkAction) -> Bool)? {
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
        for action: LinkAction,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?
    ) -> WorkspaceLinkedFileNavTarget? {
        switch action {
        case .sessionFileReference(let reference):
            return sessionFileTarget(for: reference)
        case .fileLink(let payload):
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
                sessionID: sessionID
            )
        case .deepLink, .inAppSessionLink, .webLink, .systemDefault:
            return nil
        }
    }

    private static func sessionFileTarget(
        for reference: ResourceReference
    ) -> WorkspaceLinkedFileNavTarget? {
        guard let serverID = reference.sourceServerID,
              let workspaceID = reference.workspaceID,
              let sessionID = reference.sourceSessionID,
              let path = reference.fileCandidatePath,
              !serverID.isEmpty,
              !workspaceID.isEmpty,
              !sessionID.isEmpty,
              !path.isEmpty else {
            return nil
        }
        return .sessionFile(
            serverId: serverID,
            workspaceId: workspaceID,
            sessionId: sessionID,
            path: path,
            lineAnchor: reference.lineAnchor,
            sourceSessionId: sessionID
        )
    }

    private static func resourceFileTarget(
        _ reference: ResourceReference,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?
    ) -> WorkspaceLinkedFileNavTarget? {
        let serverID = reference.sourceServerID ?? serverID
        let workspaceID = reference.workspaceID ?? workspaceID
        let sessionID = reference.sourceSessionID ?? sessionID
        guard let serverID, !serverID.isEmpty,
              let path = reference.fileCandidatePath, !path.isEmpty else {
            return nil
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
@MainActor @Observable
final class ChatReaderPayloadStore {
    private var payloads: [UUID: ChatReaderPayload] = [:]

    func store(_ payload: ChatReaderPayload) -> ChatReaderNavTarget {
        let target = ChatReaderNavTarget(id: UUID())
        payloads[target.id] = payload
        return target
    }

    func payload(for id: UUID) -> ChatReaderPayload? {
        payloads[id]
    }

    func remove(_ target: ChatReaderNavTarget) {
        payloads[target.id] = nil
    }
}

/// Pushed reader page. Documents keep ``EmbeddedFileViewerView`` chrome.
/// Nested wiki/file/media opens stay on this inner stack so Back returns here.
struct ChatReaderDestinationView: View {
    let target: ChatReaderNavTarget
    let store: ChatReaderPayloadStore
    @State private var nestedPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $nestedPath) {
            readerPage(for: target)
                .navigationDestination(for: ChatReaderNavTarget.self) { nested in
                    readerPage(for: nested)
                }
                .navigationDestination(for: WorkspaceLinkedFileNavTarget.self) { file in
                    WorkspaceLinkedFileDestinationView(target: file)
                        .toolbarVisibility(.hidden, for: .navigationBar)
                }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func readerPage(for target: ChatReaderNavTarget) -> some View {
        ChatReaderPageView(
            target: target,
            store: store,
            onOpenNestedReader: { payload in
                nestedPath.append(store.store(payload))
            },
            onOpenLinkedFile: { action in
                openLinkedFile(action)
            }
        )
    }

    private func openLinkedFile(_ action: LinkAction) -> Bool {
        guard let payload = store.payload(for: target.id),
              let file = linkedFileTarget(for: action, payload: payload) else {
            return false
        }
        nestedPath.append(file)
        return true
    }

    private func linkedFileTarget(
        for action: LinkAction,
        payload: ChatReaderPayload
    ) -> WorkspaceLinkedFileNavTarget? {
        let context = documentWorkspaceContext(payload)
        return ChatReaderLinkedFileRouting.target(
            for: action,
            serverID: context?.serverID,
            workspaceID: context?.workspaceID,
            sessionID: context?.sessionID
        )
    }

    private func documentWorkspaceContext(
        _ payload: ChatReaderPayload
    ) -> FullScreenCodeContent.WorkspaceContext? {
        switch payload {
        case .document(let content, _):
            if case .markdown(_, _, let context) = content {
                return context
            }
            return nil
        case .image, .imageData, .audioLyrics, .video, .nowPlaying, .extensionNative:
            return nil
        }
    }

#if DEBUG
    func debugMakeControllerForTesting() -> FullScreenCodeViewController? {
        ChatReaderPageView(
            target: target,
            store: store,
            onOpenNestedReader: { _ in },
            onOpenLinkedFile: { _ in false }
        ).debugMakeControllerForTesting()
    }
#endif
}

private struct ChatReaderPageView: View {
    let target: ChatReaderNavTarget
    let store: ChatReaderPayloadStore
    let onOpenNestedReader: (ChatReaderPayload) -> Void
    let onOpenLinkedFile: (LinkAction) -> Bool

    var body: some View {
        Group {
            if let payload = store.payload(for: target.id) {
                page(for: payload)
                    .environment(
                        \.openChatReader,
                        ChatReaderOpenAction(handler: onOpenNestedReader)
                    )
            } else {
                ContentUnavailableView(
                    "Unable to Open",
                    systemImage: "doc",
                    description: Text("This reader is no longer available.")
                )
            }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func page(for payload: ChatReaderPayload) -> some View {
        switch payload {
        case .document(let content, let reviewCommentSelectionContext):
            EmbeddedFileViewerView(
                content: content,
                reviewCommentSelectionContext: reviewCommentSelectionContext,
                onOpenNestedReader: onOpenNestedReader,
                onOpenLinkedFile: onOpenLinkedFile
            )
            .ignoresSafeArea(edges: .top)
        case .image(let image, let destination):
            EmbeddedImageViewerView(
                image: image,
                addToChatDestination: destination,
                onOpenNestedReader: onOpenNestedReader,
                onOpenLinkedFile: onOpenLinkedFile
            )
            .ignoresSafeArea(edges: .top)
        case .imageData(let data, let mimeType, let destination):
            EmbeddedImageDataViewerView(
                data: data,
                mimeType: mimeType,
                addToChatDestination: destination,
                onOpenNestedReader: onOpenNestedReader,
                onOpenLinkedFile: onOpenLinkedFile
            )
            .ignoresSafeArea(edges: .top)
        case .audioLyrics(let spec):
            AudioLyricsPlayerView(
                title: spec.title,
                lyrics: spec.lyrics,
                itemID: spec.itemID,
                audioPlayer: spec.audioPlayer,
                play: spec.play,
                openFile: spec.openFile,
                autoplayOnAppear: spec.autoplayOnAppear,
                showsCloseButton: false,
                usesNavigationBackButton: true,
                timedText: spec.timedText,
                sidecarLoader: spec.sidecarLoader
            )
        case .video(let spec):
            EmbeddedVideoPlayerView(content: spec)
                .ignoresSafeArea(edges: .top)
                .pushedReaderLeaveChrome(accessibilityIdentifier: "fullscreen-video.back")
        case .nowPlaying(let audioPlayer):
            InAppNowPlayingPlayerScreen(audioPlayer: audioPlayer)
        case .extensionNative(let spec):
            ExtensionNativeSurfaceDetailSheet(
                surface: spec.surface,
                identifierSuffix: spec.identifierSuffix,
                title: spec.title,
                subtitle: spec.subtitle,
                statusText: spec.statusText,
                linkContext: spec.linkContext,
                onOpenURL: spec.onOpenURL,
                usesNavigationBackChrome: true
            )
        }
    }

#if DEBUG
    func debugMakeControllerForTesting() -> FullScreenCodeViewController? {
        guard let payload = store.payload(for: target.id),
              case .document(let content, let context) = payload else {
            return nil
        }
        return EmbeddedFileViewerView(
            content: content,
            reviewCommentSelectionContext: context
        ).debugMakeControllerForTesting()
    }
#endif
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

extension Binding where Value == FullScreenMarkdownViewportRestoreState {
    func intent(for filePath: String) -> Binding<FullScreenMarkdownViewportIntent?> {
        Binding<FullScreenMarkdownViewportIntent?>(
            get: { wrappedValue[filePath] },
            set: { wrappedValue[filePath] = $0 }
        )
    }
}

/// Embeds ``FullScreenCodeViewController`` inside a SwiftUI NavigationStack.
///
/// The UIKit view controller provides its own internal `UINavigationController`
/// with Liquid Glass floating pills — identical chrome to the sheet presentation
/// used by the timeline full-screen viewer. The hosting SwiftUI view should hide
/// its navigation bar (`.toolbarVisibility(.hidden, for: .navigationBar)`) to
/// avoid double nav bars.
///
/// The dismiss (back) button calls SwiftUI's `dismiss()` to pop the navigation.
///
/// Review comment selection routing: reads from `\.reviewCommentSelectionScope`
/// in the SwiftUI environment when no explicit router is provided. This means new
/// callers get comment routing for free as long as the environment is set by an
/// ancestor (which `ContentView` does at the root level).
///
/// Usage:
/// ```swift
/// NavigationLink {
///     EmbeddedFileViewerView(
///         content: .fromText(text, filePath: path)
///     )
///     .ignoresSafeArea(edges: .top)
///     .toolbarVisibility(.hidden, for: .navigationBar)
/// } label: { ... }
/// ```
struct EmbeddedFileViewerView: UIViewControllerRepresentable {
    let content: FullScreenCodeContent
    var reviewCommentSelectionContext: ReviewCommentSelectionContext?
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    var reviewCommentSessionId: String?
    var reviewCommentSourceLabel: String?
    var lineAnchor: SourceLineAnchor? = nil
    var lineAnchorNotice: (@MainActor @Sendable (String) -> Void)? = nil
    var showsNavigationChrome = true
    var backSwipeAction: (@MainActor @Sendable () -> Void)?
    var navigationActions: [FullScreenViewerNavigationAction] = []
    var markdownViewportIntent: Binding<FullScreenMarkdownViewportIntent?>? = nil
    var addToChatDestination: ComposerCanvasDestination? = nil
    var leadingFloatingAccessoryCount: Int = 0
    var onOpenNestedReader: ((ChatReaderPayload) -> Void)? = nil
    var onOpenLinkedFile: ((LinkAction) -> Bool)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.reviewCommentSelectionScope) private var reviewCommentSelectionScope
    @Environment(\.themeID) private var themeID

    /// Effective action context for this embedded fullscreen presentation.
    private var effectiveReviewCommentSelectionContext: ReviewCommentSelectionContext? {
        reviewCommentSelectionContext
            ?? reviewCommentSelectionRouter.map { ReviewCommentSelectionContext(router: $0, sessionId: reviewCommentSessionId, sourceLabel: reviewCommentSourceLabel) }
            ?? reviewCommentSelectionScope?.makeContext(
                sessionId: reviewCommentSessionId,
                sourceLabel: reviewCommentSourceLabel
            )
    }

    func makeUIViewController(context: Context) -> FullScreenCodeViewController {
        let dismissAction = dismiss
        let presentationMode: FullScreenCodeViewController.PresentationMode
        if showsNavigationChrome {
            presentationMode = .embedded(onDismiss: { dismissAction() })
        } else {
            let backSwipeAction = backSwipeAction
            presentationMode = .contentOnly(onBackSwipe: { backSwipeAction?() ?? dismissAction() })
        }
        let viewportBinding = markdownViewportIntent
        let viewController = FullScreenCodeViewController(
            content: content,
            presentationMode: presentationMode,
            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            lineAnchorNotice: lineAnchorNotice,
            navigationActions: navigationActions,
            markdownViewportIntent: viewportBinding?.wrappedValue,
            onMarkdownViewportIntentChange: { intent in
                viewportBinding?.wrappedValue = intent
            },
            addToChatDestination: addToChatDestination
        )
        viewController.setLeadingFloatingAccessoryCount(leadingFloatingAccessoryCount)
        ChatReaderOpenLookup.install(onOpenNestedReader, on: viewController.view)
        ChatReaderLinkIntercept.install(onOpenLinkedFile, on: viewController.view)
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: FullScreenCodeViewController,
        context: Context
    ) {
        uiViewController.setNavigationActions(navigationActions)
        uiViewController.applyThemeIfNeeded(themeID)
        uiViewController.setLeadingFloatingAccessoryCount(leadingFloatingAccessoryCount)
        ChatReaderOpenLookup.install(onOpenNestedReader, on: uiViewController.view)
        ChatReaderLinkIntercept.install(onOpenLinkedFile, on: uiViewController.view)
    }

#if DEBUG
    func debugMakeControllerForTesting() -> FullScreenCodeViewController {
        let controller = FullScreenCodeViewController(
            content: content,
            presentationMode: showsNavigationChrome
                ? .embedded(onDismiss: {})
                : .contentOnly(onBackSwipe: {}),
            reviewCommentSelectionContext: effectiveReviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            lineAnchorNotice: lineAnchorNotice,
            navigationActions: navigationActions,
            markdownViewportIntent: markdownViewportIntent?.wrappedValue,
            addToChatDestination: addToChatDestination
        )
        controller.setLeadingFloatingAccessoryCount(leadingFloatingAccessoryCount)
        return controller
    }
#endif
}

struct EmbeddedImageViewerView: UIViewControllerRepresentable {
    let image: UIImage
    var addToChatDestination: ComposerCanvasDestination?
    var onOpenNestedReader: ((ChatReaderPayload) -> Void)? = nil
    var onOpenLinkedFile: ((LinkAction) -> Bool)? = nil

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        let dismissAction = dismiss
        let viewer = FullScreenImageViewController(
            image: image,
            presentationMode: .embedded(onDismiss: { dismissAction() }),
            addToChatDestination: addToChatDestination
        )
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.interactivePopGestureRecognizer?.isEnabled = false
        installLookups(on: navigation.view)
        return navigation
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        installLookups(on: uiViewController.view)
    }

    private func installLookups(on view: UIView) {
        ChatReaderOpenLookup.install(onOpenNestedReader, on: view)
        ChatReaderLinkIntercept.install(onOpenLinkedFile, on: view)
    }

#if DEBUG
    func debugMakeControllerForTesting() -> UIViewController {
        let viewer = FullScreenImageViewController(
            image: image,
            presentationMode: .embedded(onDismiss: {}),
            addToChatDestination: addToChatDestination
        )
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.interactivePopGestureRecognizer?.isEnabled = false
        return navigation
    }
#endif
}

struct EmbeddedImageDataViewerView: UIViewControllerRepresentable {
    let data: Data
    let mimeType: String?
    var addToChatDestination: ComposerCanvasDestination?
    var onOpenNestedReader: ((ChatReaderPayload) -> Void)? = nil
    var onOpenLinkedFile: ((LinkAction) -> Bool)? = nil

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        let dismissAction = dismiss
        let viewer = FullScreenImageDataPreviewViewController(
            data: data,
            mimeType: mimeType,
            title: "Preview",
            presentationMode: .embedded(onDismiss: { dismissAction() }),
            addToChatDestination: addToChatDestination
        )
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.interactivePopGestureRecognizer?.isEnabled = false
        installLookups(on: navigation.view)
        return navigation
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        installLookups(on: uiViewController.view)
    }

    private func installLookups(on view: UIView) {
        ChatReaderOpenLookup.install(onOpenNestedReader, on: view)
        ChatReaderLinkIntercept.install(onOpenLinkedFile, on: view)
    }
}

struct EmbeddedVideoPlayerView: UIViewControllerRepresentable {
    let content: ChatReaderVideoContent

    func makeUIViewController(context: Context) -> AuthenticatedMediaPlayerViewController {
        let controller = AuthenticatedMediaPlayerViewController()
        controller.configure(
            source: content.source,
            autoplay: true,
            telemetrySource: content.telemetrySource,
            telemetrySessionId: content.telemetrySessionId,
            startedNs: content.startedNs
        )
        return controller
    }

    func updateUIViewController(
        _ uiViewController: AuthenticatedMediaPlayerViewController,
        context: Context
    ) {}
}

private struct PushedReaderLeaveChrome: ViewModifier {
    let accessibilityIdentifier: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.themeCyan)
                        .frame(width: 44, height: 44)
                        .background(.themeBgHighlight.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Back"))
                .accessibilityIdentifier(accessibilityIdentifier)
                .padding(.leading, 16)
                .padding(.top, 12)
            }
            .horizontalBackSwipeGesture { dismiss() }
    }
}

extension View {
    fileprivate func pushedReaderLeaveChrome(accessibilityIdentifier: String) -> some View {
        modifier(PushedReaderLeaveChrome(accessibilityIdentifier: accessibilityIdentifier))
    }
}
