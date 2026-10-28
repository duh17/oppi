import SwiftUI

/// Lock toggle for the SwiftUI Server Settings page; kit pages use `ScopedLockToggleRow`. Delete this with that page.
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
        ScopedLockToggleRow.footer(for: subject)
    }
}
