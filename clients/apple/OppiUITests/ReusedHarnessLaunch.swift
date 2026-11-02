import XCTest

/// One app launch kept across the tests of a harness class that opts in
/// (`UIHarnessTestCase.reusesLaunch`). The launch keeps its process; what a
/// relaunch gave each test, the app-side reset contract gives it in process
/// (`OppiTestLaunch.requestInProcessReset`, `HarnessLaunchReset`), and a reset
/// that did not take fails the test naming the generation the app still shows.
///
/// A launch is reused only when the next test asks for the same launch
/// signature (arguments and environment); another signature, a dead app, or a
/// failed test terminates it and launches fresh.
@MainActor
enum ReusedHarnessLaunch {
    private struct Entry {
        let app: XCUIApplication
        let signature: String
        var generation: UInt64
    }

    private static var entries: [String: Entry] = [:]

    static let markerID = "harness.reset.generation"
    static let failureID = "harness.reset.failure"

    /// A class's opt-in, unless the run sets `OPPI_UI_REUSE_LAUNCH=0`
    /// (`TEST_RUNNER_OPPI_UI_REUSE_LAUNCH=0` through xcodebuild): every test then
    /// launches fresh, to tell a reuse problem from a test problem.
    static func isEnabled(optedIn: Bool) -> Bool {
        optedIn && ProcessInfo.processInfo.environment["OPPI_UI_REUSE_LAUNCH"] != "0"
    }

    /// The app for a test: the owner's live launch after a verified reset when
    /// its signature matches, else a fresh launch from `launch`, which must
    /// set `OppiTestLaunch.reuseLaunchKey` and start the app. `freshProcess`
    /// is for a test that needs a new process (the launch it makes then serves
    /// the tests after it).
    static func app(
        owner: String,
        signature: String,
        readyID: String,
        freshProcess: Bool = false,
        launch: () -> XCUIApplication
    ) -> XCUIApplication {
        guard isEnabled(optedIn: true) else { return launch() }
        if freshProcess { discard(owner: owner) }
        if let reused = resetReusable(owner: owner, signature: signature, readyID: readyID) {
            return reused
        }
        let app = launch()
        let marker = app.descendants(matching: .any)[markerID]
        if marker.waitUntilExists(timeout: 10), marker.value as? String == "0" {
            entries[owner] = Entry(app: app, signature: signature, generation: 0)
        } else {
            XCTFail("Launch reuse: the fresh launch did not publish \(markerID)=0 (marker value: \(describe(marker))). The app was not started with \(OppiTestLaunch.reuseLaunchKey)=1 or does not support reuse.")
        }
        return app
    }

    /// Ends the owner's launch: its class is done, or a test failed and left state the next one must not inherit.
    static func discard(owner: String) {
        entries.removeValue(forKey: owner)?.app.terminate()
    }

    private static func resetReusable(owner: String, signature: String, readyID: String) -> XCUIApplication? {
        guard var entry = entries[owner] else { return nil }
        guard entry.signature == signature, entry.app.state == .runningForeground else {
            discard(owner: owner)
            return nil
        }
        entry.generation += 1
        entries[owner] = entry
        OppiTestLaunch.requestInProcessReset(generation: entry.generation)

        let marker = entry.app.descendants(matching: .any)[markerID]
        let failure = entry.app.descendants(matching: .any)[failureID]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, marker.value as? String != String(entry.generation) {
            if failure.exists {
                let reason = failure.value as? String ?? failure.label
                discard(owner: owner)
                XCTFail("Launch reuse: the app could not vouch for reset generation \(entry.generation): \(reason).")
                return nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard marker.value as? String == String(entry.generation) else {
            let found = describe(marker)
            discard(owner: owner)
            XCTFail("Launch reuse: the in-process reset did not take. Expected \(markerID)=\(entry.generation) within 10 s, found \(found); the earlier test's state may still be on screen.")
            return nil
        }
        guard entry.app.descendants(matching: .any)[readyID].waitUntilExists(timeout: 10) else {
            discard(owner: owner)
            XCTFail("Launch reuse: reset generation \(entry.generation) applied but \(readyID) never appeared.")
            return nil
        }
        return entry.app
    }

    private static func describe(_ marker: XCUIElement) -> String {
        marker.exists ? "\(marker.value as? String ?? "nil")" : "no marker element"
    }
}
