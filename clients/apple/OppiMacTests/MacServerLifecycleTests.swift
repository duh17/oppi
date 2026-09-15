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

    private static let bundledHelper = "/Applications/Oppi.app/Contents/Resources/Helpers/node"

    private static func migrationNeeded(
        plistBody: String,
        canRunBundledNode: Bool = true,
        existing: Set<String> = []
    ) -> Bool {
        let currentPath = MacServerLifecycle.launchAgentPlistPaths[0]
        return MacServerLifecycle.launchAgentNeedsMigration(
            canRunBundledNode: canRunBundledNode,
            fileExists: { $0 == currentPath || existing.contains($0) },
            readContents: { _ in plistBody }
        )
    }

    private static func plist(node: String, cli: String) -> String {
        """
        <key>ProgramArguments</key>
        <array>
            <string>\(node)</string>
            <string>\(cli)</string>
            <string>serve</string>
        </array>
        """
    }

    @Test func staleMutableRuntimeLaunchAgentNeedsMigration() {
        #expect(Self.migrationNeeded(
            plistBody: Self.plist(
                node: Self.bundledHelper,
                cli: "/Users/test/.config/oppi/server-runtime/dist/src/cli.js"
            ),
            existing: [Self.bundledHelper]
        ))
    }

    @Test func homebrewNodeLaunchAgentNeedsMigrationEvenWithNpmCLI() {
        #expect(Self.migrationNeeded(
            plistBody: Self.plist(node: "/opt/homebrew/bin/node", cli: "/opt/homebrew/bin/oppi")
        ))
    }

    @Test func bundledNodeWithNpmCLIDoesNotNeedMigration() {
        #expect(!Self.migrationNeeded(
            plistBody: Self.plist(node: Self.bundledHelper, cli: "/opt/homebrew/bin/oppi"),
            existing: [Self.bundledHelper]
        ))
    }

    @Test func bundledNodeThatNoLongerExistsNeedsMigration() {
        #expect(Self.migrationNeeded(
            plistBody: Self.plist(node: Self.bundledHelper, cli: "/opt/homebrew/bin/oppi")
        ))
    }

    @Test func launchAgentIsLeftAloneWhenThisAppHasNoBundledNode() {
        #expect(!Self.migrationNeeded(
            plistBody: Self.plist(node: "/opt/homebrew/bin/node", cli: "/opt/homebrew/bin/oppi"),
            canRunBundledNode: false
        ))
    }
}
