import XCTest

/// Server Metrics opens from the host pill. Sampling is opt-in, so a fresh
/// server shows the off state; Turn On starts the server's sampler, and the
/// page then shows its own samples: process cards from `GET /server/metrics`,
/// host cards once a sample with host readings exists.
@MainActor
final class ServerMetricsE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    func testServerMetricsShowsLiveServerSamples() {
        let switcher = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:"))
            .firstMatch
        tap(switcher, named: "server switcher", timeout: 10)
        tap(app.buttons["hostSwitcher.serverMetrics"], named: "server metrics", timeout: 5)

        XCTAssertTrue(
            app.navigationBars["Server Metrics"].waitForExistence(timeout: 10),
            "Server Metrics navigation title did not appear"
        )
        tap(app.buttons["server.metrics.turnOn"], named: "turn on server metrics", timeout: 10)
        XCTAssertTrue(
            app.otherElements["server.metrics.card.processCpu"].waitForExistence(timeout: 15),
            "Process cards did not render from the server response"
        )
        // The sampler writes every 30s by default and the page refreshes on the
        // same cadence, so the first host sample can take two intervals.
        let hostCPU = app.otherElements["server.metrics.card.hostCpu"]
        XCTAssertTrue(hostCPU.waitForExistence(timeout: 75), "Host cards never received a sample")
        XCTAssertFalse(
            (hostCPU.value as? String ?? "").hasPrefix("—"),
            "Host CPU card has no current value"
        )

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "server-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(
            to: directory.appendingPathComponent("server-metrics.png"),
            options: .atomic
        )
    }
}
