import CoreGraphics
import Foundation
import Testing
@testable import Oppi

/// The fit rule on the real window sizes: iPhone, iPad mini, and Mac windows.
@Suite("PanePresentation")
struct PanePresentationTests: PaneFixtureBuilding {
    static let miniPortrait = CGSize(width: 744, height: 1133)
    static let miniLandscape = CGSize(width: 1133, height: 744)
    static let sidebar: CGFloat = 320

    func resolve(
        _ layout: PaneLayout, size: CGSize, sidebar: CGFloat = 0, keyboard: CGFloat = 0,
        firstResponder: PaneID? = nil, liveCap: Int = 4
    ) -> PanePresentation {
        PanePresentation.resolve(
            layout, size: size, sidebarWidth: sidebar, keyboardHeight: keyboard, firstResponderLeaf: firstResponder,
            minimumSize: { $0.stack.last.flatMap { PaneMinimumSize.standard(for: $0.route) } ?? .zero },
            liveCap: liveCap
        )
    }

    func chat(_ raw: String) -> PaneLeaf { leaf(raw) }
    func list(_ raw: String) -> PaneLeaf { leaf(raw, .git(workspace: "ws-1", worktree: nil)) }
    func reader(_ raw: String) -> PaneLeaf { leaf(raw, .file(.workspace(id: "ws-1", worktree: nil), path: "README.md", line: nil)) }

    // MARK: iPhone and iPad mini

    @Test func iPhoneShowsOnlyTheFocusedLeaf() {
        let layout = row([(chat("chat"), 0.5), (reader("doc"), 0.5)], focus: "doc", recency: ["doc", "chat"])
        let presentation = resolve(layout, size: CGSize(width: 393, height: 852))
        #expect(presentation.frames == [id("doc"): CGRect(x: 0, y: 0, width: 393, height: 852)])
        #expect(presentation.overflow == ids("chat"))
    }

    @Test func miniPortraitHoldsAChatAndAReaderButNotTwoChats() {
        // WA1: the sidebar is a drawer in portrait, so the panes get all 744 pt.
        let chatAndReader = resolve(row([(chat("chat"), 0.5), (reader("doc"), 0.5)]), size: Self.miniPortrait)
        #expect(chatAndReader.frames[id("chat")] == CGRect(x: 0, y: 0, width: 375, height: 1133))
        #expect(chatAndReader.frames[id("doc")] == CGRect(x: 376, y: 0, width: 368, height: 1133))
        #expect(chatAndReader.overflow.isEmpty)

        let twoChats = resolve(row([(chat("one"), 0.5), (chat("two"), 0.5)], focus: "two", recency: ["two", "one"]), size: Self.miniPortrait)
        #expect(Array(twoChats.frames.keys) == ids("two"))
        #expect(twoChats.overflow == ids("one"))
    }

    @Test func miniLandscapeHoldsThreePanesUntilTheSidebarShows() {
        // WA2: 375 + 1 + 320 + 1 + 320 fits 1,133 pt; with a 320 pt sidebar, 813 pt holds two.
        let layout = row([(chat("chat"), 0.5), (list("git"), 0.25), (list("files"), 0.25)], recency: ["chat", "files", "git"])
        let hidden = resolve(layout, size: Self.miniLandscape)
        #expect(hidden.overflow.isEmpty)
        #expect(hidden.frames[id("chat")] == CGRect(x: 0, y: 0, width: 491, height: 744))
        #expect(hidden.frames[id("git")] == CGRect(x: 492, y: 0, width: 320, height: 744))
        #expect(hidden.frames[id("files")] == CGRect(x: 813, y: 0, width: 320, height: 744))

        let shown = resolve(layout, size: Self.miniLandscape, sidebar: Self.sidebar)
        #expect(shown.overflow == ids("git"))
        #expect(shown.frames[id("chat")]?.width == 492)
        #expect(shown.frames[id("files")] == CGRect(x: 493, y: 0, width: 320, height: 744))

        let twoChats = resolve(row([(chat("one"), 0.5), (chat("two"), 0.5)]), size: Self.miniLandscape, sidebar: Self.sidebar)
        #expect(twoChats.overflow.isEmpty)
    }

    // MARK: Mac

    @Test func macWindowAtItsMinimumShowsOnePane() {
        // CT7: 700 pt less a 320 pt sidebar leaves 380 pt, one pane.
        let layout = row([(chat("chat"), 0.5), (list("git"), 0.5)])
        let presentation = resolve(layout, size: CGSize(width: 700, height: 500), sidebar: Self.sidebar, liveCap: 8)
        #expect(presentation.frames == [id("chat"): CGRect(x: 0, y: 0, width: 380, height: 500)])
        #expect(presentation.overflow == ids("git"))
    }

    /// CT8: the pane counts of the Mac table, for eight chats and for a chat
    /// with seven lists.
    struct MacWindow: Sendable {
        let width: CGFloat
        let sidebarShown: Bool
        let chats: Int
        let withLists: Int
    }

