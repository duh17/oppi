import CoreGraphics
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
    private(set) var isLocalShareEnabled = false
    private(set) var isRemoteViewEnabled = false
    private(set) var previewState: DesktopLocalPreviewState = .stopped
    private(set) var previewFrame: CGImage?

    let shareGate: DesktopStillShareGate

    var stillLabel: String? { still == nil ? nil : Self.stillCaption }
    var previewLabel: String? {
        previewState == .live ? DesktopCaptureCopy.localPreviewCaption : nil
    }
    var previewStatusText: String {
        switch previewState {
        case .stopped: DesktopCaptureCopy.previewStopped
        case .starting: DesktopCaptureCopy.previewStarting
        case .live: DesktopCaptureCopy.localPreviewCaption
        case .stopping: DesktopCaptureCopy.previewStopping
        case .unavailable: DesktopCaptureCopy.previewUnavailable
        }
    }
    var isLivePreview: Bool { previewState == .live }
    var isLocalPreviewActive: Bool {
        switch previewState {
        case .starting, .live, .stopping: true
        case .stopped, .unavailable: false
        }
    }
    var canCapture: Bool {
        selection != nil && !isCaptureInFlight && availability == .ready && !isLocalPreviewActive
    }
    var canClear: Bool {
        still != nil || isCaptureInFlight || isLocalPreviewActive || previewFrame != nil
    }
    var canStartLocalPreview: Bool {
        selection != nil && !isCaptureInFlight && !isLocalPreviewActive && availability == .ready
    }
    var canStopLocalPreview: Bool {
        previewState == .starting || previewState == .live
    }
    var canCancel: Bool { isCaptureInFlight }
    var canEnableLocalShare: Bool { still != nil && !isLocalShareEnabled }
    var canRevokeLocalShare: Bool { isLocalShareEnabled }
    var canEnableRemoteView: Bool { still != nil && !isRemoteViewEnabled }
    var canRevokeRemoteView: Bool { isRemoteViewEnabled }
    var sharedCaptureID: UUID? { isLocalShareEnabled ? still?.captureID : nil }

    private let service: any DesktopCaptureServicing
    /// Token for the single outstanding capture. Late callbacks with a stale token are discarded.
    private var inFlightToken: UInt64 = 0
    private var nextTokenValue: UInt64 = 1
    /// Current preview generation. Late start completions and frames with a stale value are discarded.
    private var previewGeneration: UInt64 = 0
    private var previewStartConfirmed = false
    private var stoppingGeneration: UInt64?
    /// Terminal state to apply when the in-flight stop completes (or a racing fail arrives).
    private var pendingTerminalPreviewState: DesktopLocalPreviewState?

    init(
        service: any DesktopCaptureServicing,
        shareGate: DesktopStillShareGate = DesktopStillShareGate()
    ) {
        self.service = service
        self.shareGate = shareGate
        self.service.delegate = self
    }

    func selectWindow() {
        isPickerPresented = true
        failure = nil
        service.presentWindowPicker()
    }

    func captureOnce() {
        guard !isCaptureInFlight, !isLocalPreviewActive else { return }
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

    func startLocalPreview() {
        guard canStartLocalPreview else { return }
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
        previewStartConfirmed = false
        previewFrame = nil
        previewGeneration += 1
        let generation = previewGeneration
        previewState = .starting
        service.startLocalPreview(surface: surface, generation: generation, handler: self)
    }

    func stopLocalPreview() {
        guard canStopLocalPreview else { return }
        beginStopping(pending: .stopped)
    }

    func clear() {
        invalidatePendingCapture()
        haltLocalPreview(to: .stopped)
        revokeAllGrants()
        still = nil
        failure = nil
    }

    func enableLocalShare() {
        guard let still else { return }
        guard let pngData = DesktopStillPNG.encode(still.image) else { return }
        isLocalShareEnabled = true
        shareGate.publish(
            DesktopSharedStill(
                captureID: still.captureID,
                surfaceID: still.surfaceID,
                surfaceTitle: selection?.title ?? "Window",
                capturedAt: still.capturedAt,
                width: still.image.width,
                height: still.image.height,
                pngData: pngData,
                caption: DesktopCaptureCopy.stillCaption
            )
        )
    }

    func revokeLocalShare() {
        isLocalShareEnabled = false
        shareGate.publish(nil)
    }

    func enableRemoteView() {
        guard let still else { return }
        guard let pngData = DesktopStillPNG.encode(still.image) else { return }
        isRemoteViewEnabled = true
        shareGate.setRemoteView(
            granted: true,
            still: DesktopSharedStill(
                captureID: still.captureID,
                surfaceID: still.surfaceID,
                surfaceTitle: selection?.title ?? "Window",
                capturedAt: still.capturedAt,
                width: still.image.width,
                height: still.image.height,
                pngData: pngData,
                caption: DesktopCaptureCopy.stillCaption
            )
        )
    }

    func revokeRemoteView() {
        isRemoteViewEnabled = false
        shareGate.setRemoteView(granted: false, still: nil)
    }

    private func revokeAllGrants() {
        revokeLocalShare()
        revokeRemoteView()
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
        haltLocalPreview(to: .stopped)
        revokeAllGrants()
        still = nil
        selection = surface
        failure = nil
    }

    private func haltLocalPreview(to newState: DesktopLocalPreviewState) {
        switch previewState {
        case .starting, .live, .stopping:
            beginStopping(pending: newState)
        case .stopped, .unavailable:
            previewStartConfirmed = false
            previewFrame = nil
            stoppingGeneration = nil
            pendingTerminalPreviewState = nil
            previewState = newState
        }
    }

    /// Stay in `.stopping` until stop completes so Clear/reselect cannot start a new stream.
    private func beginStopping(pending terminal: DesktopLocalPreviewState) {
        if previewState == .stopping {
            pendingTerminalPreviewState = mergedTerminalPreviewState(
                pendingTerminalPreviewState,
                terminal
            )
            previewStartConfirmed = false
            previewFrame = nil
            return
        }
        let generation = previewGeneration
        previewGeneration += 1
        previewStartConfirmed = false
        previewFrame = nil
        stoppingGeneration = generation
        pendingTerminalPreviewState = terminal
        previewState = .stopping
        service.stopLocalPreview(generation: generation)
    }

    private func mergedTerminalPreviewState(
        _ current: DesktopLocalPreviewState?,
        _ next: DesktopLocalPreviewState
    ) -> DesktopLocalPreviewState {
        if current == .unavailable || next == .unavailable {
            return .unavailable
        }
        return next
    }

    private func applyPreviewTerminal(failure: DesktopCaptureFailure?) {
        let pending = pendingTerminalPreviewState
        pendingTerminalPreviewState = nil
        stoppingGeneration = nil
        previewStartConfirmed = false
        previewFrame = nil
        if failure == .unavailable || pending == .unavailable {
            previewState = .unavailable
        } else {
            previewState = pending ?? .stopped
        }
        if let failure {
            self.failure = failure
        }
    }

    private func promotePreviewIfReady() {
        guard previewState == .starting, previewStartConfirmed, previewFrame != nil else { return }
        previewState = .live
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
                revokeAllGrants()
                still = nil
                failure = .surfaceSubstitutionRejected
                return
            }
            revokeAllGrants()
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
        if selection != nil {
            haltLocalPreview(to: .stopped)
        }
        revokeAllGrants()
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
        haltLocalPreview(to: .unavailable)
        revokeAllGrants()
        still = nil
        selection = nil
        failure = .unavailable
    }
}

