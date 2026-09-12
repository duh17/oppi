import CoreGraphics
import Foundation
import Testing
@testable import OppiDesktopCompanion

@Suite("DesktopCaptureSession")
@MainActor
struct DesktopCaptureSessionTests {
    @Test func captureOnceKeepsOnlyOneOutstandingCapture() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 11, title: "Notes")
        pickWindow(session, fake, surface)

        session.captureOnce()
        session.captureOnce()

        #expect(fake.captureCount == 1)
        #expect(session.isCaptureInFlight)
        #expect(session.still == nil)
    }

    @Test func cancelCaptureDiscardsPendingResult() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 12, title: "Safari")
        pickWindow(session, fake, surface)
        session.captureOnce()

        session.cancelCapture()
        fake.completePending(.success(makeStill(surface: surface)))

        #expect(!session.isCaptureInFlight)
        #expect(session.still == nil)
        #expect(session.failure == .cancelled)
    }

    @Test func lateCallbackAfterCancelIsDiscarded() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 13, title: "Mail")
        pickWindow(session, fake, surface)
        session.captureOnce()
        let staleStill = makeStill(surface: surface)

        session.cancelCapture()
        fake.completePending(.success(staleStill))

        #expect(session.still?.captureID != staleStill.captureID)
        #expect(session.still == nil)
        #expect(!session.isLivePreview)
    }

    @Test func selectionChangeDiscardsPendingResultAndOldStill() {
        let (session, fake) = makeHarness()
        let first = makeSurface(windowID: 21, title: "Code")
        let second = makeSurface(windowID: 22, title: "Preview")
        pickWindow(session, fake, first)
        session.captureOnce()
        let firstStill = makeStill(surface: first)
        fake.completePending(.success(firstStill))
        #expect(session.still?.captureID == firstStill.captureID)

        session.captureOnce()
        pickWindow(session, fake, second)
        fake.completePending(.success(makeStill(surface: first)))

        #expect(session.selection == second)
        #expect(session.still == nil)
        #expect(!session.isCaptureInFlight)
        #expect(session.stillLabel == nil)
    }

    @Test func permissionDeniedFailsWithoutCapture() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 31, title: "Maps")
        pickWindow(session, fake, surface)
        fake.availability = .permissionDenied

        session.captureOnce()

        #expect(fake.captureCount == 0)
        #expect(session.failure == .permissionDenied)
        #expect(session.still == nil)
        #expect(!session.isCaptureInFlight)
    }

    @Test func unavailableFailsWithoutCapture() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 32, title: "Calendar")
        pickWindow(session, fake, surface)
        fake.availability = .unavailable

        session.captureOnce()

        #expect(fake.captureCount == 0)
        #expect(session.failure == .unavailable)
        #expect(session.still == nil)
        #expect(!session.isCaptureInFlight)
    }

    @Test func clearInvalidatesStillAndPendingResult() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 41, title: "Terminal")
        pickWindow(session, fake, surface)
        session.captureOnce()
        let still = makeStill(surface: surface)
        fake.completePending(.success(still))
        #expect(session.still?.captureID == still.captureID)
        #expect(session.stillLabel == DesktopCaptureSession.stillCaption)

        session.captureOnce()
        session.clear()
        fake.completePending(.success(makeStill(surface: surface)))

        #expect(session.still == nil)
        #expect(session.stillLabel == nil)
        #expect(!session.isCaptureInFlight)
        #expect(session.failure == nil)
    }

    @Test func disappearingSelectionDoesNotSubstituteAnotherSurface() {
        let (session, fake) = makeHarness()
        let original = makeSurface(windowID: 51, title: "Original")
        let other = makeSurface(windowID: 52, title: "Other")
        pickWindow(session, fake, original)
        session.captureOnce()
        fake.completePending(.success(makeStill(surface: original)))

        fake.simulateSurfaceUnavailable(original)
        fake.simulateUserSelection(other)

        #expect(session.selection != other)
        #expect(session.selection == nil)
        #expect(session.still == nil)
        #expect(session.failure == .unavailable || session.failure == .surfaceSubstitutionRejected)
        #expect(!session.isLivePreview)
    }

    @Test func pickerUpdateWithoutPresentDoesNotSubstituteSurface() {
        let (session, fake) = makeHarness()
        let original = makeSurface(windowID: 61, title: "Keep")
        let substitute = makeSurface(windowID: 62, title: "Substitute")
        pickWindow(session, fake, original)

        fake.simulateUserSelection(substitute)

        #expect(session.selection == original)
        #expect(session.selection != substitute)
        #expect(session.failure == .surfaceSubstitutionRejected)
        #expect(session.still == nil)
    }

    @Test func screenshotManagerIsOneShotInMemoryAndDoesNotStartAStream() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiDesktopCompanion/ScreenCaptureKitDesktopCaptureService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("SCScreenshotManager.captureImage"))
        #expect(!source.contains("fileURL"))
        #expect(!source.contains("SCStream("))
        #expect(!source.contains("startCapture"))
        #expect(!source.contains("CGRequestScreenCaptureAccess"))
        #expect(!source.contains("com.apple.developer.persistent-content-capture"))
    }

    @Test func successfulCaptureIsLabeledStillNotLive() {
        let (session, fake) = makeHarness()
        let surface = makeSurface(windowID: 71, title: "Notes")
        pickWindow(session, fake, surface)
        session.captureOnce()
        let still = makeStill(surface: surface)
        fake.completePending(.success(still))

        #expect(session.still?.captureID == still.captureID)
        #expect(session.stillLabel == "Still—not live")
        #expect(session.still?.label == "Still—not live")
        #expect(session.still?.capturedAt == still.capturedAt)
        #expect(!session.isLivePreview)
        #expect(!session.isCaptureInFlight)
    }
}

