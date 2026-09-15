import CoreGraphics
import Foundation

enum DesktopCaptureCopy {
    static let stillCaption = "Still—not live"
    static let localPreviewCaption = "Local live preview—not shared"
    static let previewStarting = "Starting local preview…"
    static let previewStopping = "Stopping preview…"
    static let previewStopped = "Preview stopped"
    static let previewUnavailable = "Preview unavailable"
    static let viewSessionCaption = "View session—not live delivery"
    static let viewGrantPending = "View session—waiting for this iPhone to claim. Not live delivery."
    static let viewGrantHint =
        "Off by default. Independent of still share. This is a view session, not live delivery, not shared live."
    static let viewGrantNone = "No view session."
    static let viewGrantNotBound = "View session is not granted to this device."
}

/// Identity of a single selected window. Capture never substitutes a different surface.
struct CaptureSurfaceID: Hashable, Sendable {
    let windowID: UInt32
}

struct CaptureSurface: Equatable, Sendable, Identifiable {
    var id: CaptureSurfaceID { surfaceID }
    let surfaceID: CaptureSurfaceID
    let title: String
}

/// In-memory still. Never treated as a live preview.
struct CapturedStill {
    let captureID: UUID
    let surfaceID: CaptureSurfaceID
    let capturedAt: Date
    let image: CGImage

    var label: String { DesktopCaptureCopy.stillCaption }
}

enum CaptureAvailability: Equatable, Sendable {
    case ready
    case permissionDenied
    case unavailable
    case unsupported
}

enum DesktopLocalPreviewState: Equatable, Sendable {
    case stopped
    case starting
    case live
    case stopping
    case unavailable
}

/// In-memory local preview frame. Never published to the still share gate.
struct DesktopPreviewFrame {
    let surfaceID: CaptureSurfaceID
    let capturedAt: Date
    let image: CGImage
}

enum DesktopCaptureFailure: Error, Equatable, Sendable {
    case permissionDenied
    case unavailable
    case unsupported
    case cancelled
    case surfaceSubstitutionRejected
    case captureFailed

    var userMessage: String {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is required to capture a still."
        case .unavailable:
            "The selected window is unavailable."
        case .unsupported:
            "Window capture is not supported on this Mac."
        case .cancelled:
            "Capture was cancelled."
        case .surfaceSubstitutionRejected:
            "The selected window is gone. Another window was not captured."
        case .captureFailed:
            "Capture failed."
        }
    }
}
