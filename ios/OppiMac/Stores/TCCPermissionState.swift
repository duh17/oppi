import Foundation
import ApplicationServices
import CoreGraphics
import UserNotifications
import OSLog

private let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "TCCPermissionState")

/// Tracks macOS TCC (Transparency, Consent, and Control) permission grants.
///
/// The Oppi Mac app spawns Node.js as a child process. That child inherits
/// the parent app's TCC grants, so these permissions directly control what
/// the agent can access on this Mac.
@MainActor @Observable
final class TCCPermissionState {

    // MARK: - Types

    enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
        case fullDiskAccess
        case accessibility
        case screenRecording
        case notifications

        var id: String { rawValue }
    }

    enum PermissionStatus: Sendable, Equatable {
        case granted
        case denied
        case unknown
    }

    struct Permission: Identifiable, Sendable {
        let kind: PermissionKind
        let name: String
        let description: String
        let required: Bool
        var status: PermissionStatus

        var id: String { kind.rawValue }
    }

    #if DEBUG
    /// Test-only: override a permission status without calling OS APIs.
    func _setPermissionStatusForTesting(kind: PermissionKind, status: PermissionStatus) {
        if let i = permissions.firstIndex(where: { $0.kind == kind }) {
            permissions[i].status = status
        }
    }
    #endif

    // MARK: - Public state

    private(set) var permissions: [Permission] = PermissionKind.allCases.map { kind in
        Permission(
            kind: kind,
            name: kind.displayName,
            description: kind.displayDescription,
            required: kind.isRequired,
            status: .unknown
        )
    }

    /// True when all required permissions (FDA) are granted.
    var requiredGranted: Bool {
        permissions
            .filter(\.required)
            .allSatisfy { $0.status == .granted }
    }

    /// Human-readable summary, e.g. "1/1 required" or "0/1 required — action needed".
    var summary: String {
        let required = permissions.filter(\.required)
        let grantedCount = required.filter { $0.status == .granted }.count
        let total = required.count
        if grantedCount == total {
            return "\(grantedCount)/\(total) required"
        }
        return "\(grantedCount)/\(total) required — action needed"
    }

    // MARK: - Checking

    /// Re-check all permissions. Call on app launch and when returning from System Settings.
    func refresh() async {
        logger.debug("Refreshing TCC permission status")

        for i in permissions.indices {
            let kind = permissions[i].kind
            permissions[i].status = await checkPermission(kind)
        }

        logger.info("TCC status: \(self.summary)")
    }

    /// Returns the status for a specific permission kind.
    func status(for kind: PermissionKind) -> PermissionStatus {
        permissions.first { $0.kind == kind }?.status ?? .unknown
    }

    // MARK: - Individual checks

    private func checkPermission(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .fullDiskAccess:
            #if DEBUG
            // FDA cannot be prompted — only checked passively. Debug builds run from
            // DerivedData paths that change every build, so FDA grants never persist.
            // Skip the check to avoid a non-actionable warning during development.
            return .granted
            #else
            return checkFullDiskAccess()
            #endif
        case .accessibility:
            return checkAccessibility()
        case .screenRecording:
            return checkScreenRecording()
        case .notifications:
            return await checkNotifications()
        }
    }

    /// Check FDA by attempting to list a TCC-protected directory.
    /// If access succeeds, FDA is granted. If it throws a permission error, it's denied.
    private func checkFullDiskAccess() -> PermissionStatus {
        let protectedPath = NSHomeDirectory() + "/Library/Mail"
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: protectedPath)
            return .granted
        } catch let error as NSError {
            // Permission denied → FDA not granted
            // Directory not found → likely granted (Mail not configured), treat as granted
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
                return .denied
            }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) {
                return .denied
            }
            // Other errors (e.g. directory doesn't exist) — FDA is likely granted
            return .granted
        }
    }

    /// Check Accessibility via AXIsProcessTrusted().
    private func checkAccessibility() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Check Screen Recording via CGPreflightScreenCaptureAccess().
    private func checkScreenRecording() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Check Notification permission via UNUserNotificationCenter.
    private func checkNotifications() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}

// MARK: - Display metadata

extension TCCPermissionState.PermissionKind {

    var displayName: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .notifications: "Notifications"
        }
    }

    var displayDescription: String {
        switch self {
        case .fullDiskAccess:
            "Required so the server can read workspace files in ~/Desktop, ~/Documents, and other protected folders."
        case .accessibility:
            "Optional. Enables future agent skills for screen automation via AppleScript."
        case .screenRecording:
            "Optional. Enables future screen capture tools for agents."
        case .notifications:
            "Optional. Allows permission approval alerts when the app is not focused."
        }
    }

    var isRequired: Bool {
        switch self {
        case .fullDiskAccess: true
        case .accessibility: false
        case .screenRecording: false
        case .notifications: false
        }
    }

    /// The System Settings URL that opens directly to this permission's pane.
    var systemSettingsURL: URL? {
        let urlString: String
        switch self {
        case .fullDiskAccess:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications"
        }
        return URL(string: urlString)
    }
}
