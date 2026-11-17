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
            root.navigation.restorePrimaryStack([
                .workspace(WorkspaceNavTarget(serverId: serverId, workspace: workspace)),
                .session(WorkspaceSessionNavTarget(serverId: serverId, sessionId: "s-1", workspaceId: "ws-1")),
            ])
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
        let launcher = try #require(panes.split(panes.routedLeafID, axis: .row))
        #expect(panes.topEntry(of: launcher) == entry(.local(PaneLocalScreen.launcher(workspaceId: "ws-1").token)),
                "a chat's split offers its own workspace's Sessions, Files and Terminal")
        #expect(panes.tree.focus == panes.routedLeafID, "the chat keeps focus")

        let files = entry(.files(workspace: "ws-1", path: nil))
        panes.show(files, in: launcher)
        let copy = try #require(panes.split(launcher, axis: .column))
        #expect(panes.topEntry(of: copy) == files)
        #expect(shape(panes.tree.root) == "row[leaf-1 0.5, column[\(launcher.raw) 0.5, \(copy.raw) 0.5] 0.5]")

        panes.show(panes.launcher(for: copy), in: copy)
        #expect(panes.topEntry(of: copy) == entry(.local(PaneLocalScreen.launcher(workspaceId: "ws-1").token)),
                "Show in Pane goes back to the launcher for the pane's workspace")
    }

    @Test func theCompanionStaysBesideItsChatThroughSplitsAndCloses() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        panes.companionDidOpen(entry(.git(workspace: "ws-1", worktree: nil)), pairing: Self.gitPairing)
        panes.setCompanionShare(0.4)
        let companion = try #require(panes.companionID)

        let split = try #require(panes.split(panes.routedLeafID, axis: .row))
        #expect(shape(panes.tree.root) == "row[leaf-1 0.3, \(companion.raw) 0.2, \(split.raw) 0.5]",
                "the chat and Git share the chat's half, Git keeping its 40%")
        #expect(shape(panes.cellLayout.root) == "row[leaf-1 0.5, \(split.raw) 0.5]",
                "the host lays the chat and Git out as one cell")

        panes.move(split, to: panes.routedLeafID, edge: .left)
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
        let first = try #require(panes.split(panes.routedLeafID, axis: .row))
        _ = try #require(panes.split(first, axis: .column))
        panes.close(panes.routedLeafID)
        #expect(panes.tree.leaves.count == 4, "Close Pane on the chat's leaf does nothing")

        panes.resetPanes()
        #expect(panes.splitLeaves.isEmpty)
        #expect(panes.companionID != nil, "the chat's panel stays")
    }

    @Test func aRelaunchBringsLinkedSplitPanesBackButNotTheLauncherOrATerminal() async throws {
        let store = try makeStore()
        let before = try await chatWindow()
        defer { withExtendedLifetime(before) {} }
        let panes = before.navigation.panes
        let files = try #require(panes.split(panes.routedLeafID, axis: .row))
        panes.show(entry(.files(workspace: "ws-1", path: "Sources")), in: files)
        let terminal = try #require(panes.split(files, axis: .column))
        panes.show(entry(.local(PaneLocalScreen.terminal(workspaceId: "ws-1").token)), in: terminal)
        let launcher = try #require(panes.split(files, axis: .row))
        #expect(panes.topEntry(of: launcher) == panes.topEntry(of: files), "a Files pane's split copies it")
        panes.show(panes.launcher(for: launcher), in: launcher)
        store.save(PaneLayoutArchive(restorable: panes.layout(navigation: before.navigation, rootServerId: serverId)), scene: "a")

        let afterRoot = try await chatWindow(store: store, scene: "a")
        defer { withExtendedLifetime(afterRoot) {} }
        let after = afterRoot.navigation.panes
        #expect(after.splitLeaves.map(\.id) == [files])
        #expect(after.topEntry(of: files) == entry(.files(workspace: "ws-1", path: "Sources")))
        #expect(shape(after.tree.root) == "row[leaf-1 0.5, \(files.raw) 0.5]")
        #expect(after.routedLeafID.raw == "leaf-1")
    }

    /// The Split Panes experiment off at launch: a saved split layout comes
    /// back as the chat and its panel alone, nothing changes the cells, and
    /// the tree (and so what is saved) keeps the split leaves until the switch
    /// turns back on and they return where they were.
    @Test func splitPanesOffKeepsASavedSplitLayoutAndOnBringsItBack() async throws {
        let store = try makeStore()
        let before = try await chatWindow()
        defer { withExtendedLifetime(before) {} }
        let saved = before.navigation.panes
        saved.companionDidOpen(entry(.git(workspace: "ws-1", worktree: nil)), pairing: Self.gitPairing)
        let files = try #require(saved.split(saved.routedLeafID, axis: .row))
        saved.show(entry(.files(workspace: "ws-1", path: nil)), in: files)
        saved.focus(files)
        store.save(PaneLayoutArchive(restorable: saved.layout(navigation: before.navigation, rootServerId: serverId)), scene: "a")

        let root = try await makeRoot()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        panes.splitsEnabled = false
        panes.connect(scene: "a", store: store)
        panes.restore(navigation: root.navigation, coordinator: root.coordinator)
        #expect(panes.pendingPanel(for: "s-1") == .git(workspace: "ws-1", worktree: nil), "the chat's panel still opens beside it")
        panes.companionDidOpen(entry(.git(workspace: "ws-1", worktree: nil)), pairing: Self.gitPairing)
        let companion = try #require(panes.companionID)
        #expect(panes.splitLeaves.isEmpty, "no split leaf mounts")
        #expect(shape(panes.cellLayout.root) == "leaf-1")
        #expect(panes.cellLayout.focus == panes.routedLeafID, "the chat has focus while it is the only pane")

        #expect(panes.split(panes.routedLeafID, axis: .row) == nil, "no split")
        #expect(panes.open(entry(.files(workspace: "ws-1", path: "Sources")), ofCell: panes.routedLeafID, full: false) == nil,
                "no Open in New Pane")
        panes.close(files)
        panes.resetPanes()
        #expect(panes.undoAction == nil)
        let kept = panes.layout(navigation: root.navigation, rootServerId: serverId)
        #expect(kept.leaf(files)?.stack == [entry(.files(workspace: "ws-1", path: nil))], "what is saved keeps the Files pane")
        #expect(kept.leaf(companion)?.attachedTo == panes.routedLeafID)

        panes.splitsEnabled = true
        #expect(panes.splitLeaves.map(\.id) == [files])
        #expect(shape(panes.cellLayout.root) == "row[leaf-1 0.5, \(files.raw) 0.5]")
        #expect(panes.cellLayout.focus == files, "focus is where it was")
    }

    @Test func aDropOnAPaneEdgeOpensTheEntryOnThatSide() async throws {
        let root = try await chatWindow()
        defer { withExtendedLifetime(root) {} }
        let panes = root.navigation.panes
        let file = entry(.file(.workspace(id: "ws-1", worktree: nil), path: "README.md", line: nil))
        let above = try #require(panes.split(panes.routedLeafID, edge: .top, showing: file))
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
