import Testing
import UIKit
@testable import Oppi

/// The chat title's icon: the session's Agent (else the Pi mark) on a 40 pt
/// circle, inside a title whose tap opens the session's menu, and the moment it
/// plays when the chat opens, a turn ends, or the session needs the person. The
/// empty chat's hero is the Agent page's circle too, at the pane's size, with
/// the Agent's name and description under it.
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

    @Test func theTitleIconIsA40ptCircle() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.window.layoutIfNeeded()
            return titleIcon(of: host.chat)?.bounds.width == 40
        }, "the title's icon is a 40 pt circle")
        let icon = try #require(titleIcon(of: host.chat))
        #expect(icon.shape == .circle, "the title shows the Agent page's circle, not a tile")
    }

    /// One behavior for the whole title: the icon and the name alike open the
    /// session's menu, whose header names the whole session.
    @Test func theTitleOpensTheSessionMenu() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }
        let control = host.chat.barItems.titleControl
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.window.layoutIfNeeded()
            return control.bounds.width > 40
        }, "the title is laid out on the bar: \(control.bounds)")

        #expect(control.showsMenuAsPrimaryAction, "a tap on the title opens its menu")
        #expect(control.accessibilityIdentifier == "chat.title")
        #expect(control.accessibilityValue == "Review the icon work", "the value carries the whole title")

        let icon = try #require(titleIcon(of: host.chat))
        let circle = control.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), from: icon)
        #expect(control.hitTest(circle, with: nil) === control, "the circle opens the menu with the title")
        let besideTheName = CGPoint(x: control.bounds.maxX - 2, y: control.bounds.midY)
        #expect(control.hitTest(besideTheName, with: nil) === control, "so does a tap on the name")

        let items = try #require(sessionMenuItems(of: control))
        #expect(items.header == "Review the icon work", "the header names the whole session")
        #expect(
            items.actions == ["Copy Session ID", "Rename", "Share Session", "Edit Agent"],
            "the menu offers what the title can do: \(items.actions)"
        )
    }

    @Test func theMenuOpensTheAgentAndNamesPiForPiSessions() async throws {
        for agent in [true, false] {
            let host = try await makeHost(agent: agent)
            defer { hideTestWindow(host.window) }
            let control = host.chat.barItems.titleControl
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
                host.window.layoutIfNeeded()
                return control.menu != nil
            }, "the bar installs the title's menu")

            let items = try #require(sessionMenuItems(of: control))
            #expect(items.actions.last == (agent ? "Edit Agent" : "Pi Settings"))

            // The item's action, through the owner method it calls.
            host.chat.openSessionAgentPage()
            #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
                if agent {
                    host.stack.topViewController is AgentDetailViewController
                } else {
                    host.stack.topViewController is PiAgentDetailViewController
                }
            }, "the menu's last item opens \(agent ? "the Agent's" : "Pi's") page")
        }
    }

    /// How long a moment may take to end: its own duration plus room for the
    /// symbol effect and the main actor to settle.
    private static let momentTimeout: Duration = .seconds(10)

    @Test func aMomentPlaysInTheTitleAndRestsAfter() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            host.window.layoutIfNeeded()
            return titleIcon(of: host.chat) != nil
        }, "the title installs its icon")
        let icon = try #require(titleIcon(of: host.chat))
        // The chat's own opening plays a moment too, so the icon may be running
        // here. Await the end of whatever plays instead of assuming it starts at
        // rest: on a loaded machine the open is still playing when this asserted.
        #expect(
            await waitForMainActorCondition(timeout: Self.momentTimeout) { liveLayers(of: icon) == 1 },
            "the title's icon rests on its still drawing"
        )

        host.chat.playIconMoment()
        #expect(liveLayers(of: icon) == 2, "the moment runs the symbol's effect over the drawing")

        // Its real end, not a fixed wait: a second moment still running would
        // keep the effect up longer than one burst's duration.
        #expect(
            await waitForMainActorCondition(timeout: Self.momentTimeout) { liveLayers(of: icon) == 1 },
            "the moment ends on the still drawing"
        )
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

    /// The pane picks the circle: an iPhone's main pane, a wide pane, and a
    /// phone-width side pane, capped by a short pane.
    @Test func theEmptyChatCircleStepsWithItsPane() {
        #expect(ChatEmptyHeroMetrics.greetingSide(paneWidth: 402, paneHeight: 780) == 168)
        #expect(ChatEmptyHeroMetrics.greetingSide(paneWidth: 757, paneHeight: 700) == 180)
        #expect(ChatEmptyHeroMetrics.greetingSide(paneWidth: 375, paneHeight: 700) == 140)
        #expect(ChatEmptyHeroMetrics.greetingSide(paneWidth: 402, paneHeight: 420) == 126, "a short pane shrinks the circle")
    }

    @Test func theEmptyChatHeroIsTheAgentPagesCircle() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }
        let hero = ChatEmptyStateView(frame: CGRect(x: 0, y: 0, width: 402, height: 780))
        host.window.addSubview(hero)
        hero.apply(configuration: host.chat.makeTimelineConfiguration(), themeID: .dark)
        host.window.layoutIfNeeded()

        let icon = try #require(descendants(of: hero, IconChoiceUIView.self).first)
        #expect(icon.shape == .circle, "the empty chat shows the Agent page's circle")
        #expect(icon.bounds.width == 168 && icon.bounds.height == 168, "the hero is 168 pt: \(icon.bounds)")

        // A Pi session keeps the mark it has always shown, and no name.
        let piHost = try await makeHost(agent: false)
        defer { hideTestWindow(piHost.window) }
        let piHero = ChatEmptyStateView(frame: CGRect(x: 0, y: 0, width: 402, height: 780))
        piHost.window.addSubview(piHero)
        piHero.apply(configuration: piHost.chat.makeTimelineConfiguration(), themeID: .dark)
        piHost.window.layoutIfNeeded()
        let piIcon = try #require(descendants(of: piHero, IconChoiceUIView.self).first)
        #expect(piIcon.bounds.width == ChatEmptyHeroMetrics.piMarkSide, "Pi keeps today's 112 pt mark")
        #expect(heroLabel("chat.emptyState.name", in: piHero)?.isHidden != false, "Pi has no name under it")
    }

    /// An Agent's empty chat says who it will talk to, and the composer names it
    /// too; the chat with rows under it does neither.
    @Test func theEmptyChatNamesItsAgent() async throws {
        let host = try await makeHost(agent: true)
        defer { hideTestWindow(host.window) }
        host.chat.model.agentGreeting = ChatAgentGreeting(
            name: "Owl",
            description: "Reviews the icon work end to end."
        )

        let hero = ChatEmptyStateView(frame: CGRect(x: 0, y: 0, width: 402, height: 780))
        host.window.addSubview(hero)
        hero.apply(configuration: host.chat.makeTimelineConfiguration(), themeID: .dark)
        host.window.layoutIfNeeded()

        let name = try #require(heroLabel("chat.emptyState.name", in: hero))
        let description = try #require(heroLabel("chat.emptyState.description", in: hero))
        #expect(name.text == "Owl")
        #expect(description.text == "Reviews the icon work end to end.")
        #expect(!name.isHidden && !description.isHidden)
        #expect(host.chat.composerContent.placeholderOverride == "Message Owl")

        host.chat.clearAgentGreeting()
        hero.apply(configuration: host.chat.makeTimelineConfiguration(), themeID: .dark)
        #expect(name.isHidden && description.isHidden, "a chat with no greeting draws only the circle")
        #expect(host.chat.composerContent.placeholderOverride == nil, "the composer says Message… again")
    }
}

/// The title's menu split into what it is: a header naming the session, then the
/// actions under it.
@MainActor
private func sessionMenuItems(of control: ChatTitleControl) -> (header: String?, actions: [String])? {
    guard let menu = control.menu, let header = menu.children.first as? UIMenu else { return nil }
    return (header.title, header.children.compactMap { ($0 as? UIAction)?.title })
}

@MainActor
private func heroLabel(_ identifier: String, in root: UIView) -> UILabel? {
    descendants(of: root, UILabel.self).first { $0.accessibilityIdentifier == identifier }
}

private func descendants<T: UIView>(of root: UIView, _ type: T.Type) -> [T] {
    root.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, type) }
}
