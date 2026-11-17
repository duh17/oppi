import XCTest

/// iPad: ⌘D beside a chat opens the New Pane launcher for the chat's own
/// server and workspace, so its Files choice is live and its Pinned group
/// lists that server's pins.
@MainActor
final class IPadPaneLauncherE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }

    override var e2eOrientation: UIDeviceOrientation { .landscapeLeft }

    override func tearDownWithError() throws {
        // Pins outlive a case on the shared server; leave none behind.
        if let revision = try? e2eLabAPIJSON(method: "GET", path: "/pins")["revision"] as? Int {
            _ = try? e2eLabAPIJSON(method: "PUT", path: "/pins", body: ["baseRevision": revision, "pins": [Any]()])
        }
        try super.tearDownWithError()
    }

    func testLauncherBesideChatKnowsItsServerAndWorkspace() throws {
        try XCTSkipUnless(min(app.frame.width, app.frame.height) >= 700, "Split panes need an iPad simulator")
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 20), "the chat opened")
        // The server's home folder always exists.
        _ = try e2eLabAPIJSON(method: "POST", path: "/pins", body: ["target": ["kind": "files", "origin": "host", "path": NSNull()]])

        app.typeKey("d", modifierFlags: .command)
        let files = app.buttons["pane.launcher.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10), "⌘D opened the launcher")
        XCTAssertTrue(files.isEnabled, "Files browses the chat's workspace")
        XCTAssertTrue(app.buttons["pane.launcher.pin.~"].waitForExistence(timeout: 10), "the launcher lists the server's pin")
    }
}
