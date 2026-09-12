import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immutable PNG snapshot of the currently shared still. Fetch never recaptures.
struct DesktopSharedStill: Sendable, Equatable {
    let captureID: UUID
    let surfaceID: CaptureSurfaceID
    let surfaceTitle: String
    let capturedAt: Date
    let width: Int
    let height: Int
    let pngData: Data
    let caption: String
}

enum DesktopStillShareFetchFailure: Error, Equatable, Sendable {
    case sharingDisabled
    case staleCaptureID
}

/// Default-off share gate. Local presence is not a view grant.
final class DesktopStillShareGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shared: DesktopSharedStill?

    func publish(_ still: DesktopSharedStill?) {
        lock.lock()
        shared = still
        lock.unlock()
    }

    func current() -> DesktopSharedStill? {
        lock.lock()
        defer { lock.unlock() }
        return shared
    }

    func fetch(captureID: UUID) -> Result<DesktopSharedStill, DesktopStillShareFetchFailure> {
        guard let shared = current() else {
            return .failure(.sharingDisabled)
        }
        guard shared.captureID == captureID else {
            return .failure(.staleCaptureID)
        }
        return .success(shared)
    }
}

enum DesktopStillPNG {
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

enum DesktopStillShareHTTP {
    static let captureID = "X-Oppi-Capture-ID"
    static let surfaceWindowID = "X-Oppi-Surface-Window-ID"
    static let surfaceTitle = "X-Oppi-Surface-Title"
    static let capturedAt = "X-Oppi-Captured-At"
    static let width = "X-Oppi-Width"
    static let height = "X-Oppi-Height"
    static let caption = "X-Oppi-Caption"

    static func date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func headerTitle(_ title: String) -> String {
        let collapsed = title
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Window" : collapsed
    }
}

protocol DesktopOwnerSocketPeerAuthorizing: Sendable {
    func isAuthorized(uid: uid_t) -> Bool
}

struct SameUserDesktopOwnerSocketPeerAuthorizer: DesktopOwnerSocketPeerAuthorizing {
    func isAuthorized(uid: uid_t) -> Bool {
        uid == getuid()
    }
}
