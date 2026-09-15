import CoreGraphics
import Foundation
@testable import Oppi

func appleClientRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@MainActor
func makeHarness() -> (DesktopCaptureSession, FakeDesktopCaptureService) {
    let fake = FakeDesktopCaptureService()
    let session = DesktopCaptureSession(service: fake)
    return (session, fake)
}

@MainActor
func pickWindow(
    _ session: DesktopCaptureSession,
    _ fake: FakeDesktopCaptureService,
    _ surface: CaptureSurface
) {
    session.selectWindow()
    fake.simulateUserSelection(surface)
}

func makeSurface(windowID: UInt32, title: String) -> CaptureSurface {
    CaptureSurface(surfaceID: CaptureSurfaceID(windowID: windowID), title: title)
}

func makeStill(surface: CaptureSurface) -> CapturedStill {
    CapturedStill(captureID: UUID(), surfaceID: surface.surfaceID, capturedAt: Date(), image: makePixel())
}

func makePixel(red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0) -> CGImage {
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
        )
    else {
        fatalError("Unable to create a 1×1 test image")
    }
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let image = context.makeImage() else {
        fatalError("Unable to create a 1×1 test image")
    }
    return image
}

@MainActor
final class FakeDesktopCaptureService: DesktopCaptureServicing {
    weak var delegate: DesktopCaptureServiceDelegate?
    var availability: CaptureAvailability = .ready
    private(set) var captureCount = 0
    private(set) var previewStartCount = 0
    private(set) var previewStopCount = 0
    private(set) var lastPreviewSurface: CaptureSurface?
    private(set) var lastPreviewGeneration: UInt64?
    private(set) var lastStopGeneration: UInt64?
    private var pendingCompletion: (@MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void)?
    private weak var previewHandler: DesktopLocalPreviewHandling?

    func presentWindowPicker() {}

    func captureStill(
        surface: CaptureSurface,
        completion: @escaping @MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void
    ) {
        captureCount += 1
        pendingCompletion = completion
    }

    func startLocalPreview(
        surface: CaptureSurface,
        generation: UInt64,
        handler: any DesktopLocalPreviewHandling
    ) {
        previewStartCount += 1
        lastPreviewSurface = surface
        lastPreviewGeneration = generation
        previewHandler = handler
    }

    func stopLocalPreview(generation: UInt64) {
        previewStopCount += 1
        lastStopGeneration = generation
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

    func simulateDidFail(_ failure: DesktopCaptureFailure) {
        delegate?.desktopCaptureServiceDidFail(failure)
    }

    func completePending(_ result: Result<CapturedStill, DesktopCaptureFailure>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }

    func confirmPreviewStart(generation: UInt64? = nil) {
        let gen = generation ?? lastPreviewGeneration ?? 0
        previewHandler?.localPreviewDidConfirmStart(generation: gen)
    }

    func deliverPreviewFrame(
        _ image: CGImage,
        surfaceID: CaptureSurfaceID? = nil,
        generation: UInt64? = nil
    ) {
        let gen = generation ?? lastPreviewGeneration ?? 0
        let surface = surfaceID ?? lastPreviewSurface?.surfaceID ?? CaptureSurfaceID(windowID: 0)
        previewHandler?.localPreviewDidDeliverFrame(
            DesktopPreviewFrame(surfaceID: surface, capturedAt: Date(), image: image),
            generation: gen
        )
    }

    func failPreview(_ failure: DesktopCaptureFailure, generation: UInt64? = nil) {
        let gen = generation ?? lastPreviewGeneration ?? 0
        previewHandler?.localPreviewDidFail(generation: gen, failure: failure)
    }

    func completePreviewStop(failure: DesktopCaptureFailure? = nil, generation: UInt64? = nil) {
        let gen = generation ?? lastStopGeneration ?? lastPreviewGeneration ?? 0
        previewHandler?.localPreviewDidStop(generation: gen, failure: failure)
    }
}
