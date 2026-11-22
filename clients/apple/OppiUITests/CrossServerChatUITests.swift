import XCTest

/// Stage 4a on the production shell over the chat-routes fixtures
/// (`SCREENSHOT_SCREEN=pane-restore`): a chat on the offline `mac-mini` beside
/// this server's chat, each on its own connection, so two chats show at once.
/// A list pane's rows open their chats in that pane, and a row for a chat
/// already on screen focuses the pane that shows it (one session, one leaf).
/// The iPad mini is the window.
///
/// A split leaf draws its screens in a view identified `pane.leaf.<id>`; the
/// main pane is the window's own stack and has no such view, so a chat there is
/// found by its composer and its grip (`pane.grip.<leaf>`).
@MainActor
final class CrossServerChatUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private let routesRow = "session.nav.chat-routes-session"

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Pane tests are simulator-only")
#endif
        continueAfterFailure = false
    }

    private var grips: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.grip.'"))
    }

    /// The open chats' composers: one per chat on screen, whichever panes hold
    /// them.
    private var composers: XCUIElementQuery {
        app.textViews.matching(identifier: "chat.input")
    }

    /// The view a split leaf draws its screens in.
    private func leaf(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)["pane.leaf.\(id)"]
    }

    private func grip(_ id: String) -> XCUIElement { app.buttons["pane.grip.\(id)"] }

    private var gripLabels: [String] { grips.allElementsBoundByIndex.map(\.label) }

    /// The two panes of a seeded window, landscape, in this file's seeds: the
    /// main pane and one beside it.
    private func openWindow(seed: String) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Panes need a wide window; the iPad mini is the wide simulator")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        launchPreview(screen: "pane-restore", environment: ["PANE_RESTORE_SEED": seed], colorScheme: "dark", ready: nil)
        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor(window.frame.width > window.frame.height), "The window turned")
        XCTAssertTrue(waitFor(grips.count == 2), "The seeded window has two panes")
    }

    /// The offline server's chat fills the main pane and this server's list sits
    /// beside it. A row of that list opens its chat in the pane the list is in:
    /// two chats, on two servers, each with its own composer and connection.
    func testAListPanesRowOpensASecondServersChatBesideTheFirst() throws {
        try openWindow(seed: "cross-server")
        let list = leaf("leaf-sessions")
        let row = app.descendants(matching: .any)[routesRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 15), "The list beside the chat lists this server's sessions")
        XCTAssertTrue(waitFor(composers.count == 1), "The mini's chat is the one chat on screen")
        XCTAssertTrue(waitFor(grip("leaf-1").label.contains("Mini routes")),
                      "The main pane shows the mini's chat: \(gripLabels)")
        XCTAssertTrue(list.waitForExistence(timeout: 5), "The list is the side pane")
        XCTAssertFalse(list.textViews["chat.input"].exists, "The list's pane holds no chat yet")
        hold()
        attachScreenCapture("cross-server-before")

        row.tap()

        let sideChat = list.textViews["chat.input"]
        XCTAssertTrue(sideChat.waitUntilExists(timeout: 20), "The row's chat opened in the list's pane")
        XCTAssertTrue(waitFor(grips.count == 2), "A row's open added no pane")
        XCTAssertTrue(waitFor(composers.count == 2), "Two chats show, one in each pane")
        XCTAssertEqual(grip("leaf-sessions").value as? String, "Focused", "The pane the row opened in has focus")
        XCTAssertTrue(waitFor(grip("leaf-1").label.contains("Mini routes")), "The main pane keeps the mini's chat")
        let frames = composers.allElementsBoundByIndex.map(\.frame).sorted { $0.minX < $1.minX }
        XCTAssertGreaterThan(frames[1].minX, frames[0].maxX - 1, "The two chats sit side by side: \(frames)")
        hold()
        attachScreenCapture("cross-server-two-chats")
    }

    // A session row's long-press menu is not driven here: in this preview
    // harness the context menu on a session row leaves the app's animation
    // completion unfired, so XCTest waits on it for minutes (a 150–200 s idle
    // wait after the press, reproduced with both menu actions). The placement
    // those menu items run — a chat of another server beside, a same-server
    // chat in the main pane — is proven at the unit level
    // (`PaneCrossServerChatTests`), and the same `place` runs for a drop.

    /// One session shows in one leaf: the row of the chat already beside the
    /// list focuses that pane, over the list's own open, and pushes no second
    /// chat.
    func testARowForAShownChatFocusesItsPane() throws {
        try openWindow(seed: "chat-beside-list")
        let chatPane = leaf("leaf-chat")
        XCTAssertTrue(chatPane.textViews["chat.input"].waitUntilExists(timeout: 15), "The chat beside the list shows")
        let row = app.descendants(matching: .any)[routesRow]
        XCTAssertTrue(row.waitUntilExists(timeout: 15), "The list is still on the main pane")
        XCTAssertNotEqual(grip("leaf-chat").value as? String, "Focused")
        hold()
        attachScreenCapture("chat-beside-list-before")

        row.tap()

        XCTAssertTrue(waitFor(grip("leaf-chat").value as? String == "Focused"),
                      "The row focused the pane that shows it")
        XCTAssertTrue(waitFor(grips.count == 2), "and opened no pane")
        XCTAssertTrue(waitFor(composers.count == 1), "One chat: it pushed no second copy over the list")
        XCTAssertTrue(row.exists, "The list stayed on the main pane")
        XCTAssertTrue(chatPane.textViews["chat.input"].exists, "The chat kept its pane")
        hold()
        attachScreenCapture("chat-beside-list-after")
    }

    /// The screen's capture: in landscape `app.screenshot()` draws the iPad
    /// sideways into a portrait canvas.
    private func attachScreenCapture(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
