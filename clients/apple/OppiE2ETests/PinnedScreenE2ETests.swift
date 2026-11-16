import Foundation
import XCTest

/// Session pins and the Pinned screen against the real server. A working
/// session is pinned from its row's swipe, a finished one from its chat's …
/// menu; a failed session, two folders, and two files are pinned through the
/// API. **Pinned** in the sidebar (the iPhone's drawer) lists them as
/// Sessions, Folders, and Files, each session with its live status, and a
/// pinned session opens its chat. Run through `clients/apple/scripts/e2e.sh
/// --native` (iPad: `OPPI_SIM_DEVICE_PROFILE=ipad`).
@MainActor
final class PinnedScreenE2ETests: E2ETestCase {
    nonisolated(unsafe) private var sessionIds: [String: String] = [:]

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    // The seeded sessions show as Working and Done only to an app launched before them.
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += [
            "-dev.chenda.Oppi.theme.mode", "manual",
            "-dev.chenda.Oppi.theme.id", "dark",
        ]
    }

    override func seedE2EFixtures() throws {
        let workspaceId = try e2eWorkspaceId()
        let nowMs = Date().timeIntervalSince1970 * 1_000
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/session-threads",
            body: [
                "workspaceId": workspaceId,
                "nowMs": nowMs,
                "sessions": [
                    Self.session("working", "Write the 0.56 release notes", "busy", activity: -20_000, cost: 0.84, messages: 14),
                    Self.session("done", "Review the pins protocol change", "ready", activity: 30_000, cost: 1.92, messages: 22),
                    Self.session("failed", "Fix the flaky iPad pane test", "error", activity: -600_000, cost: 0.37, messages: 9),
                    Self.session("stopped", "Draft App Store screenshots", "stopped", activity: -7_200_000, cost: 2.6, messages: 31),
                ],
                "interactions": [],
            ]
        )
        sessionIds = try XCTUnwrap(response["sessionIds"] as? [String: String], "Session fixture ids missing")

        // A docs workspace with two folders and their files.
        let notes = try createLabWorkspaceFileFixture(
            directoryName: "release-notes", filename: "0.56.md",
            base64: Data("# 0.56\n\n- Session pins\n".utf8).base64EncodedString()
        )
        _ = try createLabWorkspaceFileFixture(
            directoryName: "release-notes", filename: "app-store-checklist.md",
            base64: Data("# App Store checklist\n".utf8).base64EncodedString()
        )
        _ = try createLabWorkspaceFileFixture(
            directoryName: "screenshots", filename: "README.md",
            base64: Data("# Screenshots\n".utf8).base64EncodedString()
        )
        let docs = try createLabWorkspace(named: "Oppi Docs", hostMount: (notes.hostMount as NSString).deletingLastPathComponent)
        for target: [String: Any] in [
            ["origin": "session", "sessionId": try XCTUnwrap(sessionIds["failed"])],
            ["origin": "workspace", "workspaceId": docs, "path": "release-notes"],
            ["origin": "workspace", "workspaceId": docs, "path": "screenshots"],
            ["origin": "workspace", "workspaceId": docs, "path": "release-notes/0.56.md"],
            ["origin": "workspace", "workspaceId": docs, "path": "release-notes/app-store-checklist.md"],
        ] {
            _ = try e2eLabAPIJSON(method: "POST", path: "/pins", body: ["target": target])
        }
    }

    override func tearDownWithError() throws {
        // Pins outlive a case on the shared server; leave none behind.
        if let revision = try? e2eLabAPIJSON(method: "GET", path: "/pins")["revision"] as? Int {
            _ = try? e2eLabAPIJSON(method: "PUT", path: "/pins", body: ["baseRevision": revision, "pins": [Any]()])
        }
        try super.tearDownWithError()
    }

    func testPinSessionsAndOpenOneFromPinned() throws {
        let working = try XCTUnwrap(sessionIds["working"])
        let done = try XCTUnwrap(sessionIds["done"])
        let failed = try XCTUnwrap(sessionIds["failed"])
        let list = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "All Sessions did not appear")
        beat()

        // Pin from the row: swipe left, then Pin.
        let workingRow = app.buttons["session.nav.\(working)"]
        XCTAssertTrue(scrollToElement(workingRow, in: list), "the working session's row")
        workingRow.swipeLeft()
        tap(app.buttons["Pin"], named: "swipe Pin", timeout: 5)
        XCTAssertTrue(waitForPin(sessionId: working), "the server keeps the row's pin")
        beat()

        // Pin from the chat's … menu.
        let doneRow = app.buttons["session.nav.\(done)"]
        XCTAssertTrue(scrollToElement(doneRow, in: list), "the finished session's row")
        tap(doneRow, named: "finished session")
        tap(app.buttons["chat.toolbar.more"], named: "chat …", timeout: 15)
        beat(0.8)
        tap(app.buttons["chat.toolbar.menu.pin"], named: "Pin Session", timeout: 5)
        XCTAssertTrue(waitForPin(sessionId: done), "the server keeps the chat's pin")
        beat()
        tap(app.buttons["chat.toolbar.more"], named: "chat …", timeout: 5)
        XCTAssertTrue(app.buttons["chat.toolbar.menu.unpin"].waitForExistence(timeout: 5), "the menu now says Unpin Session")
        beat(0.8)
        // Close the menu with a tap on empty timeline space: the menu covers the bar.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.32)).tap()
        XCTAssertTrue(app.buttons["chat.toolbar.menu.unpin"].waitForNonExistence(timeout: 5), "the menu closed")

        // Back to All Sessions, then open Pinned from the sidebar (the
        // iPhone's drawer; on iPad the split sidebar may already show it).
        beat(0.8)
        tap(app.buttons["chat.toolbar.back"], named: "chat Back", timeout: 5)
        beat()
        if !pinnedRowIsHittable {
            let drawer = app.buttons["workspace.sidebar.open"]
            if drawer.waitForExistence(timeout: 3) {
                tap(drawer, named: "workspace drawer")
            } else {
                revealSplitSidebarIfNeeded(in: app)
            }
            beat()
        }
        tap(app.buttons["workspace.pinned.open"], named: "Pinned", timeout: 10)
        let pinned = app.collectionViews["pinned.list"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 10), "the Pinned screen")
        for group in ["sessions", "folders", "files"] {
            XCTAssertTrue(pinned.descendants(matching: .any)["pinned.header.\(group)"].waitForExistence(timeout: 10), "the \(group) group")
        }
        for id in [working, done, failed] {
            XCTAssertTrue(pinned.buttons["session.nav.\(id)"].waitForExistence(timeout: 10), "pinned session \(id) shows as its session row")
        }
        XCTAssertTrue(pinned.cells["pinned.pin.\(try docsKey("release-notes/0.56.md"))"].exists, "the pinned file")
        beat(2)
        try saveLabScreenshot(name: "pinned-screen")

        // A pinned session opens its chat.
        tap(pinned.buttons["session.nav.\(working)"], named: "pinned working session")
        XCTAssertTrue(app.buttons["chat.toolbar.more"].waitForExistence(timeout: 15), "the pinned session's chat opens")
        beat(2)
    }

    // MARK: Helpers

    private var pinnedRowIsHittable: Bool {
        let row = app.buttons["workspace.pinned.open"]
        return row.exists && row.isHittable
    }

    private static func session(_ key: String, _ name: String, _ status: String, activity: Double, cost: Double, messages: Int) -> [String: Any] {
        [
            "key": key, "name": name, "status": status,
            "createdAtOffsetMs": activity - 3_600_000, "lastActivityOffsetMs": activity,
            "model": "anthropic/claude-opus-5-5", "cost": cost,
            "contextTokens": 64_000, "contextWindow": 1_000_000, "messageCount": messages,
        ]
    }

    /// The pin row key of a docs workspace path (`<workspace>:<path>`).
    private func docsKey(_ path: String) throws -> String {
        let pins = try XCTUnwrap(e2eLabAPIJSON(method: "GET", path: "/pins")["pins"] as? [[String: Any]])
        let target = try XCTUnwrap(pins.compactMap { $0["target"] as? [String: Any] }.first { $0["path"] as? String == path })
        return "\(try XCTUnwrap(target["workspaceId"] as? String)):\(path)"
    }

    private func waitForPin(sessionId: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pins = (try? e2eLabAPIJSON(method: "GET", path: "/pins")["pins"] as? [[String: Any]]) ?? []
            if pins.contains(where: { ($0["target"] as? [String: Any])?["sessionId"] as? String == sessionId }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    private func beat(_ seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
