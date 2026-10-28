import Foundation

/// The words under a Server Settings or Workspace Settings lock switch. A UIKit
/// page draws the switch itself; this is the one footer both say.
enum ScopedLockToggleRow {
    /// Footer for the current App Lock setting; `subject` names what the lock covers.
    @MainActor
    static func footer(for subject: String, appLock: AppLockService = .shared) -> String {
        let method = appLock.method == .passcode
            ? String(localized: "your passcode")
            : String(localized: "\(appLock.method.name) or your passcode")
        let lifetime = appLock.isEnabled
            ? String(localized: "until Oppi locks again")
            : String(localized: "until you leave Oppi")
        return String(localized: "Asks for \(method) before showing \(subject). Once unlocked, it stays open \(lifetime). Turning the lock off asks too. The lock is kept on this device only.")
    }
}
