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
        forgetSharedScopedLockFlags()
        let store = ChatReaderPayloadStore()
        let appNavigation = AppNavigation()
        let target = payload.map { store.store($0) } ?? ChatReaderNavTarget(id: UUID())
        appNavigation.openChatReader(target)
        let reader = ChatReaderViewController(target: target, store: store, navigation: appNavigation)
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(reader, animated: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.view.layoutIfNeeded()
        return Host(window: window, navigation: navigation, reader: reader, store: store, appNavigation: appNavigation)
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
