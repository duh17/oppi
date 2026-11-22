import Foundation
import Testing
import UIKit
@testable import Oppi

/// The window's split leaves as `ScenePanes` keeps them: what a split shows,
/// the companion staying beside its chat through splits and closes, and what
/// a relaunch brings back.
@MainActor
@Suite("Pane splits", .serialized)
struct PaneSplitTests: PaneFixtureBuilding {
    private let serverId = "sha256:pane-splits"
    private let workspace = makeTestWorkspace(id: "ws-1", name: "Oppi")

    private func makeRoot() async throws -> AppRootEnvironment {
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.workspaceStore.upsert(workspace, serverId: serverId)
        _ = connection.sessionStore.upsert(makeTestSession(id: "s-1", workspaceId: "ws-1"))
        return root
    }

    /// A window showing the chat `s-1` in its workspace, wired as launch wires it.
    private func chatWindow(store: PaneTreeStore? = nil, scene: String? = nil) async throws -> AppRootEnvironment {
        let root = try await makeRoot()
        let panes = root.navigation.panes
        if let store, let scene { panes.connect(scene: scene, store: store) }
        panes.restore(navigation: root.navigation, coordinator: root.coordinator, applying: store != nil)
        if root.navigation.workspaceStackRouteElements.isEmpty {
            root.navigation.mainPaneRoute = PaneStack(
                place: .sessions(WorkspaceNavTarget(serverId: serverId, workspace: workspace)),
                stack: [.session(WorkspaceSessionNavTarget(serverId: serverId, sessionId: "s-1", workspaceId: "ws-1"))]
            )
        }
        return root
    }

    private func makeStore() throws -> PaneTreeStore {
        let suite = "PaneSplitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return PaneTreeStore(defaults: defaults)
    }

    private func entry(_ route: PaneRoute) -> PaneStackEntry {
        PaneStackEntry(serverId: serverId, route: route)
    }

