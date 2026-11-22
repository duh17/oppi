import Foundation
import Testing
import UIKit
@testable import Oppi

/// Stage 4a: a chat beside a chat when the two sessions are on different
/// servers. Each server keeps its own connection, focused-session claim and
/// stream, so a chat of server B can show in a pane beside a chat of server A;
/// two chats of one server still cannot, because a second chat on one server
/// needs the session lane (Stage 4b). One session shows in one leaf (D7): an
/// open for a session a leaf already shows focuses that leaf rather than
/// pushing a second chat.
@Suite("A chat beside a chat across servers")
@MainActor
struct PaneCrossServerChatTests {
    private func host(width: CGFloat = 1133, height: CGFloat = 744) -> PaneTestHost {
        PaneTestHost(width: width, height: height, inNavigation: true)
    }

    /// A fresh server id per test: a scoped lock a test locked stays locked for
    /// the process, and ids are the lock's scope.
    private func server() -> String { "server-\(UUID().uuidString.prefix(8))" }

    private func chat(_ id: String, _ server: String, workspace: String) -> WorkspaceSessionNavTarget {
        WorkspaceSessionNavTarget(serverId: server, sessionId: id, workspaceId: workspace)
    }

    private func list(_ server: String, workspace: String) -> WorkspaceStackRouteElement {
        .entry(PaneStackEntry(serverId: server, route: .sessions(workspace: workspace)))
    }

