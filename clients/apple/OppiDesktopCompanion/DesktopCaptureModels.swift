import CoreGraphics
import Foundation

enum DesktopCaptureCopy {
    static let stillCaption = "Still—not live"
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
