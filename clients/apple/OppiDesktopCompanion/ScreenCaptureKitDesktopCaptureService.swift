import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiDesktopCompanion",
    category: "ScreenCapture"
)

/// ScreenCaptureKit one-shot stills. In-memory `CGImage` only — no stream, disk, or encode.
/// Debug tests must inject a fake; they must not instantiate this type.
@MainActor
final class ScreenCaptureKitDesktopCaptureService: NSObject, DesktopCaptureServicing {
    weak var delegate: DesktopCaptureServiceDelegate?

    private var selectedFilter: SCContentFilter?
    private var selectedSurface: CaptureSurface?
    private var didAddObserver = false

    func presentWindowPicker() {
        let picker = SCContentSharingPicker.shared
        if !didAddObserver {
            picker.add(self)
            didAddObserver = true
        }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.configuration = configuration
        picker.isActive = true
        picker.present(using: .window)
    }

    func captureStill(
        surface: CaptureSurface,
        completion: @escaping @MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void
    ) {
        guard
            let filter = selectedFilter,
            let selected = selectedSurface,
            selected.surfaceID == surface.surfaceID
        else {
            completion(.failure(.unavailable))
            return
        }

        let windows = filter.includedWindows
        guard windows.count == 1, let window = windows.first else {
            completion(.failure(.unavailable))
            return
        }
        guard window.windowID == surface.surfaceID.windowID else {
            completion(.failure(.surfaceSubstitutionRejected))
            return
        }

        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int((filter.contentRect.width * scale).rounded(.up))
        let height = Int((filter.contentRect.height * scale).rounded(.up))
        if width > 0 {
            configuration.width = width
        }
        if height > 0 {
            configuration.height = height
        }
        configuration.showsCursor = false
        configuration.capturesAudio = false

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(Self.mapError(error)))
                    return
                }
                guard let image else {
                    completion(.failure(.captureFailed))
                    return
                }
                completion(
                    .success(
                        CapturedStill(
                            captureID: UUID(),
                            surfaceID: surface.surfaceID,
                            capturedAt: Date(),
                            image: image
                        )
                    )
                )
            }
        }
    }

    func currentAvailability() -> CaptureAvailability {
        if CGPreflightScreenCaptureAccess() {
            return .ready
        }
        return .permissionDenied
    }

    private func handlePickedFilter(_ filter: SCContentFilter) {
        let windows = filter.includedWindows
        guard windows.count == 1, let window = windows.first else {
            selectedFilter = nil
            selectedSurface = nil
            delegate?.desktopCaptureServiceDidFail(.unavailable)
            return
        }

        let trimmedTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let surface = CaptureSurface(
            surfaceID: CaptureSurfaceID(windowID: window.windowID),
            title: trimmedTitle.isEmpty ? "Window" : trimmedTitle
        )
        selectedFilter = filter
        selectedSurface = surface
        delegate?.desktopCaptureServiceDidSelect(surface)
    }

    nonisolated private static func mapError(_ error: Error) -> DesktopCaptureFailure {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain,
              let code = SCStreamError.Code(rawValue: nsError.code)
        else {
            return .captureFailed
        }
        switch code {
        case .userDeclined, .missingEntitlements:
            return .permissionDenied
        case .noCaptureSource, .noWindowList, .noDisplayList,
             .failedApplicationConnectionInvalid, .failedApplicationConnectionInterrupted,
             .failedNoMatchingApplicationContext:
            return .unavailable
        case .userStopped:
            return .cancelled
        default:
            return .captureFailed
        }
    }
}

/// ScreenCaptureKit delivers picker callbacks off the main actor with a non-Sendable filter.
/// The filter is treated as exclusively owned after `didUpdateWith`.
private struct TransferredContentFilter: @unchecked Sendable {
    let filter: SCContentFilter
}

extension ScreenCaptureKitDesktopCaptureService: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            self.delegate?.desktopCaptureServiceDidCancelPicker()
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let transferred = TransferredContentFilter(filter: filter)
        Task { @MainActor in
            self.handlePickedFilter(transferred.filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        let mapped = Self.mapError(error)
        Task { @MainActor in
            logger.error("Content sharing picker failed: \(message, privacy: .public)")
            self.delegate?.desktopCaptureServiceDidFail(mapped)
        }
    }
}
