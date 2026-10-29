import notify
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
    /// Launch environment for a debug harness or preview whose launch a test
    /// class reuses across tests (`ReusedHarnessLaunch`).
    static let reuseLaunchKey = "OPPI_TEST_REUSE_LAUNCH"
    static let resetNotification = "dev.chenda.Oppi.test.reset"

    /// One token for the whole test process. The E2E target uses it for every
    /// launch, plain `XCTestCase` previews included: only the first launch
    /// resets, so relaunches keep the pairing and drafts they prove, and no
    /// class can clear a pairing a later `E2ETestCase` launch still needs (its
    /// invite is single-use).
    static let processToken = UUID().uuidString

    /// Set by `SWIFT_ACTIVE_COMPILATION_CONDITIONS` on the OppiE2ETests target
    /// (project.yml). These test bundles carry no Info.plist, so the bundle
    /// identifier cannot tell the targets apart.
    private static let isE2ETarget: Bool = {
#if OPPI_E2E_TESTS
        true
#else
        false
#endif
    }()

    /// The current test's token (UI target): every app a test makes shares it,
    /// so the first launch starts clean and a relaunch inside the test (a test
    /// that proves a saved choice survives one) keeps what the test wrote. The
    /// next test gets a new token.
    nonisolated(unsafe) private static var testToken: String?
    nonisolated(unsafe) private static var observer: TestEndObserver?

    private final class TestEndObserver: NSObject, XCTestObservation {
        func testCaseDidFinish(_ testCase: XCTestCase) {
            OppiTestLaunch.testToken = nil
        }
    }

    private static func currentTestToken() -> String {
        if isE2ETarget { return processToken }
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
    ///     `nil` uses the target's token: one per test in UI, one per process in E2E.
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

    /// Asks a launch started with `reuseLaunchKey` to run the reset contract
    /// again in process and rebuild its harness root. The generation travels as
    /// the Darwin notification's state; the app publishes it back as
    /// `harness.reset.generation`, which is how the caller knows the reset took.
    static func requestInProcessReset(generation: UInt64) {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        guard notify_register_check(resetNotification, &token) == NOTIFY_STATUS_OK else { return }
        notify_set_state(token, generation)
        notify_post(resetNotification)
        notify_cancel(token)
    }
}
