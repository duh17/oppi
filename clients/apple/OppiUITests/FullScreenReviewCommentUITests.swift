import CoreGraphics
import ImageIO
import XCTest

@MainActor
final class FullScreenReviewCommentUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Full-screen review comment UI test is simulator-only")
#endif
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testFullScreenCodeSelectionShowsNativeActionBar() throws {
        launchReviewCommentHarness()
        selectHarnessCodeRange()

        XCTAssertFalse(
            app.buttons["review-comment.selection-bar"].waitForExistence(timeout: 1),
            "Full-screen text selection should use the native edit menu only, not a standalone Comment bar"
        )

        let commentAction = try XCTUnwrap(
            waitForActionBarElement(named: "Comment", timeout: 5),
            "Native selection action bar did not expose Comment"
        )
        let copyAction = try XCTUnwrap(
            waitForActionBarElement(named: "Copy", timeout: 2),
            "Native selection action bar did not expose Copy"
        )
        XCTAssertTrue(commentAction.exists)
        XCTAssertTrue(copyAction.exists)
        saveScreenshot(name: "fullscreen-review-comment-action-bar")

        tapElement(commentAction)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-comment.inline-composer"].waitForExistence(timeout: 5),
            "Native Comment action did not open the inline comment composer"
        )
        saveScreenshot(name: "fullscreen-review-comment-inline-composer")
    }

    func testFullScreenCodeSelectionPaintsVisibleHighlight() throws {
        launchReviewCommentHarness()
        let beforeSelection = app.screenshot()

        selectHarnessCodeRange()
        _ = waitForActionBarElement(named: "Comment", timeout: 5)
        let afterSelection = app.screenshot()
        saveScreenshot(beforeSelection, name: "fullscreen-review-comment-before-selection")
        saveScreenshot(afterSelection, name: "fullscreen-review-comment-after-selection")

        let addedTintPixels = try addedSelectionTintPixelCount(before: beforeSelection, after: afterSelection)
        XCTAssertGreaterThan(
            addedTintPixels,
            18_000,
            "Selected text should paint a visible blue highlight, not just blue grab handles. Added tint pixels: \(addedTintPixels)."
        )
    }

    private func launchReviewCommentHarness() {
        app = XCUIApplication()
        app.launchArguments.append(contentsOf: [
            "--fullscreen-review-comment-harness",
            "-ApplePersistenceIgnoreState",
            "YES",
        ])
        app.launchEnvironment["PI_FULLSCREEN_REVIEW_COMMENT_HARNESS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["harness.ready"].waitForExistence(timeout: 10),
            "Full-screen review comment harness did not become ready"
        )
    }

    private func selectHarnessCodeRange() {
        let selectButton = app.buttons["harness.reviewComment.select"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5), "Select-code harness control did not appear")
        selectButton.tap()
    }

    private func waitForActionBarElement(named title: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = [
                app.buttons[title],
                app.menuItems[title],
                app.staticTexts[title],
                app.descendants(matching: .any)[title],
            ]
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func addedSelectionTintPixelCount(before: XCUIScreenshot, after: XCUIScreenshot) throws -> Int {
        let beforeImage = try rgbaImage(from: before.pngRepresentation)
        let afterImage = try rgbaImage(from: after.pngRepresentation)
        XCTAssertEqual(beforeImage.width, afterImage.width)
        XCTAssertEqual(beforeImage.height, afterImage.height)

        let pixelCount = min(beforeImage.bytes.count, afterImage.bytes.count) / 4
        var count = 0
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            let beforeR = Int(beforeImage.bytes[offset])
            let beforeG = Int(beforeImage.bytes[offset + 1])
            let beforeB = Int(beforeImage.bytes[offset + 2])
            let afterR = Int(afterImage.bytes[offset])
            let afterG = Int(afterImage.bytes[offset + 1])
            let afterB = Int(afterImage.bytes[offset + 2])
            let afterA = Int(afterImage.bytes[offset + 3])

            let beforeAlreadyBlue = beforeB > beforeR + 18 && beforeB > beforeG + 8
            let afterSelectionBlue = afterB > afterR + 18 && afterB > afterG + 8
            let shiftedTowardBlue = afterB - beforeB >= 8 || beforeR - afterR >= 18
            if afterA > 200, afterSelectionBlue, !beforeAlreadyBlue, shiftedTowardBlue {
                count += 1
            }
        }
        return count
    }

    private struct RGBAImage {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private func rgbaImage(from pngData: Data) throws -> RGBAImage {
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(pngData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBAImage(width: width, height: height, bytes: bytes)
    }

    private func saveScreenshot(name: String) {
        saveScreenshot(app.screenshot(), name: name)
    }

    private func saveScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: outputURL, options: .atomic)
    }
}
