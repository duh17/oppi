import XCTest
import UIKit

/// Visual capture harness for streaming markdown flicker.
///
/// This test writes frame PNGs and per-frame luminance/debug metrics to /tmp so
/// optimization runs can compare visual stability, not only apply duration.
@MainActor
final class StreamingFlickerCaptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Streaming flicker capture is simulator-only")
#endif
        continueAfterFailure = false
    }

    func testCaptureStreamingMarkdownFlicker() throws {
        app = XCUIApplication()
        app.launchArguments.append("--screenshot-preview")
        app.launchEnvironment["SCREENSHOT_SCREEN"] = "streaming-flicker"
        app.launch()

        let ready = app.descendants(matching: .any)["screenshot.ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 8), "Streaming flicker preview did not become ready")

        let outputDirectory = URL(fileURLWithPath: "/tmp/oppi-streaming-flicker", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let metricsElement = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "height=")).firstMatch
        let tickElement = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "tick=")).firstMatch
        XCTAssertTrue(tickElement.waitForExistence(timeout: 3), "Streaming tick overlay missing")

        var reportLines: [String] = []
        var previousStats: FrameStats?
        var maxAverageDelta = 0.0
        var maxDarkRatioDrop = 0.0
        var maxRenderedOverflow = 0.0
        var maxRenderedOverlap = 0.0
        var largeDeltaCount = 0

        for frameIndex in 0..<80 {
            let screenshot = app.screenshot()
            let frameURL = outputDirectory.appendingPathComponent(String(format: "frame-%03d.png", frameIndex))
            try screenshot.pngRepresentation.write(to: frameURL)

            let stats = try Self.frameStats(from: screenshot)
            var delta = 0.0
            var darkRatioDrop = 0.0
            if let previousStats {
                delta = stats.averageAbsoluteDelta(from: previousStats)
                darkRatioDrop = max(0, previousStats.darkRatio - stats.darkRatio)
                maxAverageDelta = max(maxAverageDelta, delta)
                maxDarkRatioDrop = max(maxDarkRatioDrop, darkRatioDrop)
                if delta > 18 || darkRatioDrop > 0.08 {
                    largeDeltaCount += 1
                }
            }
            previousStats = stats

            let debugLabel = metricsElement.exists ? metricsElement.label : "missing"
            if let overflow = Self.metricValue(named: "overflow", in: debugLabel) {
                maxRenderedOverflow = max(maxRenderedOverflow, overflow)
            }
            if let overlap = Self.metricValue(named: "overlap", in: debugLabel) {
                maxRenderedOverlap = max(maxRenderedOverlap, overlap)
            }

            let line = String(
                format: "frame=%03d tick='%@' debug='%@' luma=%.2f darkRatio=%.4f delta=%.2f darkDrop=%.4f",
                frameIndex,
                tickElement.exists ? tickElement.label : "missing",
                debugLabel,
                stats.averageLuma,
                stats.darkRatio,
                delta,
                darkRatioDrop
            )
            reportLines.append(line)

            Thread.sleep(forTimeInterval: 0.12)
        }

        let reportURL = outputDirectory.appendingPathComponent("report.txt")
        let summary = String(
            format: "maxAverageDelta=%.2f\nmaxDarkRatioDrop=%.4f\nmaxRenderedOverflow=%.1f\nmaxRenderedOverlap=%.1f\nlargeDeltaCount=%d\n",
            maxAverageDelta,
            maxDarkRatioDrop,
            maxRenderedOverflow,
            maxRenderedOverlap,
            largeDeltaCount
        )
        try (summary + reportLines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)

        let reportAttachment = XCTAttachment(contentsOfFile: reportURL)
        reportAttachment.name = "streaming-flicker-report"
        reportAttachment.lifetime = .keepAlways
        add(reportAttachment)

        let lastFrameURL = outputDirectory.appendingPathComponent("frame-079.png")
        if FileManager.default.fileExists(atPath: lastFrameURL.path) {
            let finalAttachment = XCTAttachment(contentsOfFile: lastFrameURL)
            finalAttachment.name = "streaming-flicker-final-frame"
            finalAttachment.lifetime = .keepAlways
            add(finalAttachment)
        }

        XCTAssertLessThanOrEqual(
            maxRenderedOverflow,
            1,
            "Streaming markdown rendered outside the assistant cell bounds; cached self-sizing is clipping the live tail. See \(reportURL.path) and simulator video."
        )
        XCTAssertLessThanOrEqual(
            maxRenderedOverlap,
            1,
            "Streaming markdown segments overlapped during live updates. See \(reportURL.path) and simulator video."
        )
    }

    private static func metricValue(named name: String, in label: String) -> Double? {
        guard let range = label.range(of: "\(name)=") else { return nil }
        let suffix = label[range.upperBound...]
        let token = suffix.split(separator: " ").first ?? Substring(suffix)
        return Double(token)
    }

    private struct FrameStats {
        let samples: [UInt8]
        let averageLuma: Double
        let darkRatio: Double

        func averageAbsoluteDelta(from previous: FrameStats) -> Double {
            let count = min(samples.count, previous.samples.count)
            guard count > 0 else { return 0 }
            var sum = 0
            for index in 0..<count {
                sum += abs(Int(samples[index]) - Int(previous.samples[index]))
            }
            return Double(sum) / Double(count)
        }
    }

    private static func frameStats(from screenshot: XCUIScreenshot) throws -> FrameStats {
        guard let image = UIImage(data: screenshot.pngRepresentation),
              let cgImage = image.cgImage else {
            throw XCTSkip("Could not decode screenshot PNG")
        }

        let width = 96
        let height = 160
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create screenshot sampling context")
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var samples: [UInt8] = []
        samples.reserveCapacity(width * height)
        var lumaSum = 0.0
        var darkCount = 0
        var count = 0

        // Skip the top overlay and bottom home-indicator area. The remaining
        // region is where assistant text clipping/blanking is visible.
        for y in 28..<(height - 8) {
            for x in 4..<(width - 4) {
                let offset = (y * width + x) * 4
                let r = Double(pixels[offset])
                let g = Double(pixels[offset + 1])
                let b = Double(pixels[offset + 2])
                let luma = UInt8(max(0, min(255, 0.299 * r + 0.587 * g + 0.114 * b)))
                samples.append(luma)
                lumaSum += Double(luma)
                if luma < 42 { darkCount += 1 }
                count += 1
            }
        }

        return FrameStats(
            samples: samples,
            averageLuma: count > 0 ? lumaSum / Double(count) : 0,
            darkRatio: count > 0 ? Double(darkCount) / Double(count) : 0
        )
    }
}
