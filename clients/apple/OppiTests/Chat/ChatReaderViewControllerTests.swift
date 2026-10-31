import Testing
import UIKit
@testable import Oppi

/// The shell's `.chatReader` screen: which page a payload mounts, and the
/// lock rules around it (a locked scope never shows content).
@Suite("Chat reader screen")
@MainActor
struct ChatReaderViewControllerTests {
    private struct Host {
        let window: UIWindow
        let navigation: UINavigationController
        let reader: ChatReaderViewController
        let store: ChatReaderPayloadStore
        let appNavigation: AppNavigation

        func close() { window.isHidden = true }
    }

    private func push(_ payload: ChatReaderPayload?) -> Host {
        push(payload, editBackend: nil)
    }

    /// A reader whose live document is served by `editBackend` instead of the
    /// app root, which these tests do not build.
    private func push(
        _ payload: ChatReaderPayload?,
        editBackend: (@MainActor (DocumentEditSubject) -> DocumentEditOwner.Backend?)?
    ) -> Host {
        forgetSharedScopedLockFlags()
        let store = ChatReaderPayloadStore()
        let appNavigation = AppNavigation()
        let target = payload.map { store.store($0) } ?? ChatReaderNavTarget(id: UUID())
        appNavigation.openChatReader(target)
        let reader = ChatReaderViewController(
            target: target,
            store: store,
            navigation: appNavigation,
            editBackend: editBackend
        )
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(reader, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        // A window with no scene never draws, and the pencil capture below is a
        // picture of this window.
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.view.layoutIfNeeded()
        return Host(window: window, navigation: navigation, reader: reader, store: store, appNavigation: appNavigation)
    }

    /// A tool row's reader whose live document is a tagged text read: the pencil
    /// must reach the reader's bar after that read, with no owner state change to
    /// trigger it.
    @Test("a tool row's reader shows the pencil its live document earns")
    func toolRowReaderShowsThePencil() async throws {
        var payload = ChatReaderPayload(
            kind: .document(content: .code(content: "let a = 1", language: "swift", filePath: "src/a.swift", startLine: 1))
        )
        payload.editSubject = .file(
            serverId: "s1",
            source: .workspaceFile,
            workspaceId: "w1",
            worktreeId: nil,
            path: "src/a.swift",
            skillFile: nil,
            fileType: .code(language: .swift)
        )
        let snapshot = WorkspaceFileDiskSnapshot(bytes: Data("let a = 1".utf8), etag: "\"sha256-a\"")
        let host = push(payload) { _ in
            DocumentEditOwner.Backend(
                capability: { _ in ServerInfo.WorkspaceFileEditingCapability(version: 1, maxBytes: 1_048_576) },
                transport: WorkspaceFileEditTransport(
                    read: { _ in .snapshot(snapshot) },
                    write: { _, _, _ in .notSent }
                )
            )
        }
        defer { host.close() }
        _ = try #require(host.reader.page)

        var waited = 0
        while !pencilIsInTheWindow(host), waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            host.window.layoutIfNeeded()
            waited += 1
        }
        #expect(
            pencilIsInTheWindow(host),
            "the tool row's pencil never reached the reader's bar: \(identifiers(in: host.window).joined(separator: ", ")) | bars: \(barButtonIdentifiers(in: host.window).joined(separator: ", "))"
        )
    }

    /// Every identifier the window's views carry, for a failure that says what
    /// the bar does hold instead of only that the pencil is missing.
    private func identifiers(in root: UIView) -> [String] {
        let own = root.accessibilityIdentifier.map { [$0] } ?? []
        return own + root.subviews.flatMap { identifiers(in: $0) }
    }

    /// The pencil the reader installed, found where a person sees it: a view or a
    /// bar item with the shared identifier in the window's own hierarchy, after
    /// layout. Nothing about the reader's internals is asked.
    private func pencilIsInTheWindow(_ host: Host) -> Bool {
        host.window.layoutIfNeeded()
        if descendant(identifier: "workspace-file-editor.edit", in: host.window) != nil { return true }
        return barButtonIdentifiers(in: host.window).contains("workspace-file-editor.edit")
    }

    /// The identifiers of the bar items the bars in this hierarchy carry. A bar
    /// button's own view need not repeat its item's identifier, so the bars are
    /// asked as well as their views.
    private func barButtonIdentifiers(in root: UIView) -> [String] {
        var identifiers: [String] = []
        if let bar = root as? UINavigationBar {
            for item in bar.items ?? [] {
                identifiers += (item.leftBarButtonItems ?? []).compactMap(\.accessibilityIdentifier)
                identifiers += (item.rightBarButtonItems ?? []).compactMap(\.accessibilityIdentifier)
            }
        }
        if let bar = root as? UIToolbar {
            identifiers += (bar.items ?? []).compactMap(\.accessibilityIdentifier)
        }
        return root.subviews.reduce(identifiers) { $0 + barButtonIdentifiers(in: $1) }
    }

    private func descendant(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        return root.subviews.lazy.compactMap { descendant(identifier: identifier, in: $0) }.first
    }

    private func documentPayload(lockOrigin: ScopedLockTarget? = nil) -> ChatReaderPayload {
        ChatReaderPayload(
            kind: .document(content: .plainText(content: "note", filePath: "note.txt")),
            lockOrigin: lockOrigin
        )
    }

    private func extensionPayload() -> ChatReaderPayload {
        .extensionNative(ExtensionNativeReaderContent(
            surface: ExtensionUINativeSurface(
                version: 1,
                id: "widget:jobs",
                source: "widget",
                presentation: ExtensionUINativePresentation(style: "surfacePanel", title: "Jobs", subtitle: nil),
                blocks: [],
                fallback: ExtensionUINativeFallback(text: "nothing running", lines: nil)
            ),
            identifierSuffix: "jobs",
            title: "Jobs",
            subtitle: "2 running"
        ))
    }

    private func makePNG() throws -> (UIImage, Data) {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return (image, try #require(image.pngData()))
    }

    // MARK: Pages

    @Test("each payload kind mounts its own page under a hidden stack bar")
    func eachPayloadKindMountsItsPage() throws {
        let png = try makePNG()
        let audio = AudioLyricsReaderContent(
            title: "Track",
            lyrics: nil,
            itemID: "item",
            audioPlayer: nil,
            play: { _ in },
            openFile: nil,
            autoplayOnAppear: false
        )
        let video = ChatReaderVideoContent(
            source: AuthenticatedMediaSource(
                url: URL(fileURLWithPath: "/nonexistent/clip.mp4"),
                authorizationHeaderValue: "Bearer test",
                tlsCertFingerprint: nil,
                contentTypeHint: "video/mp4",
                sourceFileExtension: "mp4"
            )
        )
        let cases: [(ChatReaderPayload, (UIViewController) -> Bool)] = [
            (documentPayload(), { $0 is FullScreenCodeViewController }),
            (.image(png.0), { ($0 as? UINavigationController)?.topViewController is FullScreenImageViewController }),
            (
                .imageData(png.1, mimeType: "image/png"),
                { ($0 as? UINavigationController)?.topViewController is FullScreenImageDataPreviewViewController }
            ),
            (.audioLyrics(audio), { $0 is AudioLyricsPlayerViewController }),
            (.video(video), { [self] page in descendant(identifier: "fullscreen-video.back", in: page.view) != nil }),
            (.nowPlaying(AudioPlayerService()), { $0 is InAppNowPlayingPlayerViewController }),
            (extensionPayload(), { $0 is ExtensionNativeSurfaceDetailViewController }),
        ]
        for (payload, isExpectedPage) in cases {
            let host = push(payload)
            defer { host.close() }
            let page = try #require(host.reader.page, "no page for \(payload.kind)")
            #expect(isExpectedPage(page), "wrong page for \(payload.kind)")
            #expect(host.navigation.isNavigationBarHidden, "the page draws its own Back")
        }
    }

    /// A stack root that says when its appearance finished: UIKit holds a push
    /// or pop issued before then, so a test must wait for it.
    private final class AppearanceRoot: UIViewController {
        private(set) var didAppear = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear = true
        }
    }

    @Test(
        "the router stack's delegate keeps the bar hidden over a page and brings it back on pop",
        arguments: [false, true]
    )
    func routerStackHidesTheBarOverAPageOnly(animated: Bool) async throws {
        forgetSharedScopedLockFlags()
        let store = ChatReaderPayloadStore()
        let appNavigation = AppNavigation()
        let root = AppearanceRoot()
        let navigation = RouterNavigationController(rootViewController: root)
        // Only a window in the app's scene gets real appearance transitions.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let appeared = await waitForMainActorCondition(timeout: .seconds(5)) { root.didAppear }
        try #require(appeared, "the stack's root never appeared")
        #expect(!navigation.isNavigationBarHidden)

        func settle() async {
            let settled = await waitForMainActorCondition(timeout: .seconds(5)) {
                navigation.view.layoutIfNeeded()
                return navigation.transitionCoordinator == nil
            }
            #expect(settled, "the transition never finished")
        }
        func openReader(_ payload: ChatReaderPayload?) async -> ChatReaderViewController {
            let target = payload.map { store.store($0) } ?? ChatReaderNavTarget(id: UUID())
            let reader = ChatReaderViewController(target: target, store: store, navigation: appNavigation)
            navigation.pushViewController(reader, animated: animated)
            await settle()
            return reader
        }
        func pop() async {
            navigation.popViewController(animated: animated)
            await settle()
        }

        let page = await openReader(documentPayload())
        #expect(page.page != nil)
        #expect(navigation.isNavigationBarHidden, "the stack's bar showed above the page's own Back")

        let nested = await openReader(documentPayload())
        #expect(nested.page != nil)
        #expect(navigation.isNavigationBarHidden)
        await pop()
        #expect(navigation.isNavigationBarHidden, "back to the first reader keeps its page's Back alone")
        await pop()
        #expect(!navigation.isNavigationBarHidden, "popping the reader must bring the stack's Back back")

        _ = await openReader(nil)
        #expect(!navigation.isNavigationBarHidden, "the unavailable message needs the stack's Back")

        // Routes the app sets without a user pop: a deep link that rebuilds the
        // stack around a reader, and a reset to the root.
        let rebuilt = ChatReaderViewController(
            target: store.store(documentPayload()), store: store, navigation: appNavigation
        )
        navigation.setViewControllers([root, rebuilt], animated: animated)
        await settle()
        #expect(navigation.isNavigationBarHidden, "a stack rebuilt around a reader hides the stack's bar")
        navigation.popToRootViewController(animated: animated)
        await settle()
        #expect(!navigation.isNavigationBarHidden, "a reset to the root brings the stack's Back back")
    }

    @Test("a missing payload shows the unavailable message with the stack's Back")
    func missingPayloadShowsUnavailableWithStackBar() async throws {
        let host = push(nil)
        defer { host.close() }

        #expect(host.reader.page == nil)
        #expect(!host.navigation.isNavigationBarHidden)
        #expect(host.reader.contentUnavailableConfiguration != nil)
    }

    @Test("Back from the page leaves the reader")
    func backFromPageLeavesTheReader() async throws {
        let host = push(extensionPayload())
        defer { host.close() }
        let back = try #require(
            descendant(identifier: "extension-native-surface-jobs-detail-back", in: host.reader.view) as? UIControl
        )

        back.sendActions(for: .primaryActionTriggered)

        let popped = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.navigation.viewControllers.count == 1
        }
        #expect(popped, "Back did not leave the reader")
    }

    // MARK: Locks

    @Test("a locked origin shows only the cover; unlocking builds the page")
    func lockedOriginShowsOnlyTheCover() async throws {
        let serverId = "sha256:reader-locked-\(UUID().uuidString)"
        let origin = ScopedLockTarget.server(serverId)
        let locks = ScopedLockService.shared
        let host = push(documentPayload(lockOrigin: origin))
        defer {
            host.close()
            locks.forgetServer(serverId)
        }
        #expect(host.reader.page != nil)

        locks.lock(.server(serverId: serverId))
        let covered = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.navigation.view.layoutIfNeeded()
            return host.reader.page == nil
                && host.reader.children.contains { $0 is ScopedLockCoverViewController }
        }
        #expect(covered, "a locked origin left the reader's content mounted or showed no cover")
        #expect(!host.navigation.isNavigationBarHidden, "the cover has no bar or Back")

        // A device authorization for the origin is what reveals the reader.
        locks.noteCreated(origin)
        let revealed = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.navigation.view.layoutIfNeeded()
            return host.reader.page != nil
                && !host.reader.children.contains { $0 is ScopedLockCoverViewController }
        }
        #expect(revealed, "unlocking the origin did not bring the page back")
        #expect(host.navigation.isNavigationBarHidden)
    }

    /// A reader stays on the stack under later screens. The origin it was stamped with names the workspace
    /// its chat had when it opened; Back must follow the session's workspace in the store now.
    @Test("a reader is covered when its origin chat's session has moved into a locked workspace")
    func readerFollowsTheOriginSessionsLiveWorkspace() async throws {
        let serverId = "sha256:reader-moved-\(UUID().uuidString)"
        let locks = ScopedLockService.shared
        let previousLookup = locks.sessionLookup
        var live = makeTestSession(id: "child", workspaceId: "w1", status: .stopped)
        locks.sessionLookup = { _, _ in live }
        let origin = locks.sessionTarget(serverId: serverId, sessionId: "child", workspaceId: "w1")
        let host = push(documentPayload(lockOrigin: origin))
        defer {
            host.close()
            locks.sessionLookup = previousLookup
            locks.forgetServer(serverId)
        }
        #expect(host.reader.page != nil)

        live = makeTestSession(id: "child", workspaceId: "w2", status: .stopped)
        locks.lock(.workspace(serverId: serverId, workspaceId: "w2"))
        let covered = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.navigation.view.layoutIfNeeded()
            return host.reader.page == nil
                && host.reader.children.contains { $0 is ScopedLockCoverViewController }
        }
        #expect(covered, "the reader kept showing the content of a session that moved into a locked workspace")
    }

    @Test("a reader with no origin is covered with Close while any lock exists")
    func readerWithoutOriginIsCoveredWithClose() async throws {
        let serverId = "sha256:reader-unknown-\(UUID().uuidString)"
        let locks = ScopedLockService.shared
        let host = push(documentPayload())
        defer {
            host.close()
            locks.forgetServer(serverId)
        }
        #expect(host.reader.page != nil)

        locks.lock(.server(serverId: serverId))
        let covered = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.navigation.view.layoutIfNeeded()
            return host.reader.page == nil
        }
        #expect(covered, "an origin-less reader stayed mounted while a lock exists")
        let close = try #require(descendant(identifier: "scopedLock.unlock", in: host.reader.view) as? UIControl)
        close.sendActions(for: .primaryActionTriggered)

        let left = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.navigation.viewControllers.count == 1
        }
        #expect(left, "Close did not leave the reader")
    }

    @Test("the shell's server lock cover follows the server's name")
    func serverLockCoverTitleFollowsTheServersName() async throws {
        func server(named name: String) throws -> PairedServer {
            try #require(PairedServer(from: ServerCredentials(
                host: "cover.local",
                port: 7749,
                token: "sk_test",
                name: name,
                scheme: .https,
                serverFingerprint: "sha256:cover-title",
                tlsCertFingerprint: "sha256:cover-title-leaf"
            )))
        }
        func label(_ text: String, in root: UIView) -> UILabel? {
            if let label = root as? UILabel, label.text == text { return label }
            return root.subviews.lazy.compactMap { label(text, in: $0) }.first
        }
        let serverStore = ServerStore()
        let first = try server(named: "alpha")
        serverStore.replaceServersForPreview([first])
        let root = makeTestAppRoot(coordinator: ConnectionCoordinator(serverStore: serverStore))
        let cover = ShellRouteScreens.serverLockCover(serverId: first.id, root: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = cover
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        cover.view.layoutIfNeeded()
        cover.updatePropertiesIfNeeded()
        #expect(label("alpha", in: cover.view) != nil)

        serverStore.replaceServersForPreview([try server(named: "beta")])
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            cover.updatePropertiesIfNeeded()
            return label("beta", in: cover.view) != nil
        }, "the cover kept the old server name")
    }
}
