import XCTest

/// The one place UI and E2E tests build the Oppi `XCUIApplication`
/// (`dev/testing/README.md`, "UI and E2E launch state"). It sets the app's
/// launch contract (`Oppi/App/TestLaunchContract.swift`, whose keys are repeated
/// here): the app clears its own saved preferences, drafts, and What's New
/// state when it sees a reset token it has not applied yet. The harness never
/// writes defaults itself. Call sites add their own arguments and environment
/// to the returned app.
enum OppiTestLaunch {
    static let resetTokenKey = "dev.chenda.Oppi.test.resetToken"
    static let animationsKey = "dev.chenda.Oppi.test.animations"

    /// One token for the whole test process. E2E uses it so only the first
    /// launch resets and relaunches keep the pairing and drafts they prove.
    static let processToken = UUID().uuidString

    /// The current test's token: every app a test makes shares it, so the
    /// first launch starts clean and a relaunch inside the test (a test that
    /// proves a saved choice survives one) keeps what the test wrote. The next
    /// test gets a new token.
    nonisolated(unsafe) private static var testToken: String?
    nonisolated(unsafe) private static var observer: TestEndObserver?

    private final class TestEndObserver: NSObject, XCTestObservation {
        func testCaseDidFinish(_ testCase: XCTestCase) {
            OppiTestLaunch.testToken = nil
        }
    }

    private static func currentTestToken() -> String {
        if observer == nil {
            let observer = TestEndObserver()
            XCTestObservationCenter.shared.addTestObserver(observer)
            self.observer = observer
        }
        if let testToken { return testToken }
        let token = UUID().uuidString
        testToken = token
        return token
    }

    /// - Parameters:
    ///   - resetToken: Launches that share a token share state after the first.
    ///     `nil` uses the current test's token, so each test starts clean.
    ///   - animations: `false` turns UIKit animations off for the launch.
    static func makeApp(
        resetToken: String? = nil,
        animations: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-\(resetTokenKey)", resetToken ?? currentTestToken(),
        ]
        setAnimations(animations, on: app)
        return app
    }

    /// Switches animations for the app's next launch.
    static func setAnimations(_ enabled: Bool, on app: XCUIApplication) {
        var arguments = app.launchArguments
        if let index = arguments.firstIndex(of: "-\(animationsKey)") {
            arguments.removeSubrange(index...min(index + 1, arguments.count - 1))
        }
        if !enabled {
            arguments += ["-\(animationsKey)", "NO"]
        }
        app.launchArguments = arguments
    }
}
