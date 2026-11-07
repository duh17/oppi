import Testing
import UIKit
@testable import Oppi

/// A timeline-opened reader (a document, image, or an extension drawer's
/// full screen) and the title menu's Share redaction review are each one
/// more destination through the chat's trailing column, the same container
/// Files, Git, Outline, and Context already use: regular width mounts them
/// there instead of a pushed route or a second, full-screen presentation,
/// and narrow width keeps today's behavior untouched.
@MainActor
@Suite("Chat reader and share side-panel routing")
struct ChatReaderSidePanelRoutingTests {
    @Test("regular width mounts the reader in the trailing column, not a pushed route")
    func regularWidthUsesTheTrailingColumn() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.openTimelineReader(.document(content: .fromText("hello", filePath: "notes.md")))

        let mounted = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.trailingColumn.mountedScreenForTesting is ChatReaderViewController
        }
        #expect(mounted, "the reader never mounted in the trailing column")
        #expect(host.chat.model.sidePanelReaderTarget != nil)
        #expect(host.appNavigation.workspaceStackRouteElements.isEmpty, "no second, pushed presentation path")
    }

    @Test("compact width keeps today's pushed route, not the trailing column")
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
        #expect(host.chat.model.sidePanelReaderTarget == nil)
        #expect(host.chat.trailingColumn.mountedScreenForTesting == nil)
    }

    @Test("closing the side-panel reader drops its stored payload")
    func closingTheSidePanelReaderDropsItsPayload() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.openTimelineReader(.document(content: .fromText("hello", filePath: "notes.md")))
        _ = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.trailingColumn.mountedScreenForTesting is ChatReaderViewController
        }
        let target = try #require(host.chat.model.sidePanelReaderTarget)
        #expect(host.appRoot.chatReaderPayloadStore.payload(for: target.id) != nil)

        host.chat.closeSidePanelReader()
        #expect(host.chat.model.sidePanelReaderTarget == nil)
        #expect(host.appRoot.chatReaderPayloadStore.payload(for: target.id) == nil)

        let detached = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.trailingColumn.mountedScreenForTesting == nil
        }
        #expect(detached)
    }

    @Test("narrowing to compact hands an open column reader to the pushed route, payload intact")
    func narrowingHandsTheColumnReaderToThePushedRoute() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.openTimelineReader(.document(content: .fromText("hello", filePath: "notes.md")))
        _ = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.trailingColumn.mountedScreenForTesting is ChatReaderViewController
        }
        let target = try #require(host.chat.model.sidePanelReaderTarget)

        host.window.traitOverrides.horizontalSizeClass = .compact
        let pushed = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.appNavigation.containsChatReader(target)
                && host.chat.trailingColumn.mountedScreenForTesting == nil
        }
        #expect(pushed, "the reader neither left the column nor joined the shell's stack")
        #expect(host.chat.model.sidePanelReaderTarget == nil)
        #expect(host.appRoot.chatReaderPayloadStore.payload(for: target.id) != nil, "the pushed reader can still resolve it")
    }

    @Test("regular width mounts Share in the trailing column, not the old full-screen modal")
    func regularWidthMountsShareInTheTrailingColumn() async throws {
        let host = try await makeHost(horizontalSizeClass: .regular)
        defer { host.hide() }

        host.chat.showSidePanel(.share)

        let mounted = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.chat.trailingColumn.mountedScreenForTesting is ShareSessionRedactionViewController
        }
        #expect(mounted, "Share never mounted in the trailing column")
        #expect(host.chat.model.showShareRedactionSheet)

        // Opening another panel closes Share the same way its own Cancel
        // does (the preflight it started is cancelled), so the column never
        // ends up with two panels fighting over who owns it.
        host.chat.showSidePanel(.files)
        let swapped = await waitForMainActorCondition(timeout: .seconds(3)) {
            !(host.chat.trailingColumn.mountedScreenForTesting is ShareSessionRedactionViewController)
        }
        #expect(swapped)
        #expect(host.chat.model.showShareRedactionSheet == false)
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

    private func makeHost(horizontalSizeClass: UIUserInterfaceSizeClass) async throws -> Host {
        let sessionId = "reader-routing-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))

        let appNavigation = AppNavigation()
        let appRoot = makeTestAppRoot()
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "chat reader routing tests need the test host's window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        window.traitOverrides.appRootEnvironment = appRoot
        window.traitOverrides.horizontalSizeClass = horizontalSizeClass
        window.rootViewController = chat
        window.makeKeyAndVisible()
        chat.view.setNeedsLayout()
        chat.view.layoutIfNeeded()

        return Host(chat: chat, appNavigation: appNavigation, appRoot: appRoot, window: window)
    }
}
