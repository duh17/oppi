import UIKit

/// The shell's `.chatReader` route: a full-screen reader pushed from a chat's
/// timeline, an extension drawer, or another reader.
///
/// The payload lives in `ChatReaderPayloadStore`, never in the route; this
/// screen keeps the first one it resolves, so a later eviction cannot blank a
/// reader that is on screen. The payload's content picks the page: a document
/// or image in its own reader chrome, the audio player, video, Now Playing, or
/// an extension surface. Every page draws its own Back, so the stack's bar is
/// hidden while a page shows.
///
/// A reader shows content from its origin chat, so it follows that chat's lock:
/// while the lock is engaged the cover replaces the page and nothing of the
/// content stays mounted, and unlocking (which authorizes the scope) builds the
/// page again. A reader with content but no origin cannot be checked and stays
/// covered, with Close, while any lock exists.
@MainActor
final class ChatReaderViewController: UIViewController, NavigationBarHiding {
    let target: ChatReaderNavTarget

    private enum Shown: Equatable {
        case unavailable
        case closeCover
        case lockCover(ScopedLockTarget)
        case page
    }

    private let store: ChatReaderPayloadStore
    private let navigation: AppNavigation
    private let payloadHolder = ChatReaderPayloadHolder()
    private var shown: Shown?
    private var cover: ScopedLockCoverViewController?
    /// The mounted page; nil while a cover or the unavailable state shows.
    private(set) var page: UIViewController?
    /// The mounted reader's edit entry, when the payload names a live document.
    private var editOwner: DocumentEditOwner?
    private weak var editReader: FullScreenCodeViewController?