    @Test func splittingAChatOpensTheLauncherAndSplittingFilesCopiesIt() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        let launcher = try #require(panes.split(panes.mainLeafID, axis: .row))
        #expect(panes.topEntry(of: launcher) == entry(.local(PaneLocalScreen.launcher(workspaceId: "ws-1").token)),
                "a chat's split offers its own workspace's Sessions, Files and Terminal")
        #expect(panes.tree.focus == panes.mainLeafID, "the chat keeps focus")

        let files = entry(.files(workspace: "ws-1", path: nil))
        panes.show(files, in: launcher)
        let copy = try #require(panes.split(launcher, axis: .column))
        #expect(panes.topEntry(of: copy) == files)
        #expect(shape(panes.tree.root) == "row[leaf-1 0.5, column[\(launcher.raw) 0.5, \(copy.raw) 0.5] 0.5]")

        panes.show(panes.launcher(for: copy), in: copy)
        #expect(panes.topEntry(of: copy) == entry(.local(PaneLocalScreen.launcher(workspaceId: "ws-1").token)),
                "Show in Pane goes back to the launcher for the pane's workspace")
    }

    /// Undo takes back the pane it closed, not the navigation that happened
    /// since: the main pane keeps the screen the person opened after the close.
    @Test func undoRestoresTheClosedPanesRouteAlone() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        let folder = PaneStackEntry(serverId: serverId, route: .files(workspace: "ws-1", path: "Sources"))
        let side = try #require(panes.split(panes.mainLeafID, edge: .right, showing: .entry(folder)))
        #expect(panes.stack(of: side)?.top == .entry(folder))

        panes.close(side)
        root.navigation.open(.place(.utility(.agents)))
        let agentPlace = root.navigation.mainPaneRoute.place

        #expect(panes.undo())
        #expect(panes.stack(of: side)?.top == .entry(folder), "the closed pane is back with what it showed")
        #expect(root.navigation.mainPaneRoute.place == agentPlace, "the main pane keeps where the person went")
    }

    /// Open in Pane on an already-focused side pane still records an Undo step,
    /// even though the tree's layout and focus did not change.
    @Test func undoTakesBackOpenInPaneOnTheFocusedPane() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        let first = WorkspaceStackRouteElement.entry(entry(.files(workspace: "ws-1", path: "Sources")))
        let second = WorkspaceStackRouteElement.entry(entry(.git(workspace: "ws-1", worktree: nil)))
        let side = try #require(panes.split(panes.mainLeafID, edge: .right, showing: first))
        panes.focus(side)
        #expect(panes.cellLayout.focus == side)

        panes.replace(second, inCell: side)
        #expect(panes.stack(of: side)?.top == second)
        #expect(panes.undoAction == ScenePanes.openInPaneAction, "replacing the focused pane offers Undo")
        #expect(panes.undo())
        #expect(panes.stack(of: side)?.top == first, "Undo puts the previous route back")
    }

    @Test func theCompanionStaysBesideItsChatThroughSplitsAndCloses() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        panes.companionDidOpen(entry(.git(workspace: "ws-1", worktree: nil)), pairing: Self.gitPairing)
        panes.setCompanionShare(0.4)
        let companion = try #require(panes.companionID)

        let split = try #require(panes.split(panes.mainLeafID, axis: .row))
        #expect(shape(panes.tree.root) == "row[leaf-1 0.3, \(companion.raw) 0.2, \(split.raw) 0.5]",
                "the chat and Git share the chat's half, Git keeping its 40%")
        #expect(shape(panes.cellLayout.root) == "row[leaf-1 0.5, \(split.raw) 0.5]",
                "the host lays the chat and Git out as one cell")

        panes.move(split, to: panes.mainLeafID, edge: .left)
        #expect(shape(panes.tree.root) == "row[\(split.raw) 0.5, leaf-1 0.3, \(companion.raw) 0.2]")

        panes.close(split)
        #expect(shape(panes.tree.root) == "row[leaf-1 0.6, \(companion.raw) 0.4]")
        #expect(panes.companionID == companion)
    }

    @Test func theChatLeafNeverClosesAndResetKeepsItsPanel() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        panes.companionDidOpen(entry(.git(workspace: "ws-1", worktree: nil)), pairing: Self.gitPairing)
        let first = try #require(panes.split(panes.mainLeafID, axis: .row))
        _ = try #require(panes.split(first, axis: .column))
        panes.close(panes.mainLeafID)
        #expect(panes.tree.leaves.count == 4, "Close Pane on the chat's leaf does nothing")

        panes.resetPanes()
        #expect(panes.splitLeaves.isEmpty)
        #expect(panes.companionID != nil, "the chat's panel stays")
    }

    /// Split Right or Down on a terminal a launcher opened opens the
    /// workspace's own terminal, not a launcher.
    @Test func splittingALaunchersTerminalPaneOpensTheWorkspacesTerminal() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        let workspaceTerminal = entry(.local(PaneLocalScreen.terminal(workspaceId: "ws-1").token))
        let terminal = try #require(panes.split(panes.mainLeafID, axis: .row))
        panes.show(workspaceTerminal, in: terminal)
        let beside = try #require(panes.split(terminal, axis: .column))
        #expect(panes.topEntry(of: beside) == workspaceTerminal)
    }

    /// The chat bar's Terminal beside a chat names its workspace, so a split
    /// of it opens that workspace's terminal and not an empty launcher.
    @Test func splittingAChatsTerminalPaneOpensTheWorkspacesTerminal() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        let target = SSHTerminalFolderTarget(serverHost: "studio.local", folder: "/srv/oppi", label: "Oppi")
        let terminal = try #require(SSHTerminalFolderEntry.terminal(for: target, workspace: (serverId, "ws-1")))
        let content = PaneOpenContent(terminal: terminal, serverId: serverId)
        let beside = try #require(panes.split(panes.mainLeafID, edge: .right, showing: content.route))
        #expect(panes.stack(of: beside)?.top == .terminal(terminal), "the chat's own terminal opens beside it")

        let split = try #require(panes.split(beside, axis: .column))
        #expect(panes.topEntry(of: split) == entry(.local(PaneLocalScreen.terminal(workspaceId: "ws-1").token)))
    }

    /// A terminal beside a chat of another server keeps that chat's server: a
    /// split of it opens `ws-2`'s terminal on the server holding `ws-2`, not a
    /// workspace of the same id (or a host list) on the window's own server.
    @Test func aTerminalBesideTheOtherServersChatSplitsOnTheChatsServer() async throws {
        let other = "sha256:pane-splits-other"
        let root = try await makeTestTwoServerRoot(firstId: serverId, otherId: other)
        defer { withExtendedLifetime(root) {} }
        let otherConnection = try #require(root.coordinator.connection(for: other))
        otherConnection.workspaceStore.upsert(makeTestWorkspace(id: "ws-2", name: "Other"), serverId: other)
        let panes = root.navigation.panes
        panes.restore(navigation: root.navigation, coordinator: root.coordinator, applying: false)
        root.navigation.mainPaneRoute = PaneStack(
            place: .sessions(WorkspaceNavTarget(serverId: serverId, workspace: workspace)),
            stack: [.session(WorkspaceSessionNavTarget(serverId: serverId, sessionId: "s-1", workspaceId: "ws-1"))]
        )
        let otherChat = WorkspaceSessionNavTarget(serverId: other, sessionId: "s-2", workspaceId: "ws-2")
        let chat = try #require(panes.split(panes.mainLeafID, edge: .right, showing: .session(otherChat)))
        let target = SSHTerminalFolderTarget(serverHost: "other-server.test", folder: "/srv/other", label: "Other")
        let terminal = try #require(SSHTerminalFolderEntry.terminal(for: target, workspace: (other, "ws-2")))
        let terminalPane = try #require(panes.split(chat, edge: .right, showing: .terminal(terminal)))
        #expect(panes.stack(of: terminalPane)?.top == .terminal(terminal), "the chat's own terminal opens beside it")

        let split = try #require(panes.split(terminalPane, axis: .column))
        #expect(panes.topEntry(of: split) == PaneStackEntry(
            serverId: other, route: .local(PaneLocalScreen.terminal(workspaceId: "ws-2").token)
        ), "the split terminal works in the workspace of the chat it came from, on that chat's server")
        let context = panes.context(of: split)
        #expect(context.serverId == other, "the window's own server does not stand in for the terminal's")
        #expect(context.workspaceId == "ws-2")
    }

    @Test func aRelaunchBringsLinkedSplitPanesBackButNotTheLauncherOrATerminal() async throws {
        let store = try makeStore()
        let before = try await chatWindow()
        defer { withExtendedLifetime(before) {} }
        let panes = before.navigation.panes
        let files = try #require(panes.split(panes.mainLeafID, axis: .row))
        panes.show(entry(.files(workspace: "ws-1", path: "Sources")), in: files)
        let terminal = try #require(panes.split(files, axis: .column))
        panes.show(entry(.local(PaneLocalScreen.terminal(workspaceId: "ws-1").token)), in: terminal)
        let launcher = try #require(panes.split(files, axis: .row))
        #expect(panes.topEntry(of: launcher) == panes.topEntry(of: files), "a Files pane's split copies it")
        panes.show(panes.launcher(for: launcher), in: launcher)
        store.save(PaneLayoutArchive(restorable: panes.layout(rootServerId: serverId)), scene: "a")

        let afterRoot = try await chatWindow(store: store, scene: "a")
        defer { withExtendedLifetime(afterRoot) {} }
        let after = afterRoot.navigation.panes
        #expect(after.splitLeaves.map(\.id) == [files])
        #expect(after.topEntry(of: files) == entry(.files(workspace: "ws-1", path: "Sources")))
        #expect(shape(after.tree.root) == "row[leaf-1 0.5, \(files.raw) 0.5]")
        #expect(after.mainLeafID.raw == "leaf-1")
    }

    @Test func aDropOnAPaneEdgeOpensTheEntryOnThatSide() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        let file = entry(.file(.workspace(id: "ws-1", worktree: nil), path: "README.md", line: nil))
        let above = try #require(panes.split(panes.mainLeafID, edge: .top, showing: panes.route(for: file)))
        #expect(shape(panes.tree.root) == "column[\(above.raw) 0.5, leaf-1 0.5]")
        #expect(panes.topEntry(of: above) == file)
    }

    @Test func theOuterQuarterOfAPaneIsItsNearestEdge() {
        let cell = CGRect(x: 100, y: 0, width: 400, height: 800)
        #expect(PaneDropTarget.zone(at: CGPoint(x: 199, y: 400), in: cell) == .left)
        #expect(PaneDropTarget.zone(at: CGPoint(x: 201, y: 400), in: cell) == nil)
        #expect(PaneDropTarget.zone(at: CGPoint(x: 300, y: 790), in: cell) == .bottom)
        #expect(PaneDropTarget.zone(at: CGPoint(x: 490, y: 100), in: cell) == .right, "nearest of two edges, by share")
    }
}
