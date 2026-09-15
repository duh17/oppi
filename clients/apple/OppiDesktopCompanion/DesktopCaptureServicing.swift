import Foundation

@MainActor
protocol DesktopCaptureServiceDelegate: AnyObject {
    func desktopCaptureServiceDidSelect(_ surface: CaptureSurface)
    func desktopCaptureServiceDidCancelPicker()
    func desktopCaptureServiceDidFail(_ failure: DesktopCaptureFailure)
    func desktopCaptureServiceSurfaceBecameUnavailable(_ surface: CaptureSurface)
}

@MainActor
protocol DesktopLocalPreviewHandling: AnyObject {
    func localPreviewDidConfirmStart(generation: UInt64)
    func localPreviewDidDeliverFrame(_ frame: DesktopPreviewFrame, generation: UInt64)
    func localPreviewDidStop(generation: UInt64, failure: DesktopCaptureFailure?)
    func localPreviewDidFail(generation: UInt64, failure: DesktopCaptureFailure)
}

@MainActor
protocol DesktopCaptureServicing: AnyObject {
    var delegate: DesktopCaptureServiceDelegate? { get set }

    func presentWindowPicker()
    func captureStill(
        surface: CaptureSurface,
        completion: @escaping @MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void
    )
    func startLocalPreview(
        surface: CaptureSurface,
        generation: UInt64,
        handler: any DesktopLocalPreviewHandling
    )
    func stopLocalPreview(generation: UInt64)
    func currentAvailability() -> CaptureAvailability
}
