import Foundation

@MainActor
@Observable
final class DesktopCaptureSession {
    static let stillCaption = DesktopCaptureCopy.stillCaption

    private(set) var selection: CaptureSurface?
    private(set) var still: CapturedStill?
    private(set) var failure: DesktopCaptureFailure?
    private(set) var availability: CaptureAvailability = .ready
    private(set) var isCaptureInFlight = false
    private(set) var isPickerPresented = false

    var stillLabel: String? { still == nil ? nil : Self.stillCaption }
    var isLivePreview: Bool { false }
    var canCapture: Bool {
        selection != nil && !isCaptureInFlight && availability == .ready
    }
    var canClear: Bool { still != nil || isCaptureInFlight }
    var canCancel: Bool { isCaptureInFlight }

    private let service: any DesktopCaptureServicing
    /// Token for the single outstanding capture. Late callbacks with a stale token are discarded.
    private var inFlightToken: UInt64 = 0
    private var nextTokenValue: UInt64 = 1

    init(service: any DesktopCaptureServicing) {
        self.service = service
        self.service.delegate = self
    }

    func selectWindow() {
        isPickerPresented = true
        failure = nil
        service.presentWindowPicker()
    }

    func captureOnce() {
        guard !isCaptureInFlight else { return }
        refreshAvailability()
        switch availability {
        case .ready:
            break
        case .permissionDenied:
            failure = .permissionDenied
            return
        case .unavailable:
            failure = .unavailable
            return
        case .unsupported:
            failure = .unsupported
            return
        }
        guard let surface = selection else { return }

        failure = nil
        let token = nextTokenValue
        nextTokenValue += 1
        inFlightToken = token
        isCaptureInFlight = true
        service.captureStill(surface: surface) { [weak self] result in
            self?.finishCapture(token: token, expectedSurfaceID: surface.surfaceID, result: result)
        }
    }

    func cancelCapture() {
        guard isCaptureInFlight else { return }
        invalidatePendingCapture()
        failure = .cancelled
    }

    func clear() {
        invalidatePendingCapture()
        still = nil
        failure = nil
    }

    func refreshAvailability() {
        availability = service.currentAvailability()
    }

    private func invalidatePendingCapture() {
        isCaptureInFlight = false
        inFlightToken = 0
    }

    private func applyUserSelection(_ surface: CaptureSurface) {
        invalidatePendingCapture()
        still = nil
        selection = surface
        failure = nil
    }

    private func finishCapture(
        token: UInt64,
        expectedSurfaceID: CaptureSurfaceID,
        result: Result<CapturedStill, DesktopCaptureFailure>
    ) {
        guard isCaptureInFlight, token == inFlightToken else { return }
        isCaptureInFlight = false
        inFlightToken = 0

        switch result {
        case .success(let captured):
            guard selection?.surfaceID == expectedSurfaceID, captured.surfaceID == expectedSurfaceID else {
                still = nil
                failure = .surfaceSubstitutionRejected
                return
            }
            still = captured
            failure = nil
        case .failure(let error):
            failure = error
        }
    }
}

extension DesktopCaptureSession: DesktopCaptureServiceDelegate {
    func desktopCaptureServiceDidSelect(_ surface: CaptureSurface) {
        if isPickerPresented {
            isPickerPresented = false
            applyUserSelection(surface)
            return
        }
        if selection?.surfaceID == surface.surfaceID {
            selection = surface
            return
        }
        // Unsolicited different surface: never present it as the selection or a new still.
        invalidatePendingCapture()
        still = nil
        failure = .surfaceSubstitutionRejected
    }

    func desktopCaptureServiceDidCancelPicker() {
        isPickerPresented = false
    }

    func desktopCaptureServiceDidFail(_ failure: DesktopCaptureFailure) {
        isPickerPresented = false
        invalidatePendingCapture()
        self.failure = failure
    }

    func desktopCaptureServiceSurfaceBecameUnavailable(_ surface: CaptureSurface) {
        guard selection?.surfaceID == surface.surfaceID else { return }
        isPickerPresented = false
        invalidatePendingCapture()
        still = nil
        selection = nil
        failure = .unavailable
    }
}