    /// A side leaf holding a session list, as the launcher's Sessions choice
    /// opens one.
    private func sideList(_ host: PaneTestHost, _ server: String, workspace: String) throws -> PaneID {
        let panes = host.scenePanes
        let opened = try #require(panes.split(
            panes.mainLeafID, edge: .right, showing: list(server, workspace: workspace)
        ), "a pane beside the main leaf")
        return opened
    }

    /// The main pane shows server A's chat, and a session list of server B sits
    /// in a side pane. A row of that list opens server B's chat in that pane:
    /// each server has its own connection and stream, so nothing is shared.
    @Test func aRowOfASideListOpensItsChatInThatPane() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server(), b = server()
        let chatA = chat("a-1", a, workspace: "wa")
        let chatB = chat("b-1", b, workspace: "wb")

        navigation.open(.chat(chatA), from: .row(panes.mainLeafID))
        #expect(navigation.mainPaneRoute.top == .session(chatA))
        let side = try sideList(host, b, workspace: "wb")
        let beside = panes.stack(of: side)?.stack ?? []

        let placement = navigation.open(.chat(chatB), from: .row(side, workspace: WorkspaceNavTarget(
            serverId: b, workspace: makeTestWorkspace(id: "wb")
        )))

        #expect(placement == .push(side), "the chat opens in the pane its list is in")
        #expect(panes.stack(of: side)?.stack == beside + [.session(chatB)], "over the list, which stays under it")
        #expect(navigation.mainPaneRoute.top == .session(chatA), "the other server's chat stays where it is")
    }

    /// Two chats of one server cannot show at once: that server has one
    /// connection, one focused-session claim and one stream (Stage 4b brings
    /// the session lane). A row for a second chat of it opens in the main pane.
    @Test func aSecondChatOfTheSameServerOpensInTheMainPane() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server()
        let chatA = chat("a-1", a, workspace: "wa")
        let otherA = chat("a-2", a, workspace: "wa")

        navigation.open(.chat(chatA), from: .row(panes.mainLeafID))
        let side = try sideList(host, a, workspace: "wa")
        let beside = panes.stack(of: side)?.stack ?? []

        let placement = navigation.open(.chat(otherA), from: .row(side, workspace: WorkspaceNavTarget(
            serverId: a, workspace: makeTestWorkspace(id: "wa")
        )))

        #expect(placement != .push(side), "a second chat of one server never opens beside")
        #expect(panes.stack(of: side)?.stack == beside, "the side pane keeps its list")
        #expect(navigation.mainPaneRoute.top == .session(otherA), "it opened in the main pane")
        #expect(navigation.mainPaneRoute.stack.last == .session(otherA), "one chat of that server shows")
    }

    /// D7: a session shows in one leaf. A row, a link and an outside open for
    /// a chat a side pane shows focus that pane and leave the main pane's own
    /// chat alone.
    @Test func anOpenForAShownChatFocusesItsLeaf() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server(), b = server()
        let chatA = chat("a-1", a, workspace: "wa")
        let chatB = chat("b-1", b, workspace: "wb")

        navigation.open(.chat(chatA), from: .row(panes.mainLeafID))
        let side = try sideList(host, b, workspace: "wb")
        navigation.open(.chat(chatB), from: .row(side))
        #expect(panes.stack(of: side)?.top == .session(chatB))
        panes.focus(panes.mainLeafID)

        for origin: OpenOrigin in [.row(panes.mainLeafID), .link, .external] {
            let placement = navigation.open(.chat(chatB), from: origin)
            #expect(placement == .stay, "\(origin) did not open a second chat")
            #expect(panes.tree.focus == side, "\(origin) focuses the leaf that shows it")
            #expect(navigation.mainPaneRoute.top == .session(chatA), "\(origin) left the main pane's chat alone")
        }
        #expect(panes.tree.leaves.count == 2, "one leaf per session")
    }

    /// The leaf that shows the chat brings it back on top: a page opened over
    /// it was opened from that chat, so the open reveals the chat itself.
    @Test func aShownChatComesBackOverThePageThatCoveredIt() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server(), b = server()
        let chatB = chat("b-1", b, workspace: "wb")
        let file = WorkspaceLinkedFileNavTarget.workspaceFile(serverId: b, workspaceId: "wb", path: "notes/a.md")

        navigation.open(.chat(chat("a-1", a, workspace: "wa")), from: .row(panes.mainLeafID))
        let side = try sideList(host, b, workspace: "wb")
        navigation.open(.chat(chatB), from: .row(side))
        panes.setStack(PaneStack(stack: [list(b, workspace: "wb"), .session(chatB), .linkedFile(file)]), for: side)

        navigation.open(.chat(chatB), from: .link)

        #expect(panes.stack(of: side)?.stack == [list(b, workspace: "wb"), .session(chatB)])
        #expect(panes.tree.focus == side)
    }

    /// The session row's pane menu: Open in New Pane ▸ Right puts the chat
    /// beside the pane its list is in, at the root of the new pane.
    @Test func theRowsPaneMenuOpensASecondServersChatInANewPane() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server(), b = server()
        let chatA = chat("a-1", a, workspace: "wa")
        let chatB = chat("b-1", b, workspace: "wb")
        navigation.open(.chat(chatA), from: .row(panes.mainLeafID))
        #expect(navigation.mainPaneRoute.top == .session(chatA))

        host.panes.place(PaneOpenContent(session: chatB), at: .newPane(.right), from: panes.mainLeafID)

        let side = try #require(panes.splitLeaves.first?.id, "a pane beside the chat")
        #expect(panes.stack(of: side)?.stack == [.session(chatB)])
        #expect(host.panes.focusedCell == side, "the new pane has focus")
        #expect(navigation.mainPaneRoute.top == .session(chatA))
    }

    /// The same menu for a chat of the server already on screen: refused,
    /// because one server streams one chat. It opens in the main pane instead,
    /// and no pane is added.
    @Test func theRowsPaneMenuRefusesASecondChatOfOneServer() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server()
        navigation.open(.chat(chat("a-1", a, workspace: "wa")), from: .row(panes.mainLeafID))

        host.panes.place(PaneOpenContent(session: chat("a-2", a, workspace: "wa")), at: .newPane(.right), from: panes.mainLeafID)

        #expect(panes.splitLeaves.isEmpty, "one chat per server: no second pane")
        #expect(navigation.mainPaneRoute.top == .session(chat("a-2", a, workspace: "wa")), "it opened in the main pane")
        #expect(host.panes.focusedCell == panes.mainLeafID)
    }

    /// A chat's split still gives the launcher (its own chat cannot be copied),
    /// and that launcher's Sessions list opens its rows in the leaf: the rule
    /// holds for every chat but one of another server, which the leaf refuses
    /// as the main pane's chat has the server.
    @Test func aSplitChatStillGivesTheLauncherAndItsRowsOpenThere() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server(), b = server()
        let chatA = chat("a-1", a, workspace: "wa")
        navigation.open(.chat(chatA), from: .row(panes.mainLeafID))

        let side = try #require(panes.split(panes.mainLeafID, axis: .row))
        #expect(panes.stack(of: side)?.top?.isLauncher == true, "a split of a chat opens the launcher")
        panes.show(.entry(PaneStackEntry(serverId: b, route: .sessions(workspace: "wb"))), in: side)

        navigation.open(.chat(chat("b-1", b, workspace: "wb")), from: .row(side))
        #expect(panes.stack(of: side)?.top == .session(chat("b-1", b, workspace: "wb")), "another server's chat opens there")
        // A second chat of that server from the same list takes the leaf's top:
        // one chat of a leaf shows at a time. A chat in *another* leaf is the
        // refusal (`aSecondChatOfTheSameServerOpensInTheMainPane`).
        navigation.open(.chat(chat("b-2", b, workspace: "wb")), from: .row(side))
        #expect(panes.stack(of: side)?.top == .session(chat("b-2", b, workspace: "wb")), "over the first, in its own pane")
        #expect(navigation.mainPaneRoute.top == .session(chatA), "the main pane's chat stays")
    }

    /// One chat per server, whichever leaf the open names: a chat of a server
    /// that already shows one takes that leaf, in place of the chat there. The
    /// server has one connection, one claim and one stream, so both would run
    /// on one of it.
    @Test func aChatOfTheServersPaneTakesThatPaneWhereverTheOpenComesFrom() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server()
        let first = chat("a-1", a, workspace: "wa")
        let second = chat("a-2", a, workspace: "wa")

        navigation.open(.chat(chat("m-1", server(), workspace: "wm")), from: .row(panes.mainLeafID))
        let side = try #require(panes.split(panes.mainLeafID, edge: .right, showing: .session(first)))
        let mainTop = navigation.mainPaneRoute.top

        // A row of the main pane's list for the server whose chat is beside it.
        let placement = navigation.open(.chat(second), from: .row(panes.mainLeafID))

        #expect(placement == .reuse(side), "the open goes to the leaf that shows the server's chat")
        #expect(panes.stack(of: side)?.top == .session(second), "in place of it")
        #expect(panes.leaf(showingChatOf: "a-1", serverId: a) == nil, "the first chat left the window")
        #expect(panes.leaf(showingChatOf: "a-2", serverId: a) == side)
        #expect(navigation.mainPaneRoute.top == mainTop, "the main pane keeps what it showed")
        #expect(panes.tree.focus == side, "and the leaf that shows it has focus")

        // Every other origin follows the same rule, and the chat it leaves
        // behind leaves with it. A repeated open for the chat now shown is D7's
        // (it focuses that leaf).
        for (index, origin) in [OpenOrigin.link, .external].enumerated() {
            let next = chat("a-\(index + 3)", a, workspace: "wa")
            #expect(navigation.open(.chat(next), from: origin) == .reuse(side), "\(origin)")
            #expect(panes.stack(of: side)?.top == .session(next), "\(origin)")
            #expect(panes.leaf(showingChatOf: "a-\(index + 2)", serverId: a) == nil, "\(origin)")
        }
        #expect(navigation.open(.chat(chat("a-4", a, workspace: "wa")), from: .link) == .stay,
                "the chat already shown focuses its leaf")
    }

    /// A saved tree can already hold two chats of one server (an older build
    /// wrote it): a restore keeps the main leaf's and gives the other up.
    @Test func aRestoredTreeKeepsOneChatPerServer() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        _ = UIWindow(windowScene: scene)
        let suite = "PaneCrossServerChatTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = PaneTreeStore(defaults: defaults)
        let serverId = "server-restore-\(UUID().uuidString.prefix(6))"
        let workspaceId = "w-restore"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.workspaceStore.upsert(makeTestWorkspace(id: workspaceId), serverId: serverId)
        for id in ["a-1", "a-2"] {
            _ = connection.sessionStore.upsert(makeTestSession(id: id, workspaceId: workspaceId))
        }
        let main = ScenePanes().mainLeafID
        let side = try #require(PaneID("leaf-2"))
        store.save(PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .row, children: [
                .leaf(PaneLeaf(id: main, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspaceId)),
                    PaneStackEntry(serverId: serverId, route: .session("a-1")),
                ], attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: side, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .session("a-2")),
                ], attachedTo: nil, origin: .split)),
            ], weights: [0.6, 0.4]),
            focus: main, recency: [main, side]
        )), scene: "scene-two-chats")
        let navigation = root.navigation
        navigation.panes.connect(scene: "scene-two-chats", store: store)
        navigation.panes.restore(navigation: navigation, coordinator: root.coordinator)

        #expect(navigation.panes.leaf(showingChatOf: "a-1", serverId: serverId) == main)
        #expect(navigation.panes.leaf(showingChatOf: "a-2", serverId: serverId) == nil,
                "a restore keeps one chat per server")
        #expect(navigation.panes.tree.leaves.count == 1, "the leaf that showed only the other chat closed")
    }

    /// A route is every leaf's: leaving an incognito chat, or a deleted
    /// session's chat, is decided by what the whole window shows.
    @Test func routesAreEveryLeavesAndAWindowChatLeavesWithItsSession() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server(), b = server()
        let chatB = chat("b-1", b, workspace: "wb")
        navigation.open(.chat(chat("a-1", a, workspace: "wa")), from: .row(panes.mainLeafID))
        _ = try #require(panes.split(panes.mainLeafID, edge: .right, showing: .session(chatB)), "a pane of its own")
        #expect(navigation.routeContainsSession("b-1"), "a side leaf's chat is in the route")

        #expect(navigation.removeSessionRoute(serverId: b, sessionId: "b-1"), "the person was in that chat")
        #expect(!navigation.routeContainsSession("b-1"))
        #expect(panes.splitLeaves.isEmpty, "the pane showing only that chat closed with it")
        #expect(navigation.routeContainsSession("a-1"), "the other server's chat stays")
        #expect(navigation.mainPaneRoute.top == .session(chat("a-1", a, workspace: "wa")))
    }

    /// A chat under a page in its own leaf is still the window's chat for its
    /// session: deleting the session removes it and the page opened from it.
    @Test func aCoveredSideChatGoesWithThePageOpenedFromIt() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let b = server()
        let chatB = chat("b-1", b, workspace: "wb")
        let file = WorkspaceLinkedFileNavTarget.workspaceFile(serverId: b, workspaceId: "wb", path: "notes/a.md")
        let side = try sideList(host, b, workspace: "wb")
        navigation.open(.chat(chatB), from: .row(side))
        panes.setStack(PaneStack(stack: [list(b, workspace: "wb"), .session(chatB), .linkedFile(file)]), for: side)

        // The page was opened from that chat, so it goes with it; the list under
        // the chat stays, and the pane with it.
        #expect(navigation.removeSessionRoute(serverId: b, sessionId: "b-1"), "the screens above it were its own")
        #expect(panes.stack(of: side)?.stack == [list(b, workspace: "wb")], "the chat and the page above it went")
        #expect(panes.splitLeaves.map(\.id) == [side], "the list keeps its pane")
    }

    /// Stage 4a: when a new chat takes a side leaf showing a chat of the same
    /// server, the leaf keeps what sits under the old chat (its list) and drops
    /// the old chat and anything pushed over it, so Back still reaches the list.
    @Test func aNewChatInASidePaneKeepsItsListUnderneath() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server()
        let m = server()
        let chatM = chat("m-1", m, workspace: "wm")
        let chatA1 = chat("a-1", a, workspace: "wa")
        let chatA2 = chat("a-2", a, workspace: "wa")
        let chatA3 = chat("a-3", a, workspace: "wa")
        let sideListEntry = list(a, workspace: "wa")

        navigation.open(.chat(chatM), from: .row(panes.mainLeafID))
        let side = try sideList(host, a, workspace: "wa")
        navigation.open(.chat(chatA1), from: .row(side))
        #expect(panes.stack(of: side)?.stack == [sideListEntry, .session(chatA1)])

        // Open A2 from the main pane: takes the side pane in place of A1,
        // keeping the list underneath so Back returns to it.
        let placement = navigation.open(.chat(chatA2), from: .row(panes.mainLeafID))
        #expect(placement == .reuse(side))
        #expect(panes.stack(of: side)?.stack == [sideListEntry, .session(chatA2)],
                "side pane keeps its list under the new chat")
        #expect(panes.tree.focus == side)
        #expect(navigation.mainPaneRoute.top == .session(chatM))

        // A page pushed over A2 goes when A3 takes its place via the pane menu,
        // while the list below still stays.
        let file = WorkspaceLinkedFileNavTarget.workspaceFile(serverId: a, workspaceId: "wa", path: "notes/a.md")
        panes.setStack(PaneStack(stack: [sideListEntry, .session(chatA2), .linkedFile(file)]), for: side)
        host.panes.place(PaneOpenContent(session: chatA3), at: .newPane(.right), from: panes.mainLeafID)
        #expect(panes.stack(of: side)?.stack == [sideListEntry, .session(chatA3)],
                "pane menu replace keeps the list and drops pages above the old chat")

        // Back from A3 returns to the list.
        panes.pop(side, to: 1)
        #expect(panes.stack(of: side)?.stack == [sideListEntry], "Back reaches the list")
    }

    /// Main-pane equivalent: when a new chat takes the main leaf holding a chat
    /// of the same server, unrelated screens below the old chat stay intact
    /// (and pages above the old chat go), so Back still reaches them.
    @Test func aNewChatInTheMainPaneKeepsScreensBelowTheOldChat() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server()
        let chatA1 = chat("a-1", a, workspace: "wa")
        let chatA2 = chat("a-2", a, workspace: "wa")
        let chatA3 = chat("a-3", a, workspace: "wa")
        let folder = FileBrowserNavTarget(serverId: a, workspaceId: "wa", path: "Sources/")
        let file = WorkspaceLinkedFileNavTarget.workspaceFile(serverId: a, workspaceId: "wa", path: "Sources/App.swift")
        let workspace = WorkspaceNavTarget(serverId: a, workspace: makeTestWorkspace(id: "wa"))

        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.mainPaneRoute = PaneStack(place: .sessions(workspace), stack: [.fileBrowser(folder), .session(chatA1)])
        let side = try sideList(host, a, workspace: "wa")

        let placement = navigation.open(.chat(chatA2), from: .row(side))
        #expect(placement == .reuse(panes.mainLeafID))
        #expect(navigation.mainPaneRoute == PaneStack(
            place: .sessions(workspace),
            stack: [.fileBrowser(folder), .session(chatA2)]
        ), "main pane keeps its place and screens below the old chat")
        #expect(panes.tree.focus == panes.mainLeafID)

        // A page opened above A2 is dropped when A3 takes its place, while the
        // folder below A2 stays.
        navigation.mainPaneRoute = PaneStack(
            place: .sessions(workspace),
            stack: [.fileBrowser(folder), .session(chatA2), .linkedFile(file)]
        )
        _ = navigation.open(.chat(chatA3), from: .row(side))
        #expect(navigation.mainPaneRoute == PaneStack(
            place: .sessions(workspace),
            stack: [.fileBrowser(folder), .session(chatA3)]
        ), "pages above the old chat go; screens below it stay")

        // Back from A3 returns to the folder below it.
        navigation.popShownStack(toDepth: 1)
        #expect(navigation.mainPaneRoute == PaneStack(place: .sessions(workspace), stack: [.fileBrowser(folder)]),
                "Back reaches the screen below the chat")
    }

    /// `beforeMain` is for opens landing in the main pane; when a side pane
    /// takes the chat for its server, `beforeMain` does not run.
    @Test func beforeMainDoesNotRunWhenASidePaneTakesTheChat() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server(), m = server()

        navigation.open(.chat(chat("m-1", m, workspace: "wm")), from: .row(panes.mainLeafID))
        let side = try sideList(host, a, workspace: "wa")
        navigation.open(.chat(chat("a-1", a, workspace: "wa")), from: .row(side))

        var ranForSide = false
        let sidePlacement = navigation.open(.chat(chat("a-2", a, workspace: "wa")), from: .row(panes.mainLeafID)) {
            ranForSide = true
        }
        #expect(sidePlacement == .reuse(side))
        #expect(!ranForSide, "beforeMain must not run when a side pane takes the open")

        // Conversely, when the main pane takes a chat for its server, beforeMain runs.
        var ranForMain = false
        let mainPlacement = navigation.open(.chat(chat("m-2", m, workspace: "wm")), from: .row(side)) {
            ranForMain = true
        }
        #expect(mainPlacement == .reuse(panes.mainLeafID))
        #expect(ranForMain, "beforeMain runs when the main pane takes the open")
    }

    /// Repair keeps the main leaf's chat even when the main leaf moved past a
    /// side leaf in layout order, and drops pages pushed above a removed
    /// duplicate chat so no orphan reader/file remains.
    @Test func aRestoredTreeKeepsMainChatAfterMoveAndDropsPagesAboveDuplicate() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        _ = UIWindow(windowScene: scene)
        let suite = "PaneCrossServerChatTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = PaneTreeStore(defaults: defaults)
        let serverId = "server-repair-order-\(UUID().uuidString.prefix(6))"
        let workspaceId = "w-repair"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let connection = try #require(root.coordinator.connection(for: serverId))
        let workspace = makeTestWorkspace(id: workspaceId)
        connection.workspaceStore.upsert(workspace, serverId: serverId)
        for id in ["a-1", "a-2"] {
            _ = connection.sessionStore.upsert(makeTestSession(id: id, workspaceId: workspaceId))
        }
        let main = ScenePanes().mainLeafID
        let side = try #require(PaneID("leaf-2"))
        // Side leaf appears BEFORE main leaf (as after moving a pane left).
        store.save(PaneLayoutArchive(restorable: PaneLayout(
            root: .split(axis: .row, children: [
                .leaf(PaneLeaf(id: side, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspaceId)),
                    PaneStackEntry(serverId: serverId, route: .session("a-2")),
                    PaneStackEntry(serverId: serverId, route: .file(.workspace(id: workspaceId, worktree: nil), path: "README.md", line: nil)),
                ], attachedTo: nil, origin: .split)),
                .leaf(PaneLeaf(id: main, name: nil, stack: [
                    PaneStackEntry(serverId: serverId, route: .sessions(workspace: workspaceId)),
                    PaneStackEntry(serverId: serverId, route: .session("a-1")),
                ], attachedTo: nil, origin: .split)),
            ], weights: [0.4, 0.6]),
            focus: main, recency: [main, side]
        )), scene: "scene-moved-main")
        let navigation = root.navigation
        navigation.panes.connect(scene: "scene-moved-main", store: store)
        navigation.panes.restore(navigation: navigation, coordinator: root.coordinator)

        #expect(navigation.panes.leaf(showingChatOf: "a-1", serverId: serverId) == main,
                "main leaf keeps its chat even when it is not first in tree order")
        #expect(navigation.panes.leaf(showingChatOf: "a-2", serverId: serverId) == nil,
                "side leaf gives up the duplicate chat")
        #expect(navigation.panes.stack(of: side)?.stack == [.workspace(WorkspaceNavTarget(serverId: serverId, workspace: workspace))],
                "pages above the removed duplicate chat are dropped too, leaving only the list underneath")
    }

    /// Cold-launch placeholder resolution: when a restored `.entry` for a
    /// session resolves into a live `.session` chat, the one-chat-per-server
    /// rule applies — both when a side leaf resolves after another leaf is live
    /// and when the main leaf resolves after a side leaf already went live.
    @Test func aResolvedPlaceholderChatEnforcesOneChatPerServer() throws {
        let host = host()
        defer { host.hide() }
        let navigation = host.root.navigation
        let panes = host.scenePanes
        let a = server()
        let chatA1 = chat("a-1", a, workspace: "wa")
        let chatA2 = chat("a-2", a, workspace: "wa")
        let entryA1 = PaneStackEntry(serverId: a, route: .session("a-1"))
        let entryA2 = PaneStackEntry(serverId: a, route: .session("a-2"))
        let over = PaneStackEntry(serverId: a, route: .file(.workspace(id: "wa", worktree: nil), path: "README.md", line: nil))

        // Case 1: main already holds live A1; side placeholder A2 (with a page
        // above it) resolves -> side gives up A2 and the page above, keeping list.
        navigation.open(.chat(chatA1), from: .row(panes.mainLeafID))
        let sideWithList = try sideList(host, a, workspace: "wa")
        panes.setStack(PaneStack(stack: [list(a, workspace: "wa"), .entry(entryA2), .entry(over)]), for: sideWithList)
        panes.replace(entryA2, with: .session(chatA2), in: sideWithList)
        #expect(panes.stack(of: sideWithList)?.stack == [list(a, workspace: "wa")],
                "resolving a duplicate side placeholder drops it and pages above it")
        #expect(panes.leaf(showingChatOf: "a-1", serverId: a) == panes.mainLeafID)

        // Case 2: side placeholder A2 was the pane's only screen, wired through
        // `PaneHostController`'s `replaceRoot` callback -> pane closes.
        let sideAlone = try #require(panes.split(panes.mainLeafID, edge: .right, showing: .entry(entryA2)))
        host.act { host.panes.syncSplitLeaves() }
        let leafController = try #require(host.panes.splitLeaves[sideAlone]?.controller)
        let leafState = try #require(leafController.viewControllers.compactMap { $0 as? PaneLeafStateViewController }
            .first { $0.entry == entryA2 })
        host.act { leafState.onOpen?(.session(chatA2)) }
        #expect(panes.tree.leaf(sideAlone) == nil, "a side pane holding only the duplicate placeholder closes")
        #expect(host.panes.splitLeaves[sideAlone] == nil, "the closed split leaf controller leaves the host")

        // Case 3: cold-launch race where side resolved A2 first, then main's
        // placeholder A1 resolves -> main keeps A1 and side gives up A2.
        navigation.mainPaneRoute = PaneStack(place: .allSessions, stack: [.entry(entryA1)])
        panes.setStack(PaneStack(stack: [list(a, workspace: "wa"), .session(chatA2)]), for: sideWithList)
        navigation.resolvePaneEntry(entryA1, with: .session(chatA1))
        #expect(panes.leaf(showingChatOf: "a-1", serverId: a) == panes.mainLeafID, "main keeps its resolved chat")
        #expect(panes.leaf(showingChatOf: "a-2", serverId: a) == nil, "side gives up A2 when main resolves A1")
        #expect(panes.stack(of: sideWithList)?.stack == [list(a, workspace: "wa")], "side keeps its list")
    }
}