@MainActor
private func makeHarness() -> (DesktopCaptureSession, FakeDesktopCaptureService) {
    let fake = FakeDesktopCaptureService()
    let session = DesktopCaptureSession(service: fake)
    return (session, fake)
}

@MainActor
private func pickWindow(
    _ session: DesktopCaptureSession,
    _ fake: FakeDesktopCaptureService,
    _ surface: CaptureSurface
) {
    session.selectWindow()
    fake.simulateUserSelection(surface)
}

private func makeSurface(windowID: UInt32, title: String) -> CaptureSurface {
    CaptureSurface(surfaceID: CaptureSurfaceID(windowID: windowID), title: title)
}

private func makeStill(surface: CaptureSurface) -> CapturedStill {
    CapturedStill(captureID: UUID(), surfaceID: surface.surfaceID, capturedAt: Date(), image: makePixel())
}

private func makePixel() -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = context.makeImage()
    else {
        fatalError("Unable to create a 1×1 test still")
    }
    return image
}

@MainActor
private final class FakeDesktopCaptureService: DesktopCaptureServicing {
    weak var delegate: DesktopCaptureServiceDelegate?
    var availability: CaptureAvailability = .ready
    private(set) var captureCount = 0
    private var pendingCompletion: (@MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void)?

    func presentWindowPicker() {}

    func captureStill(
        surface: CaptureSurface,
        completion: @escaping @MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void
    ) {
        captureCount += 1
        pendingCompletion = completion
    }

    func currentAvailability() -> CaptureAvailability {
        availability
    }

    func simulateUserSelection(_ surface: CaptureSurface) {
        delegate?.desktopCaptureServiceDidSelect(surface)
    }

    func simulateSurfaceUnavailable(_ surface: CaptureSurface) {
        delegate?.desktopCaptureServiceSurfaceBecameUnavailable(surface)
    }

    func completePending(_ result: Result<CapturedStill, DesktopCaptureFailure>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}
