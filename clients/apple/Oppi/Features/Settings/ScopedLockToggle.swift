import SwiftUI

/// Lock toggle for Server Settings and Workspace Settings. Turning the lock on
/// never asks and keeps this screen open for now; turning it off asks for
/// device authentication and stays on after a cancel.
struct ScopedLockToggle: View {
    let title: LocalizedStringKey
    let scope: ScopedLockScope

    @State private var locks = ScopedLockService.shared

    var body: some View {
        Toggle(
            title,
            isOn: Binding(
                get: { locks.isFlagged(scope) },
                set: { isOn in
                    if isOn {
                        locks.lock(scope, unlockedForNow: true)
                    } else {
                        Task { await locks.removeLock(scope) }
                    }
                }
            )
        )
        .disabled(locks.isAuthenticating)
    }

    /// Footer for the current App Lock setting; `subject` names what the lock covers.
    @MainActor
    static func footer(for subject: String) -> String {
        let appLock = AppLockService.shared
        let method = appLock.method == .passcode
            ? String(localized: "your passcode")
            : String(localized: "\(appLock.method.name) or your passcode")
        let lifetime = appLock.isEnabled
            ? String(localized: "until Oppi locks again")
            : String(localized: "until you leave Oppi")
        return String(localized: "Asks for \(method) before showing \(subject). Once unlocked, it stays open \(lifetime). Turning the lock off asks too. The lock is kept on this device only.")
    }
}
