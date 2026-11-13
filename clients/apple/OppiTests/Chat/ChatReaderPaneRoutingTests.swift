import Testing
import UIKit
@testable import Oppi

/// A timeline-opened reader (a document, image, or an extension drawer's
/// full screen) and the title menu's Share redaction review are each one
/// more destination through the chat's attached leaf, the same container
/// Files, Git, Outline, and Context already use: regular width mounts them
/// there instead of a pushed route or a second, full-screen presentation,
/// and narrow width keeps today's behavior untouched.
@MainActor
@Suite("Chat reader and share pane routing")
struct ChatReaderPaneRoutingTests {
    @Test("regular width mounts the reader in the attached leaf, not a pushed route")
    func regularWidthUsesTheAttachedLeaf() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.openTimelineReader(.document(content: .fromText("hello", filePath: "notes.md")))

        let mounted = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen is ChatReaderViewController
        }
        #expect(mounted, "the reader never mounted in the attached leaf")
        #expect(host.chat.model.readerTarget != nil)
        #expect(host.appNavigation.workspaceStackRouteElements.isEmpty, "no second, pushed presentation path")
    }

    @Test("compact width keeps today's pushed route, not the attached leaf")
    func compactWidthKeepsThePushedRoute() async throws {
        let host = try await makeHost(horizontalSizeClass: .compact)
        defer { host.hide() }

        host.chat.openTimelineReader(.document(content: .fromText("hello", filePath: "notes.md")))

        let pushed = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.appNavigation.workspaceStackRouteElements.count == 1
        }
        #expect(pushed)
        if case .chatReader = host.appNavigation.workspaceStackRouteElements.first {
            // expected
        } else {
            Issue.record("Expected a pushed .chatReader route element")
        }
        #expect(host.chat.model.readerTarget == nil)
        #expect(host.chat.attachedLeaf.mountedScreen == nil)
    }

    @Test("closing the reader beside the chat drops its stored payload")
    func closingTheReaderBesideTheChatDropsItsPayload() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.openTimelineReader(.document(content: .fromText("hello", filePath: "notes.md")))
        _ = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen is ChatReaderViewController
        }
        let target = try #require(host.chat.model.readerTarget)
        #expect(host.appRoot.chatReaderPayloadStore.payload(for: target.id) != nil)

        host.chat.closePanel(.reader(target))
        #expect(host.chat.model.readerTarget == nil)
        #expect(host.appRoot.chatReaderPayloadStore.payload(for: target.id) == nil)

        let detached = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen == nil
        }
        #expect(detached)
    }

    @Test("narrowing to compact hands an open reader beside the chat to the pushed route, payload intact")
    func narrowingHandsTheColumnReaderToThePushedRoute() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.openTimelineReader(.document(content: .fromText("hello", filePath: "notes.md")))
        _ = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen is ChatReaderViewController
        }
        let target = try #require(host.chat.model.readerTarget)

        host.window.traitOverrides.horizontalSizeClass = .compact
        let pushed = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.appNavigation.containsChatReader(target)
                && host.chat.attachedLeaf.mountedScreen == nil
        }
        #expect(pushed, "the reader neither left the attached leaf nor joined the shell's stack")
        #expect(host.chat.model.readerTarget == nil)
        #expect(host.appRoot.chatReaderPayloadStore.payload(for: target.id) != nil, "the pushed reader can still resolve it")
    }

    @Test("regular width mounts Share in the attached leaf, not the old full-screen modal")
    func regularWidthMountsShareInTheAttachedLeaf() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.showPanel(.share)

        let mounted = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen is ShareSessionRedactionViewController
        }
        #expect(mounted, "Share never mounted in the attached leaf")
        #expect(host.chat.model.panel == .share)

        // Opening another panel closes Share the same way its own Cancel
        // does (the preflight it started is cancelled), so the column never
        // ends up with two panels fighting over who owns it.
        host.chat.showPanel(.files)
        let swapped = await waitForMainActorCondition(timeout: .seconds(3)) {
            !(host.chat.attachedLeaf.mountedScreen is ShareSessionRedactionViewController)
        }
        #expect(swapped)
        #expect(host.chat.model.panel == .files)
    }

    // MARK: - Extension panels

    /// The `panel-hints.json` surface with its header subtitle and revision replaced.
    private func jobsSurface(subtitle: String, revision: Int) throws -> ExtensionUISurface {
        let data = try ProtocolFixtures.data("surfaces/panel-hints.json")
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var header = try #require(json["header"] as? [String: Any])
        header["subtitle"] = subtitle
        json["header"] = header
        json["revision"] = revision
        return try JSONDecoder().decode(ExtensionUISurface.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func mountedPanel(_ host: Host) -> ExtensionPanelViewController? {
        host.chat.attachedLeaf.mountedScreen as? ExtensionPanelViewController
    }

    @Test("a surface opens in its panel pane beside the chat, linked, and follows the session's snapshots")
    func aSurfaceOpensInItsPanelPane() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }
        let surfaces = host.chat.connection.extensionSurfaces
        surfaces.apply(try jobsSurface(subtitle: "1 running", revision: 7), sessionId: host.chat.sessionId)

        let openPanel = try #require(host.chat.extensionDrawerActions().openPanel)
        openPanel("jobs")
        let mounted = await waitForMainActorCondition(timeout: .seconds(3)) { mountedPanel(host) != nil }
        #expect(mounted, "the panel never mounted in the attached leaf")
        let panel = try #require(mountedPanel(host))
        panel.updatePropertiesIfNeeded()
        #expect(panel.shownState == .content)
        #expect(panel.navigationItem.title == "Jobs")
        #expect(panel.navigationItem.subtitle == "1 running")
        #expect(host.chat.shownPanelSurfaceId == "jobs")
        let tree = try #require(PaneHostController.hosting(host.chat)?.panes.tree)
        #expect(tree.leaves.first { $0.origin == .attached }?.stack.last == PaneStackEntry(
            serverId: "sha256:reader-routing", route: .panel(session: host.chat.sessionId, id: "jobs")
        ), "the pane has a link, so the window restores it")

        // P3: parked behind a full-screen cover, the pane misses an update and
        // draws the newest snapshot when it returns.
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        host.chat.present(cover, animated: false)
        let parked = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.attachedLeaf.mountedScreen == nil
        }
        #expect(parked, "the pane stayed mounted under the cover")
        surfaces.apply(try jobsSurface(subtitle: "2 finished", revision: 8), sessionId: host.chat.sessionId)
        host.chat.dismiss(animated: false)
        let returned = await waitForMainActorCondition(timeout: .seconds(3)) {
            mountedPanel(host)?.updatePropertiesIfNeeded()
            return mountedPanel(host)?.navigationItem.subtitle == "2 finished"
        }
        #expect(returned, "the returning pane did not draw the newest snapshot")
    }

    @Test("SD2: a panel whose session goes away keeps its last snapshot, ended, with Close Pane")
    func aPanelWhoseSessionEndsShowsEnded() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }
        let surfaces = host.chat.connection.extensionSurfaces
        surfaces.apply(try jobsSurface(subtitle: "1 running", revision: 7), sessionId: host.chat.sessionId)
        host.chat.openExtensionPanel("jobs")
        _ = await waitForMainActorCondition(timeout: .seconds(3)) { mountedPanel(host) != nil }
        let panel = try #require(mountedPanel(host))
        panel.updatePropertiesIfNeeded()
        #expect(panel.shownState == .content)

        // The session is deleted: the server clears its surfaces, and the store drops it.
        surfaces.clear(sessionId: host.chat.sessionId)
        host.chat.connection.sessionStore.remove(id: host.chat.sessionId)
        panel.updatePropertiesIfNeeded()
        #expect(panel.shownState == .ended)
        #expect(panel.navigationItem.title == "Jobs", "the last snapshot stays")
        let ended = try #require(panel.view.firstSubview(identifiedAs: "extensionPanel.ended"))
        #expect(!ended.isHidden)
        #expect(panel.children.first?.view.alpha ?? 1 < 1, "the snapshot is dimmed")
    }

    @Test("a panel its idle session has not published says so; a busy one waits")
    func anUnpublishedPanelWaitsOrIsUnavailable() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }
        host.chat.openExtensionPanel("jobs")
        _ = await waitForMainActorCondition(timeout: .seconds(3)) { mountedPanel(host) != nil }
        let panel = try #require(mountedPanel(host))
        panel.updatePropertiesIfNeeded()
        #expect(panel.shownState == .unavailable)

        host.chat.connection.sessionStore.upsert(makeTestSession(id: host.chat.sessionId, status: .busy))
        panel.updatePropertiesIfNeeded()
        #expect(panel.shownState == .waiting)

        host.chat.connection.extensionSurfaces.apply(
            try jobsSurface(subtitle: "1 running", revision: 7), sessionId: host.chat.sessionId
        )
        panel.updatePropertiesIfNeeded()
        #expect(panel.shownState == .content)
    }

    // MARK: - Fixture

    private struct Host {
        let chat: ChatViewController
        let appNavigation: AppNavigation
        let appRoot: AppRootEnvironment
        let window: UIWindow

        func hide() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func commitRequest(_ host: Host, sha: String) -> ChatTimelineDestinationRequest {
        ChatTimelineDestinationRequest(
            destination: .commitDetail(sha: sha),
            serverId: nil,
            workspaceId: "ws-test",
            sessionId: host.chat.sessionId,
            reviewCommentSelectionScope: nil,
            sourceView: host.chat.view,
            presenter: host.chat
        )
    }

    private func openedSha(_ host: Host) -> String? {
        (host.chat.attachedLeaf.mountedScreen as? CommitDetailViewController)?.configuration.sha
    }

    @Test("a timeline commit opens in the column at regular width, and a second open replaces it")
    func timelineCommitOpensInTheColumnAndIsReplaced() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.showPanel(.timeline(commitRequest(host, sha: "aaa1111").panelTarget))
        let first = await waitForMainActorCondition(timeout: .seconds(3)) { openedSha(host) == "aaa1111" }
        #expect(first, "the commit never mounted in the attached leaf")
        #expect(host.chat.presentedViewController == nil, "no modal over the chat")

        host.chat.showPanel(.timeline(commitRequest(host, sha: "bbb2222").panelTarget))
        let replaced = await waitForMainActorCondition(timeout: .seconds(3)) { openedSha(host) == "bbb2222" }
        #expect(replaced, "a second link must replace the open pane, not stack on it or be ignored")
    }

    @Test("narrowing to compact moves an open timeline pane to the sheet it opens as there")
    func narrowingMovesTheTimelinePaneToTheSheet() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.showPanel(.timeline(commitRequest(host, sha: "aaa1111").panelTarget))
        _ = await waitForMainActorCondition(timeout: .seconds(3)) { openedSha(host) == "aaa1111" }

        host.window.traitOverrides.horizontalSizeClass = .compact
        let sheet = await waitForMainActorCondition(timeout: .seconds(3)) {
            let presented = host.chat.presentedViewController as? RouterNavigationController
            return presented?.viewControllers.first is CommitDetailViewController
                && host.chat.attachedLeaf.mountedScreen == nil
        }
        #expect(sheet, "the open commit pane was dropped instead of presented as the sheet")
        #expect(host.chat.model.panel == nil)
    }

    private func makeHost(horizontalSizeClass: UIUserInterfaceSizeClass) async throws -> Host {
        let sessionId = "reader-routing-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let appNavigation = AppNavigation()
        let appRoot = makeTestAppRoot()
        let chat = ChatViewController(
            sessionId: sessionId, connection: connection, navigation: appNavigation, serverIdHint: "sha256:reader-routing"
        )

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "chat reader routing tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        window.traitOverrides.appRootEnvironment = appRoot
        window.traitOverrides.horizontalSizeClass = horizontalSizeClass
        window.rootViewController = PaneHostController(primary: chat)
        window.makeKeyAndVisible()
        chat.view.setNeedsLayout()
        chat.view.layoutIfNeeded()

        return Host(chat: chat, appNavigation: appNavigation, appRoot: appRoot, window: window)
    }
}

private extension UIView {
    func firstSubview(identifiedAs identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let found = subview.firstSubview(identifiedAs: identifier) { return found }
        }
        return nil
    }
}

private extension ChatScreenModel {
    /// The reader the chat's panel shows, if it shows one.
    var readerTarget: ChatReaderNavTarget? {
        if case .reader(let target)? = panel { return target }
        return nil
    }
}
