import Testing
import UIKit
@testable import Oppi

/// The chat title's icon: the session's Agent (else the Pi mark) on a 32 pt
/// circle that opens the Agent's page, beside a title that still renames, and
/// the moment it plays when the chat opens, a turn ends, or the session needs
/// the person. The empty chat's hero is the Agent page's circle too.
@Suite("Chat title icon")
@MainActor
struct ChatTitleIconTests {
    private struct Host {
        let chat: ChatViewController
        let stack: UINavigationController
        let window: UIWindow
    }

    private func makeHost(agent: Bool) async throws -> Host {
        let sessionId = "title-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        var session = makeTestSession(id: sessionId, workspaceId: "w1", name: "Review the icon work")
        if agent {
            session.launch = SessionLaunchMetadata(
                agentId: "agent-reviewer",
                agentIcon: .symbol("sparkles", effect: .bounce)
            )
        }
        connection.sessionStore.upsert(session)
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: SceneNavigation())
        let stack = UINavigationController(rootViewController: chat)
        let window = makeSceneWindow()
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = stack
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return Host(chat: chat, stack: stack, window: window)
    }

    /// The circle in the title, once the chat has installed its leaves.
    private func titleIcon(of chat: ChatViewController) -> IconChoiceUIView? {
        descendants(of: chat.barItems.titleControl, IconChoiceUIView.self).first
    }

    /// The image views an icon shows: its still drawing, then the one a symbol's
    /// effect or an animated image plays in.
    private func liveLayers(of icon: IconChoiceUIView) -> Int {
        icon.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden }.count
    }

    @Test func theTitleIconIsA32ptCircle() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.window.layoutIfNeeded()
            return titleIcon(of: host.chat)?.bounds.width == 32
        }, "the title's icon is a 32 pt circle")
        let icon = try #require(titleIcon(of: host.chat))
        #expect(icon.shape == .circle, "the title shows the Agent page's circle, not a tile")
    }

    @Test func theCircleOpensTheAgentAndTheTitleStillRenames() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }
        let control = host.chat.barItems.titleControl
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.window.layoutIfNeeded()
            return control.bounds.width > 40
        }, "the title is laid out on the bar: \(control.bounds)")

        let icon = try #require(titleIcon(of: host.chat))
        let circle = control.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), from: icon)
        let hit = try #require(control.hitTest(circle, with: nil))
        #expect(hit !== control, "the circle takes its own taps, not the title's")
        (hit as? UIControl)?.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.stack.topViewController is AgentDetailViewController
        }, "the circle opens the Agent's page")

        let besideTheName = CGPoint(x: control.bounds.maxX - 2, y: control.bounds.midY)
        #expect(control.hitTest(besideTheName, with: nil) === control, "a tap on the title is still the title's")
    }

    @Test func thePiMarkOpensPisPage() async throws {
        let host = try await makeHost(agent: false)
        defer { hideTestWindow(host.window) }
        let control = host.chat.barItems.titleControl
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.window.layoutIfNeeded()
            return control.bounds.width > 40
        })

        let icon = try #require(titleIcon(of: host.chat))
        let circle = control.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), from: icon)
        (try #require(control.hitTest(circle, with: nil)) as? UIControl)?.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.stack.topViewController is PiAgentDetailViewController
        }, "a session launched without an Agent opens Pi's page")
    }

    @Test func aMomentPlaysInTheTitleAndRestsAfter() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.window.layoutIfNeeded()
            return titleIcon(of: host.chat) != nil
        }, "the title installs its icon")
        let icon = try #require(titleIcon(of: host.chat))
        #expect(liveLayers(of: icon) == 1, "the title's icon rests on its still drawing")

        host.chat.playIconMoment()
        #expect(liveLayers(of: icon) == 2, "the moment runs the symbol's effect over the drawing")

        try await Task.sleep(for: IconChoiceUIView.burstDuration + .milliseconds(300))
        #expect(liveLayers(of: icon) == 1, "the moment ends on the still drawing")
    }

    /// The chat opening is the first moment: the title plays it on its own, from
    /// the appearance, not from a later pass over the bar.
    @Test func theChatOpeningPlaysTheTitleMoment() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            guard let icon = titleIcon(of: host.chat) else { return false }
            return liveLayers(of: icon) > 1
        }, "the chat's open plays the title's icon")
    }

    @Test func theEmptyChatHeroIsTheAgentPagesCircle() throws {
        let window = makeSceneWindow()
        defer { hideTestWindow(window) }
        let hero = ChatEmptyStateView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        window.addSubview(hero)
        window.layoutIfNeeded()

        let icon = try #require(descendants(of: hero, IconChoiceUIView.self).first)
        #expect(icon.shape == .circle, "the empty chat shows the Agent page's circle")
        #expect(icon.bounds.width == 112 && icon.bounds.height == 112, "the hero is 112 pt: \(icon.bounds)")
    }
}

private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
    root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
}
