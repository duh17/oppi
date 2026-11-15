import Testing
import UIKit
@testable import Oppi

/// The chat's top bar at iPhone width in a real window: with every button
/// chosen, the bar keeps the first ones in the user's order, the title keeps
/// its room, and the buttons crowded out are offered in the … menu.
@Suite("Chat top bar overflow", .serialized)
@MainActor
struct ChatTopBarOverflowTests {
    @Test("At 375 pt every button on: the title keeps its room and the crowded-out buttons are in the … menu")
    func aNarrowBarMovesTheLastButtonsIntoTheMenu() async throws {
        // The bar reads the device's layout; this test owns it for its run.
        AppPreferences.ChatTopBar.setLayout(
            ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: Set(ChatTopBarAction.allCases))
        )
        defer { AppPreferences.ChatTopBar.preference.reset(in: .standard) }

        let sessionId = "top-bar-overflow-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.workspaceStore.workspaces = [makeTestWorkspace(id: "w1", hostMount: "/Users/alex/project")]
        connection.sessionStore.upsert(makeTestSession(
            id: sessionId, workspaceId: "w1", name: "Fix the release notes for the next build", status: .ready
        ))
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: SceneNavigation())
        let navigation = UINavigationController(rootViewController: chat)
        let window = makeSceneWindow()
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        let available = Set(ChatBarItems.availableActions(
            hasWorkspace: true, gitAvailable: chat.mayHaveGit,
            showsOutline: chat.outlineAvailability.isAvailable, hasTerminalFolder: chat.hasUsableTerminalFolder,
            offersTerminal: chat.connection.offers(.terminal)
        ))
        #expect(available.isSuperset(of: [.files, .git, .context, .terminal]), "the fixture offers four buttons or more: \(available)")

        let laidOut = await waitForMainActorCondition {
            chat.updatePropertiesIfNeeded()
            navigation.view.layoutIfNeeded()
            return chat.timelineWidth > 0 && trailingIdentifiers(chat).count > 1
        }
        #expect(laidOut, "the bar never drew its trailing group")

        let placement = chat.barItems.placement(of: chat)
        let drawn = trailingIdentifiers(chat)
        // The bar draws exactly the placement's buttons, in order, and … last.
        #expect(drawn == placement.bar.map(\.accessibilityIdentifier) + ["chat.toolbar.more"])
        #expect(placement.bar.count < available.count, "375 pt cannot hold every button beside Back and a title")
        // Order is priority: the drawn ones are the first in the user's order,
        // and the rest are in the menu, in that order.
        let chosen = ChatTopBarAction.allCases.filter(available.contains)
        #expect(placement.bar == Array(chosen.prefix(placement.bar.count)))
        #expect(placement.menu == Array(chosen.dropFirst(placement.bar.count)))

        // The title keeps a readable width and does not run under the buttons.
        let title = try #require(chat.screen.navigationItem.titleView)
        let trailing = try #require(chat.screen.navigationItem.rightBarButtonItems?.first?.customView)
        let titleFrame = title.convert(title.bounds, to: window)
        let trailingFrame = trailing.convert(trailing.bounds, to: window)
        #expect(titleFrame.width >= ChatBarItems.titleMinimumWidth - 1, "title squeezed to \(titleFrame.width) pt")
        #expect(titleFrame.maxX <= trailingFrame.minX + 0.5, "title \(titleFrame) runs under the buttons \(trailingFrame)")
    }

    private func trailingIdentifiers(_ chat: ChatViewController) -> [String] {
        guard let stack = chat.screen.navigationItem.rightBarButtonItems?.first?.customView as? UIStackView else { return [] }
        return stack.arrangedSubviews.filter { !$0.isHidden }.map { $0.accessibilityIdentifier ?? "?" }
    }
}