    init(target: ChatReaderNavTarget, store: ChatReaderPayloadStore, navigation: AppNavigation) {
        self.target = target
        self.store = store
        self.navigation = navigation
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    convenience init(target: ChatReaderNavTarget, root: AppRootEnvironment) {
        self.init(target: target, store: root.chatReaderPayloadStore, navigation: root.navigation)
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The pages bring their own Back; a cover or the unavailable message
    /// needs the stack's. The stack's delegate asks before the reader is
    /// laid out, so the answer builds the content first.
    var hidesNavigationBar: Bool {
        loadViewIfNeeded()
        return shown == .page
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        updateContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        releasePayloadIfLeft()
        // Back reports the pop to app navigation just after UIKit reports the
        // disappearance, so look again once that has run.
        if isMovingFromParent {
            Task { @MainActor [weak self] in self?.releasePayloadIfLeft() }
        }
    }

    /// A reader still on the stack (covered by a nested one, or rebuilt by a
    /// stack/split swap) keeps its payload.
    private func releasePayloadIfLeft() {
        if !navigation.containsChatReader(target) {
            store.remove(target)
        }
    }

    override func updateProperties() {
        super.updateProperties()
        updateContent()
    }

    // MARK: Content

    private func updateContent() {
        let palette = (AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
        view.backgroundColor = palette.ui.bg

        let locks = ScopedLockService.shared
        let payload = payloadHolder.resolve(from: store, target: target)
        let next: Shown
        if let payload {
            if let captured = payload.lockOrigin {
                // The origin chat's workspace is read live: its session can move
                // into a locked workspace while this reader is under another screen.
                let origin = locks.current(captured)
                next = locks.isLocked(origin) ? .lockCover(origin) : .page
            } else {
                next = locks.mayLockUnknownScope ? .closeCover : .page
            }
        } else {
            next = .unavailable
        }
        show(next, payload: payload)
    }

    private func show(_ next: Shown, payload: ChatReaderPayload?) {
        guard shown != next else { return }
        shown = next
        removePage()
        removeCover()
        contentUnavailableConfiguration = nil

        switch next {
        case .page:
            if let payload { mountPage(for: payload) }
        case .lockCover(let origin):
            mountCover(ScopedLockCoverViewController(target: origin, title: String(localized: "Reader")))
        case .closeCover:
            mountCover(ScopedLockCoverViewController(
                title: String(localized: "Reader"),
                closeTitle: String(localized: "Close"),
                onClose: { [weak self] in self?.leave() }
            ))
        case .unavailable:
            let palette = (AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(
                .empty(
                    title: String(localized: "Unable to Open"),
                    systemImage: "doc",
                    message: String(localized: "This reader is no longer available.")
                ),
                palette: palette,
                background: palette.ui.bg
            )
        }
        // The stack's delegate applies the bar as this reader comes forward;
        // a lock or unlock that swaps the page and a cover while it is in
        // front, or the first content built as it is pushed, asks here.
        navigationController?.updateNavigationBar(for: self, animated: false)
    }

    private func leave() {
        Router.finish(self)
    }

    // MARK: Pages

    private func mountPage(for payload: ChatReaderPayload) {
        let openNested: (ChatReaderPayload) -> Void = { [weak self] nested in
            guard let self else { return }
            navigation.openChatReader(
                store.store(
                    nested.inheritingDestination(from: payload),
                    retaining: navigation.containsChatReader
                )
            )
        }
        let back: @MainActor @Sendable () -> Void = { [weak self] in self?.leave() }

        let mounted: UIViewController
        // Document, image, and video pages reach under the top safe area (their
        // own glass bar sits at the top of the screen) and stop at the other
        // safe-area edges. The rest fill the screen and lay out inside it.
        var fillsScreen = false
        var routesNestedOpens = false
        switch payload.kind {
        case .document(let content, let reviewCommentSelectionContext):
            let reader = FullScreenCodeViewController(
                content: content,
                presentationMode: .embedded(onDismiss: back),
                reviewCommentSelectionContext: reviewCommentSelectionContext,
                addToChatDestination: payload.destination
            )
            if let owner = makeEditOwner(subject: payload.editSubject, reader: reader) {
                Task { [weak self] in
                    _ = await owner.read()
                    self?.setNeedsUpdateProperties()
                }
            }
            mounted = reader
            routesNestedOpens = true
        case .image(let image):
            mounted = Self.embeddedNavigation(
                FullScreenImageViewController(
                    image: image,
                    presentationMode: .embedded(onDismiss: back),
                    addToChatDestination: payload.destination
                )
            )
            routesNestedOpens = true
        case .imageData(let data, let mimeType):
            mounted = Self.embeddedNavigation(
                FullScreenImageDataPreviewViewController(
                    data: data,
                    mimeType: mimeType,
                    title: "Preview",
                    presentationMode: .embedded(onDismiss: back),
                    addToChatDestination: payload.destination
                )
            )
            routesNestedOpens = true
        case .audioLyrics(let spec):
            mounted = AudioLyricsPlayerViewController(configuration: .init(
                title: spec.title,
                lyrics: spec.lyrics,
                itemID: spec.itemID,
                audioPlayer: spec.audioPlayer,
                play: spec.play,
                openFile: spec.openFile,
                shareFileData: spec.shareFileData,
                autoplayOnAppear: spec.autoplayOnAppear,
                showsCloseButton: false,
                usesNavigationBackButton: true,
                timedText: spec.timedText,
                sidecarLoader: spec.sidecarLoader,
                dismiss: { back() }
            ))
            fillsScreen = true
        case .video(let spec):
            mounted = ChatReaderVideoPageViewController(content: spec, onLeave: { back() })
        case .nowPlaying(let audioPlayer):
            mounted = InAppNowPlayingPlayerViewController(audioPlayer: audioPlayer, onLeave: { back() })
            fillsScreen = true
        case .extensionNative(let spec):
            mounted = ExtensionNativeSurfaceDetailViewController(
                surface: spec.surface,
                identifierSuffix: spec.identifierSuffix,
                title: spec.title,
                subtitle: spec.subtitle,
                linkContext: spec.linkContext,
                onOpenURL: spec.onOpenURL,
                liveSurface: spec.liveSurface,
                onLeave: { back() }
            )
            fillsScreen = true
        }

        addChild(mounted)
        mounted.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mounted.view)
        let safe = view.safeAreaLayoutGuide
        if fillsScreen {
            NSLayoutConstraint.activate([
                mounted.view.topAnchor.constraint(equalTo: view.topAnchor),
                mounted.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                mounted.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                mounted.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                mounted.view.topAnchor.constraint(equalTo: view.topAnchor),
                mounted.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                mounted.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                mounted.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
        }
        mounted.didMove(toParent: self)
        page = mounted

        // Nested readers and wiki/file links open above this one, so Back
        // returns here. Pages with no document or image to link from keep the
        // default presentation.
        if routesNestedOpens {
            ChatReaderOpenLookup.install(openNested, on: view)
            ChatReaderLinkIntercept.install({ [weak self] request in
                self?.openLinkedFile(request, payload: payload) ?? false
            }, on: view)
        }
    }

    /// The image viewers draw their bar in a navigation controller of their
    /// own, which pops nothing.
    private static func embeddedNavigation(_ viewer: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.interactivePopGestureRecognizer?.isEnabled = false
        return navigation
    }

    /// The reader's edit entry, through the one owner: the pencil opens our
    /// editor on the live file the payload names, and the "…" holds Edit with
    /// Session when the origin chat offered one. A reader whose payload names no
    /// document keeps the bar it had.
    private func makeEditOwner(
        subject: DocumentEditSubject?,
        reader: FullScreenCodeViewController
    ) -> DocumentEditOwner? {
        guard let subject, subject != .snapshot else { return nil }
        let owner = DocumentEditOwner(
            subject: subject,
            serverId: { [weak self] in self?.payloadLockOrigin?.serverId },
            backend: { [weak self] in
                guard let self,
                      let serverId = payloadLockOrigin?.serverId,
                      let api = AppRootEnvironment.near(self)?.coordinator.connection(for: serverId)?.apiClient
                else { return nil }
                return .make(for: subject, api: api)
            },
            handlers: .init(
                makePreview: { [weak reader] text in
                    FullScreenCodeViewController(
                        content: .fromText(text, filePath: reader?.contentFilePath),
                        presentationMode: .contentOnly()
                    )
                }
            ),
            onChange: { [weak self, weak reader] in
                guard let self, let reader else { return }
                reader.setEditBarItems(editOwner?.barItems ?? [])
                editOwner?.updateEditorPage(
                    palette: (AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette,
                    checkoutSubtitle: nil
                )
                editOwner?.presentEditorIfNeeded(from: self)
            }
        )
        editOwner = owner
        editReader = reader
        return owner
    }

    private var payloadLockOrigin: ScopedLockTarget? {
        payloadHolder.resolve(from: store, target: target)?.lockOrigin
    }

    private func removePage() {
        ChatReaderOpenLookup.install(nil, on: view)
        ChatReaderLinkIntercept.install(nil, on: view)
        // The editor holds the live buffer: hand it back before the reader goes.
        editOwner?.finishEditing()
        editOwner = nil
        editReader = nil
        guard let page else { return }
        page.willMove(toParent: nil)
        page.view.removeFromSuperview()
        page.removeFromParent()
        self.page = nil
    }

    private func mountCover(_ cover: ScopedLockCoverViewController) {
        addChild(cover)
        cover.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cover.view)
        NSLayoutConstraint.activate([
            cover.view.topAnchor.constraint(equalTo: view.topAnchor),
            cover.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cover.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        cover.didMove(toParent: self)
        self.cover = cover
    }

    private func removeCover() {
        guard let cover else { return }
        cover.willMove(toParent: nil)
        cover.view.removeFromSuperview()
        cover.removeFromParent()
        self.cover = nil
    }

    // MARK: Links

    /// Opens a wiki or file link from the reader on its own page. Link routing
    /// reads the payload's identity, never whichever chat is active when the
    /// link is tapped.
    private func openLinkedFile(_ request: AppOpenRequest?, payload: ChatReaderPayload) -> Bool {
        let identity = Self.documentIdentity(payload)
        guard let file = ChatReaderLinkedFileRouting.target(
            for: request,
            serverID: identity.serverID,
            workspaceID: identity.workspaceID,
            sessionID: identity.sessionID,
            workspaceRuntime: identity.workspaceRuntime
        ) else {
            return false
        }
        navigation.openWorkspaceLinkedFile(file)
        return true
    }

    /// The source identity the pushed reader was built with.
    private static func documentIdentity(_ payload: ChatReaderPayload) -> MarkdownResourceAccess.Identity {
        if case .document(let content, _) = payload.kind,
           case .markdown(_, _, let resourceAccess, _, _) = content {
            return resourceAccess.identity
        }
        return MarkdownResourceAccess.Identity()
    }
}

/// A video in the reader: the system player under a Back control and the back
/// swipe, since the player draws no Back of its own.
@MainActor
private final class ChatReaderVideoPageViewController: UIViewController {
    private let content: ChatReaderVideoContent
    private let onLeave: @MainActor () -> Void
    private let player = AuthenticatedMediaPlayerViewController()
    private let backButton = UIButton(configuration: .plain())
    private var backSwipe: HorizontalBackSwipeGestureInstaller?

    init(content: ChatReaderVideoContent, onLeave: @escaping @MainActor () -> Void) {
        self.content = content
        self.onLeave = onLeave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        player.configure(
            source: content.source,
            autoplay: true,
            telemetrySource: content.telemetrySource,
            telemetrySessionId: content.telemetrySessionId,
            startedNs: content.startedNs
        )
        addChild(player)
        player.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(player.view)
        player.didMove(toParent: self)

        backButton.accessibilityLabel = String(localized: "Back")
        backButton.accessibilityIdentifier = "fullscreen-video.back"
        backButton.addAction(UIAction { [weak self] _ in self?.onLeave() }, for: .primaryActionTriggered)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            player.view.topAnchor.constraint(equalTo: view.topAnchor),
            player.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            player.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            backButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        let installer = HorizontalBackSwipeGestureInstaller { [weak self] in self?.onLeave() }
        installer.install(on: view)
        backSwipe = installer
    }

    override func updateProperties() {
        super.updateProperties()
        let palette = (AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
        view.backgroundColor = palette.ui.bg
        var back = backButton.configuration ?? .plain()
        back.image = UIImage.scaledSymbol("chevron.backward", style: .body, weight: .semibold)
        back.baseForegroundColor = palette.ui.cyan
        back.background.backgroundColor = palette.ui.bgHighlight.withAlphaComponent(0.9)
        back.background.cornerRadius = 22
        back.contentInsets = .zero
        backButton.configuration = back
    }
}
