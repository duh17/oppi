import XCTest

/// A launch precondition failed (`E2ETestCase.requireLaunchStep`).
struct E2ELaunchFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Remembers which E2E launch configurations never reached their first surface,
/// so the rest of the run fails them at once with the first reason instead of
/// relaunching and waiting out the same ceiling per test.
///
/// A configuration is the class plus everything that decides its launch path
/// (the launch flags, arguments, and environment), so a sibling test that
/// launches differently still runs. A failure counts only while no launch of
/// that configuration has succeeded in this process: after one success, a later
/// launch failure is that test's leftover state, not a broken precondition.
struct E2ELaunchFailureLedger {
    private var failures: [String: String] = [:]
    private var launched: Set<String> = []

    /// Environment that differs per run without changing the path. The
    /// auto-open workspace does change it, so it stays in the key.
    private static let ignoredEnvironment: Set<String> = [
        "PI_E2E_INVITE_URL", "OPPI_E2E_LAUNCH_INVITE",
    ]

    static func key(
        className: String,
        flags: [String: Bool],
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let flagText = flags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let envText = environment
            .filter { !ignoredEnvironment.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return [className, flagText, arguments.joined(separator: " "), envText].joined(separator: "|")
    }

    func failure(for key: String) -> String? {
        failures[key]
    }

    mutating func recordFailure(_ reason: String, for key: String) {
        guard !launched.contains(key), failures[key] == nil else { return }
        failures[key] = reason
    }

    mutating func recordSuccess(for key: String) {
        guard failures[key] == nil else { return }
        launched.insert(key)
    }
}

/// Every launch in the E2E target shares one reset token, whichever class
/// makes the app: a plain `XCTestCase` preview with its own token would clear
/// a pairing a later `E2ETestCase` launch needs.
final class E2ELaunchTokenTests: XCTestCase {
    func testMakeAppSharesTheProcessTokenInTheE2ETarget() throws {
        let arguments = OppiTestLaunch.makeApp().launchArguments
        let tokenIndex = try XCTUnwrap(arguments.firstIndex(of: "-\(OppiTestLaunch.resetTokenKey)"))

        XCTAssertEqual(arguments[tokenIndex + 1], OppiTestLaunch.processToken)
    }
}

final class E2ELaunchFailureLedgerTests: XCTestCase {
    private func key(_ className: String = "A", inbox: Bool = true, arguments: [String] = []) -> String {
        E2ELaunchFailureLedger.key(
            className: className,
            flags: ["inboxOnly": inbox],
            arguments: arguments,
            environment: ["PI_E2E_INVITE_URL": "oppi://run-specific"]
        )
    }

    func testFirstFailureBlocksTheSameConfigurationWithItsReason() {
        var ledger = E2ELaunchFailureLedger()
        ledger.recordFailure("inbox missing", for: key())
        ledger.recordFailure("later reason", for: key())

        XCTAssertEqual(ledger.failure(for: key()), "inbox missing")
    }

    func testSiblingThatLaunchesDifferentlyStillRuns() {
        var ledger = E2ELaunchFailureLedger()
        ledger.recordFailure("inbox missing", for: key())

        XCTAssertNil(ledger.failure(for: key(inbox: false)))
        XCTAssertNil(ledger.failure(for: key(arguments: ["-dev.chenda.Oppi.experiments.liveVoice", "NO"])))
        XCTAssertNil(ledger.failure(for: key("B")))
    }

    func testSiblingThatAutoOpensAnotherWorkspaceStillRuns() {
        func key(workspace: String) -> String {
            E2ELaunchFailureLedger.key(
                className: "A",
                flags: [:],
                arguments: [],
                environment: ["OPPI_E2E_AUTO_OPEN_WORKSPACE": workspace]
            )
        }
        var ledger = E2ELaunchFailureLedger()
        ledger.recordFailure("workspace missing", for: key(workspace: "one"))

        XCTAssertNil(ledger.failure(for: key(workspace: "two")))
    }

    func testFailureAfterAnEarlierSuccessIsNotRecorded() {
        var ledger = E2ELaunchFailureLedger()
        ledger.recordSuccess(for: key())
        ledger.recordFailure("sheet left over", for: key())

        XCTAssertNil(ledger.failure(for: key()))
    }
}
