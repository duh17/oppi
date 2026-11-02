import XCTest

/// One app launch kept across the tests of a class that opts in
/// (`UIHarnessTestCase.reusesLaunch`, `PreviewUITestCase.reusesLaunch`). The
/// launch keeps its process; what a relaunch gave each test, the app-side reset
/// contract gives it in process (`OppiTestLaunch.requestInProcessReset`,
/// `HarnessLaunchReset`), and a reset that did not take fails the test naming
/// the generation the app still shows.
///
/// A launch is reused when the next test asks for the same process signature:
/// its arguments and its environment apart from the screen environment
/// (`OppiTestLaunch.screenEnvironmentPrefix`, the `SCREENSHOT_*` keys that pick
/// a preview's screen, page, site, and theme). The screen environment travels
/// with the reset instead, through a file the app reads before it builds the
/// next root, so tests of one class that open different screens share a
/// process. Another process signature, a dead app, or a failed test terminates
/// the launch and launches fresh.
@MainActor
enum ReusedHarnessLaunch {
    private struct Entry {
        let app: XCUIApplication
        let signature: String
        let launchToken: String
        var generation: UInt64

        /// The reset token the app applied last: the launch's, then one per
        /// in-process reset, built as `TestLaunchContract.applyInProcessReset` builds it.
        var appliedToken: String { generation == 0 ? launchToken : "\(launchToken)#reuse\(generation)" }
    }

    private static var entries: [String: Entry] = [:]
    private static var observer: ReusedLaunchEndObserver?

    static let markerID = "harness.reset.generation"
    static let failureID = "harness.reset.failure"

    /// Where the next reset's screen environment is written. One file per test
    /// process: only one launch of the app runs at a time. Simulator processes
    /// share the host file system, so the app reads the runner's file by path.
    private static let screenFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("oppi-reuse-screen-\(OppiTestLaunch.processToken).json")

    /// A class's opt-in, unless the run sets `OPPI_UI_REUSE_LAUNCH=0`
    /// (`TEST_RUNNER_OPPI_UI_REUSE_LAUNCH=0` through xcodebuild): every test then
    /// launches fresh, to tell a reuse problem from a test problem.
    static func isEnabled(optedIn: Bool) -> Bool {
        optedIn && ProcessInfo.processInfo.environment["OPPI_UI_REUSE_LAUNCH"] != "0"
    }

    /// The reset token the owner's live launch applied last, for a test that
    /// launches again inside itself: a relaunch with this token keeps what the
    /// test wrote, as a relaunch with the test's own token does without reuse.
    static func appliedResetToken(owner: String) -> String? {
        entries[owner]?.appliedToken
    }

    /// The app for a test: the owner's live launch after a verified reset to
    /// `application`'s screen environment when its process signature matches,
    /// else `application` itself, started by `launch`. `readyID`, when given, is
    /// waited for after a reset. `freshProcess` is for a test that needs a new
    /// process (the launch it makes then serves the tests after it).
    static func app(
        owner: String,
        application: XCUIApplication,
        readyID: String?,
        freshProcess: Bool = false,
        launch: () -> Void
    ) -> XCUIApplication {
        // The run's kill switch holds for every caller, including a class that
        // calls this directly instead of checking its own opt-in first.
        guard isEnabled(optedIn: true) else {
            launch()
            return application
        }
        installObserver()
        application.launchEnvironment[OppiTestLaunch.reuseLaunchKey] = "1"
        application.launchEnvironment[OppiTestLaunch.reuseScreenFileKey] = screenFile.path
        let signature = OppiTestLaunch.launchSignature(of: application)
        if freshProcess { discard(owner: owner) }
        if let reused = resetReusable(
            owner: owner,
            signature: signature,
            screen: OppiTestLaunch.screenEnvironment(of: application),
            readyID: readyID
        ) {
            return reused
        }
        launch()
        let marker = application.descendants(matching: .any)[markerID]
        if marker.waitUntilExists(timeout: 10), marker.value as? String == "0",
           let token = OppiTestLaunch.resetToken(of: application) {
            entries[owner] = Entry(app: application, signature: signature, launchToken: token, generation: 0)
        } else {
            XCTFail("Launch reuse: the fresh launch did not publish \(markerID)=0 (marker value: \(describe(marker))). The app was not started with \(OppiTestLaunch.reuseLaunchKey)=1 and a reset token, or does not support reuse.")
        }
        return application
    }

    /// Ends the owner's launch: its class is done, or a test failed and left state the next one must not inherit.
    static func discard(owner: String) {
        entries.removeValue(forKey: owner)?.app.terminate()
    }

    private static func resetReusable(
        owner: String,
        signature: String,
        screen: [String: String],
        readyID: String?
    ) -> XCUIApplication? {
        guard var entry = entries[owner] else { return nil }
        guard entry.signature == signature, entry.app.state == .runningForeground else {
            discard(owner: owner)
            return nil
        }
        do {
            try JSONEncoder().encode(screen).write(to: screenFile, options: .atomic)
        } catch {
            discard(owner: owner)
            XCTFail("Launch reuse: could not write the screen environment to \(screenFile.path): \(error)")
            return nil
        }
        entry.generation += 1
        entries[owner] = entry
        OppiTestLaunch.requestInProcessReset(generation: entry.generation)

        // Between the old root going and the new one publishing there is no marker,
        // and reading a missing element's value fails the test; `exists` does not.
        let marker = entry.app.descendants(matching: .any)[markerID]
        let reset = entry.app.descendants(matching: .any).matching(identifier: markerID)
            .matching(NSPredicate(format: "value == %@", String(entry.generation))).firstMatch
        let failure = entry.app.descendants(matching: .any)[failureID]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !reset.exists {
            if failure.exists {
                let reason = failure.value as? String ?? failure.label
                discard(owner: owner)
                XCTFail("Launch reuse: the app could not vouch for reset generation \(entry.generation): \(reason).")
                return nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard reset.exists else {
            let found = describe(marker)
            discard(owner: owner)
            XCTFail("Launch reuse: the in-process reset did not take. Expected \(markerID)=\(entry.generation) within 10 s, found \(found); the earlier test's state may still be on screen.")
            return nil
        }
        if let readyID, !entry.app.descendants(matching: .any)[readyID].waitUntilExists(timeout: 10) {
            discard(owner: owner)
            XCTFail("Launch reuse: reset generation \(entry.generation) applied but \(readyID) never appeared.")
            return nil
        }
        return entry.app
    }

    private static func describe(_ marker: XCUIElement) -> String {
        marker.exists ? "\(marker.value as? String ?? "nil")" : "no marker element"
    }

    /// Ends a launch after a failed test of its owner, and at the end of the
    /// owner's class. An owner is its test class's name.
    private static func installObserver() {
        guard observer == nil else { return }
        let observer = ReusedLaunchEndObserver()
        XCTestObservationCenter.shared.addTestObserver(observer)
        self.observer = observer
    }
}

private final class ReusedLaunchEndObserver: NSObject, XCTestObservation {
    func testCaseDidFinish(_ testCase: XCTestCase) {
        // A failed test can leave state a reset does not clear (a stuck
        // gesture, a hung main thread); the next test launches fresh instead.
        guard (testCase.testRun?.totalFailureCount ?? 0) > 0 else { return }
        let owner = String(describing: type(of: testCase))
        MainActor.assumeIsolated { ReusedHarnessLaunch.discard(owner: owner) }
    }

    func testSuiteDidFinish(_ testSuite: XCTestSuite) {
        let owner = testSuite.name
        MainActor.assumeIsolated { ReusedHarnessLaunch.discard(owner: owner) }
    }
}