    @Test(arguments: [
        MacWindow(width: 1470, sidebarShown: true, chats: 3, withLists: 3),
        MacWindow(width: 1470, sidebarShown: false, chats: 3, withLists: 4),
        MacWindow(width: 1512, sidebarShown: true, chats: 3, withLists: 3),
        MacWindow(width: 1512, sidebarShown: false, chats: 4, withLists: 4),
        MacWindow(width: 1728, sidebarShown: true, chats: 3, withLists: 4),
        MacWindow(width: 1728, sidebarShown: false, chats: 4, withLists: 5),
        MacWindow(width: 2560, sidebarShown: true, chats: 5, withLists: 6),
        MacWindow(width: 2560, sidebarShown: false, chats: 6, withLists: 7),
        // The 8-live cap binds only from about 2,620 pt: all eight fit here.
        MacWindow(width: 2622, sidebarShown: false, chats: 6, withLists: 8),
    ])
    func macWindowsHoldTheTablesPaneCounts(window: MacWindow) {
        let size = CGSize(width: window.width, height: 900)
        let sidebar = window.sidebarShown ? Self.sidebar : 0
        let allChats = row((1...8).map { (chat("c\($0)"), 1.0) })
        let chatAndLists = row([(chat("c1"), 1.0)] + (2...8).map { (list("l\($0)"), 1.0) })
        #expect(resolve(allChats, size: size, sidebar: sidebar, liveCap: 8).frames.count == window.chats)
        #expect(resolve(chatAndLists, size: size, sidebar: sidebar, liveCap: 8).frames.count == window.withLists)
    }

    // MARK: Overflow, focus, caps

    @Test func overflowTakesTheLeastRecentAndNeverTheFocusedLeaf() {
        // The focused leaf is the least recent here, and still stays.
        let layout = row(
            [(chat("a"), 0.25), (list("b"), 0.25), (list("c"), 0.25), (list("d"), 0.25)],
            focus: "a", recency: ["b", "c", "d", "a"]
        )
        let presentation = resolve(layout, size: CGSize(width: 1017, height: 744))
        #expect(Set(presentation.frames.keys) == Set(ids("a", "b", "c")))
        #expect(presentation.overflow == ids("d"))
    }

    @Test func aWindowTooSmallForAnyMinimumStillShowsTheFocusedLeaf() {
        // W3: every other leaf overflows, most recent first; the focused leaf takes the window.
        let layout = row([(chat("a"), 0.4), (list("b"), 0.3), (list("c"), 0.3)], focus: "b", recency: ["b", "c", "a"])
        let presentation = resolve(layout, size: CGSize(width: 300, height: 200))
        #expect(presentation.frames == [id("b"): CGRect(x: 0, y: 0, width: 300, height: 200)])
        #expect(presentation.overflow == ids("c", "a"))
    }

    @Test func theLiveCapSendsTheLeastRecentToOverflowAndSkipsCollapsedLeaves() throws {
        // P4: a fifth live leaf on the mini goes to overflow even where it would fit.
        let five = row((1...5).map { (list("l\($0)"), 1.0) })
        let capped = resolve(five, size: CGSize(width: 3000, height: 900), liveCap: 4)
        #expect(capped.overflow == ids("l5"))
        #expect(capped.frames.count == 4)

        // A collapsed leaf is parked, not live: it keeps its 20 pt strip under the cap.
        let collapsed = try five.collapse(id("l2"))
        let withStrip = resolve(collapsed, size: CGSize(width: 3000, height: 900), liveCap: 4)
        #expect(withStrip.overflow.isEmpty)
        #expect(withStrip.frames[id("l2")]?.width == PanePresentation.collapsedThickness)
    }

    @Test func aZoomedLeafFillsThePaneArea() throws {
        let layout = try row([(chat("a"), 0.5), (list("b"), 0.5)]).zoom(id("b"))
        let presentation = resolve(layout, size: Self.miniLandscape, sidebar: Self.sidebar)
        #expect(presentation.frames == [id("b"): CGRect(x: 0, y: 0, width: 813, height: 744)])
        #expect(presentation.overflow.isEmpty)
    }

    // MARK: Keyboard

    @Test func theKeyboardZoomsALowLeafWithinItsColumn() throws {
        // K2: mini landscape, the composer in the lower chat of the right column.
        let layout = try row([(chat("left"), 0.5), (list("top"), 0.5)])
            .split(id("top"), axis: .column, inserting: chat("low"))
        let presentation = resolve(layout, size: Self.miniLandscape, keyboard: 400, firstResponder: id("low"))
        #expect(presentation.zoomedForKeyboard == id("low"))
        #expect(presentation.frames[id("low")] == CGRect(x: 567, y: 0, width: 566, height: 744))
        // The column's other leaf is hidden, not sent to overflow; the left chat is untouched.
        #expect(presentation.frames[id("top")] == nil)
        #expect(presentation.overflow.isEmpty)
        #expect(presentation.frames[id("left")] == CGRect(x: 0, y: 0, width: 566, height: 744))

        // The upper leaf keeps 344 pt above the keyboard, over its 280 pt minimum.
        let upper = resolve(layout, size: Self.miniLandscape, keyboard: 400, firstResponder: id("top"))
        #expect(upper.zoomedForKeyboard == nil)
        #expect(upper.frames.count == 3)
    }
}
