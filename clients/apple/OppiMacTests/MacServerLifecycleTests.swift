import Testing
@testable import Oppi

@MainActor
@Suite("MacServerLifecycle")
struct MacServerLifecycleTests {
    @Test(
        "healthy local server is attached before spawning another child",
        arguments: [
            (launchAgentInstalled: true, healthCheckSucceeded: true, expected: MacServerStartupPlan.attachHealthyServer),
            (launchAgentInstalled: false, healthCheckSucceeded: true, expected: MacServerStartupPlan.attachHealthyServer),
            (launchAgentInstalled: true, healthCheckSucceeded: false, expected: MacServerStartupPlan.waitForLaunchAgent),
            (launchAgentInstalled: false, healthCheckSucceeded: false, expected: MacServerStartupPlan.spawnChildProcess),
        ]
    )
    func startupPlanChoosesSafeOwner(
        launchAgentInstalled: Bool,
        healthCheckSucceeded: Bool,
        expected: MacServerStartupPlan
    ) {
        #expect(MacServerLifecycle.startupPlan(
            launchAgentInstalled: launchAgentInstalled,
            healthCheckSucceeded: healthCheckSucceeded
        ) == expected)
    }

    @Test func launchAgentDetectionAcceptsEitherKnownLabel() {
        let installedPath = MacServerLifecycle.launchAgentPlistPaths[0]

        #expect(MacServerLifecycle.launchAgentInstalled { path in
            path == installedPath
        })
    }

    @Test func launchAgentDetectionReturnsFalseWhenNoKnownPathExists() {
        #expect(!MacServerLifecycle.launchAgentInstalled { _ in false })
    }

    @Test func staleMutableRuntimeLaunchAgentNeedsMigration() {
        let currentPath = MacServerLifecycle.launchAgentPlistPaths[0]
        #expect(MacServerLifecycle.launchAgentNeedsMigration(
            fileExists: { $0 == currentPath },
            readContents: { _ in
                "<string>/Users/test/.config/oppi/server-runtime/dist/src/cli.js</string>"
            }
        ))
    }

    @Test func npmLaunchAgentDoesNotNeedMigration() {
        let currentPath = MacServerLifecycle.launchAgentPlistPaths[0]
        #expect(!MacServerLifecycle.launchAgentNeedsMigration(
            fileExists: { $0 == currentPath },
            readContents: { _ in "<string>/opt/homebrew/bin/oppi</string>" }
        ))
    }

    @Test func oldLaunchAgentLabelNeedsMigration() {
        let oldPath = MacServerLifecycle.launchAgentPlistPaths[1]
        #expect(MacServerLifecycle.launchAgentNeedsMigration(
            fileExists: { $0 == oldPath },
            readContents: { _ in nil }
        ))
    }
}
