import XCTest

/// Sampling is opt-in, and Server Settings is the on-ramp: the host pill hides
/// Server Metrics while sampling is off. Turning it on there starts the server's
/// sampler and adds the pill item; the page then shows its own samples: process
/// cards from `GET /server/metrics`, host cards once a sample with host
/// readings exists. There is no Event Loop card.
@MainActor
final class ServerMetricsE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    func testServerMetricsShowsLiveServerSamples() {
        let switcher = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Current server:"))
            .firstMatch
        tap(switcher, named: "server switcher", timeout: 10)
        XCTAssertTrue(
            app.buttons["hostSwitcher.serverSettings"].waitForExistence(timeout: 5),
            "Host pill menu did not open"
        )
        XCTAssertFalse(
            app.buttons["hostSwitcher.serverMetrics"].exists,
            "Server Metrics must stay out of the pill while sampling is off"
        )
        tap(app.buttons["hostSwitcher.serverSettings"], named: "server settings", timeout: 5)
        XCTAssertTrue(app.navigationBars["Server Settings"].waitForExistence(timeout: 10), "Server settings did not open")

        let toggle = app.switches["server.serverMetrics.enabled"]
        for _ in 0..<8 where !(toggle.exists && toggle.isHittable) {
            app.swipeUp()
        }
        tap(toggle, named: "server metrics toggle", timeout: 10)

        tap(switcher, named: "server switcher", timeout: 10)
        tap(app.buttons["hostSwitcher.serverMetrics"], named: "server metrics", timeout: 5)

        XCTAssertTrue(
            app.navigationBars["Server Metrics"].waitForExistence(timeout: 10),
            "Server Metrics navigation title did not appear"
        )
        XCTAssertTrue(
            app.otherElements["server.metrics.card.processCpu"].waitForExistence(timeout: 15),
            "Process cards did not render from the server response"
        )
        XCTAssertFalse(
            app.otherElements["server.metrics.card.eventLoop"].exists,
            "Event Loop is collected for Grafana but not shown on the phone"
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
