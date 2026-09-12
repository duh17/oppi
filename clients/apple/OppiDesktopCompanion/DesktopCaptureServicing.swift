import Foundation

@MainActor
protocol DesktopCaptureServiceDelegate: AnyObject {
    func desktopCaptureServiceDidSelect(_ surface: CaptureSurface)
    func desktopCaptureServiceDidCancelPicker()
    func desktopCaptureServiceDidFail(_ failure: DesktopCaptureFailure)
    func desktopCaptureServiceSurfaceBecameUnavailable(_ surface: CaptureSurface)
}

@MainActor
protocol DesktopCaptureServicing: AnyObject {
    var delegate: DesktopCaptureServiceDelegate? { get set }

    func presentWindowPicker()
    func captureStill(
        surface: CaptureSurface,
        completion: @escaping @MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void
    )
    func currentAvailability() -> CaptureAvailability
}
