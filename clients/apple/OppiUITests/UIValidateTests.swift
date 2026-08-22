import XCTest

/// Generic post-run UI dump. Launch a named screenshot-preview screen and write
/// Apple's accessibility tree, audit, and one PNG. Do not add a new method per screen.
@MainActor
final class UIValidateTests: XCTestCase {
    func testDumpNamedPreview() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("UI validate dumps are simulator-only")
#endif
        continueAfterFailure = false

        let screen = ProcessInfo.processInfo.environment["SCREENSHOT_SCREEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedScreen = screen, !resolvedScreen.isEmpty else {
            throw XCTSkip("SCREENSHOT_SCREEN is required; do not dump a default preview")
        }
        let readyIdentifier = ProcessInfo.processInfo.environment["OPPI_UI_VALIDATE_READY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReady = (readyIdentifier?.isEmpty == false) ? readyIdentifier! : "screenshot.ready"
        let outputDir = try resolveOutputDirectory(screen: resolvedScreen)

        let app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = resolvedScreen
        if let colorScheme = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"],
           !colorScheme.isEmpty {
            app.launchEnvironment["SCREENSHOT_COLOR_SCHEME"] = colorScheme
        }
        app.launch()

        let ready = app.descendants(matching: .any)[resolvedReady]
        XCTAssertTrue(
            ready.waitForExistence(timeout: 8),
            "Screenshot preview \(resolvedScreen) did not become ready"
        )
        _ = app.images.firstMatch.waitForExistence(timeout: 8)

        let snapshot = try app.snapshot()
        let tree = UIValidateDump.renderTree(snapshot)
        let audit = UIValidateDump.renderAudit(UIValidateDump.collectAuditIssues(from: app))
        try UIValidateDump.write(
            directory: outputDir,
            screen: resolvedScreen,
            tree: tree,
            audit: audit,
            screenshot: app.screenshot()
        )
        let shared = URL(fileURLWithPath: "/tmp/oppi-ui-validate/\(resolvedScreen)", isDirectory: true)
        if shared.standardizedFileURL != outputDir.standardizedFileURL {
            try UIValidateDump.write(
                directory: shared,
                screen: resolvedScreen,
                tree: tree,
                audit: audit,
                screenshot: app.screenshot()
            )
        }
    }

    private func resolveOutputDirectory(screen: String) throws -> URL {
        if let raw = ProcessInfo.processInfo.environment["OPPI_UI_VALIDATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-ui-validate", isDirectory: true)
            .appendingPathComponent(screen, isDirectory: true)
        return fallback
    }
}
