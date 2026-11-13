import Foundation
import Testing
@testable import Oppi

/// The saved tree (build plan §1.8): what survives a relaunch, what never
/// does, and the versions that start fresh.
@Suite("PaneLayoutArchive")
struct PaneLayoutArchiveTests: PaneFixtureBuilding {
    private func entry(_ route: PaneRoute) -> PaneStackEntry {
        PaneStackEntry(serverId: paneFixtureServer, route: route)
    }

    private func local(_ raw: String) -> PaneStackEntry {
        entry(.local(PaneLocalToken(raw: raw)))
    }

    @Test func aTwoPaneTreeComesBackWithItsWeightsFocusStacksAndReadingPosition() throws {
        let chat = PaneLeaf(
            id: id("main"), name: "Chat",
            stack: [
                entry(.sessions(workspace: "ws-1")),
                entry(.session("s-1")),
                entry(.file(.workspace(id: "ws-1", worktree: "wt-2"), path: "src/a b.swift", line: 12)),
            ],
            attachedTo: nil, origin: .split
        )
        let git = PaneLeaf(
            id: id("side"), name: nil,
            stack: [entry(.git(workspace: "ws-1", worktree: nil))],
            attachedTo: id("main"), origin: .attached
        )
        let layout = PaneLayout(
            root: .split(axis: .row, children: [.leaf(chat), .leaf(git)], weights: [0.65, 0.35]),
            focus: id("side"),
            recency: ids("side", "main"),
            collapsed: [:]
        )
        let scroll = PaneChatScroll(sessionId: "s-1", itemId: "msg-77", relativeY: 42)
        let archive = try #require(PaneLayoutArchive(restorable: layout, chatScroll: [id("main"): scroll], companionFraction: 0.35))

        let decoded = try #require(PaneLayoutArchive.decode(try archive.encoded()))
        #expect(decoded == archive)
        #expect(decoded.layout.leaves == [chat, git])
        #expect(decoded.layout.focus == id("side"))
        #expect(decoded.layout.recency == ids("side", "main"))
        guard case .split(.row, _, let weights) = decoded.layout.root else {
            Issue.record("not a row")
            return
        }
        #expect(abs(weights[1] - 0.35) < 1e-9)
        #expect(decoded.chatScroll[id("main")] == scroll)
        #expect(decoded.companionFraction == 0.35)
    }

    @Test func screensWithoutLinksAreNotSavedAndALeafLeftEmptyClosesWithItsAttachedLeaves() throws {
        let main = PaneLeaf(
            id: id("main"), name: nil,
            stack: [entry(.sessions(workspace: nil)), local("settings"), entry(.session("s-1")), local("reader")],
            attachedTo: nil, origin: .split
        )
        let outline = PaneLeaf(id: id("outline"), name: nil, stack: [local("outline")], attachedTo: id("main"), origin: .attached)
        let other = PaneLeaf(id: id("other"), name: nil, stack: [local("context")], attachedTo: nil, origin: .split)
        let attachedToOther = PaneLeaf(
            id: id("files"), name: nil, stack: [entry(.files(workspace: "ws-1", path: nil))],
            attachedTo: id("other"), origin: .attached
        )
        let layout = PaneLayout(
            root: .split(
                axis: .row,
                children: [.leaf(main), .leaf(outline), .leaf(other), .leaf(attachedToOther)],
                weights: [0.4, 0.2, 0.2, 0.2]
            ),
            focus: id("other")
        )

        let archive = try #require(PaneLayoutArchive(restorable: layout))
        #expect(archive.layout.leaves.map(\.id) == ids("main"), "every leaf with nothing to restore went, and what hung on it")
        #expect(archive.layout.leaves[0].stack == [entry(.sessions(workspace: nil)), entry(.session("s-1"))])
        #expect(archive.layout.focus == id("main"), "focus falls to a leaf that is left")

        let onlyLocal = PaneLayout(single: PaneLeaf(id: id("main"), name: nil, stack: [local("settings")], attachedTo: nil, origin: .split))
        #expect(PaneLayoutArchive(restorable: onlyLocal) == nil, "nothing restorable is nothing saved")
    }

    /// A web page comes back as its link; one no link may name (loopback)
    /// leaves with its pane, and the rest of the window still restores.
    @Test func aWebPageComesBackAndOneNoLinkMayNameLeavesWithItsPane() throws {
        let page = try #require(URL(string: "https://example.com/docs?q=1#top"))
        let local = try #require(URL(string: "http://localhost:5173/"))
        let layout = row([
            (leaf("main", .sessions(workspace: nil)), 0.4),
            (leaf("web", .browser(page)), 0.3),
            (leaf("dev", .browser(local)), 0.3),
        ], focus: "dev")

        let archive = try #require(PaneLayoutArchive(restorable: layout))
        let decoded = try #require(PaneLayoutArchive.decode(try archive.encoded()))
        #expect(decoded.layout.leaves.map(\.id) == ids("main", "web"))
        #expect(decoded.layout.leaves[1].stack == [entry(.browser(page))])
    }

    @Test func aLeafKindFromANewerOppiIsKeptThroughRestoration() throws {
        let raw: [String: JSONValue] = ["web": "https://example.com", "zoom": 1.5]
        let layout = PaneLayout(single: PaneLeaf(
            id: id("main"), name: nil,
            stack: [entry(.unsupported(kind: "web", raw: raw))],
            attachedTo: nil, origin: .layout
        ))
        let archive = try #require(PaneLayoutArchive(restorable: layout))
        #expect(PaneLayoutArchive.decode(try archive.encoded())?.layout.leaves == layout.leaves)
    }

    /// X5: another schema version, or bytes that are not a tree, start fresh.
    @Test func anUnknownVersionOrAnUnreadableTreeDecodesToNothing() throws {
        let layout = PaneLayout(single: leaf("main"))
        let data = try #require(PaneLayoutArchive(restorable: layout)).encoded()
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["v"] = PaneLayoutArchive.schemaVersion + 1
        #expect(PaneLayoutArchive.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
        #expect(PaneLayoutArchive.decode(Data("{\"v\":1}".utf8)) == nil)
        #expect(PaneLayoutArchive.decode(Data("not json".utf8)) == nil)
    }

    @Test func anEntryWhoseLinkThisBuildCannotReadIsDropped() throws {
        let layout = PaneLayout(single: PaneLeaf(
            id: id("main"), name: nil,
            stack: [entry(.sessions(workspace: nil)), entry(.session("s-1"))],
            attachedTo: nil, origin: .split
        ))
        let data = try #require(PaneLayoutArchive(restorable: layout)).encoded()
        let text = try #require(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "oppi://session/s-1", with: "oppi://session/s-1/extra")
        let decoded = try #require(PaneLayoutArchive.decode(Data(text.utf8)))
        #expect(decoded.layout.leaves[0].stack == [entry(.sessions(workspace: nil))])
    }
}