extension DesktopCaptureSession: DesktopLocalPreviewHandling {
    func localPreviewDidConfirmStart(generation: UInt64) {
        guard generation == previewGeneration, previewState == .starting else { return }
        previewStartConfirmed = true
        promotePreviewIfReady()
    }

    func localPreviewDidDeliverFrame(_ frame: DesktopPreviewFrame, generation: UInt64) {
        guard generation == previewGeneration else { return }
        guard previewState == .starting || previewState == .live else { return }
        guard selection?.surfaceID == frame.surfaceID else {
            haltLocalPreview(to: .stopped)
            failure = .surfaceSubstitutionRejected
            return
        }
        previewFrame = frame.image
        promotePreviewIfReady()
    }

    func localPreviewDidStop(generation: UInt64, failure: DesktopCaptureFailure?) {
        guard previewState == .stopping, stoppingGeneration == generation else { return }
        applyPreviewTerminal(failure: failure)
    }

    func localPreviewDidFail(generation: UInt64, failure: DesktopCaptureFailure) {
        // Concurrent didStopWithError can enqueue fail() after stop advanced generation.
        // Accept that terminal fail once so the session cannot stay stuck in `.stopping`.
        if previewState == .stopping, stoppingGeneration == generation {
            applyPreviewTerminal(failure: failure)
            return
        }
        guard generation == previewGeneration else { return }
        guard previewState == .starting || previewState == .live else { return }
        previewGeneration += 1
        previewStartConfirmed = false
        previewFrame = nil
        stoppingGeneration = nil
        pendingTerminalPreviewState = nil
        previewState = failure == .unavailable ? .unavailable : .stopped
        self.failure = failure
        service.stopLocalPreview(generation: generation)
    }
}
