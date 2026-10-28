import UIKit

/// The lock switch of Server Settings and Workspace Settings, for a kit page.
/// Turning the lock on never asks and keeps the screen open for now; turning it
/// off asks for device authentication and stays on after a cancel. The switch is
/// disabled while that prompt is up.
///
/// A page reads the lock in `sections()` and `inputs(of:)` through
/// `scopedLockInputs(_:locks:)`, which `ScopedLockService` (`@Observable`) keeps
/// live, and draws the row with `scopedLockToggleRow(_:title:scope:locks:identifier:)`.
@MainActor
extension SettingsListViewController {
    /// What the lock row is drawn from, for `inputs(of:)`.
    func scopedLockInputs(_ scope: ScopedLockScope, locks: ScopedLockService = .shared) -> AnyHashable {
        AnyHashable([locks.isFlagged(scope), locks.isAuthenticating])
    }

    /// Makes `cell` the lock's switch row.
    func scopedLockToggleRow(
        _ cell: UICollectionViewListCell,
        title: String,
        scope: ScopedLockScope,
        locks: ScopedLockService = .shared,
        identifier: String? = nil
    ) {
        toggleRow(
            cell,
            title: title,
            isOn: locks.isFlagged(scope),
            identifier: identifier,
            isEnabled: !locks.isAuthenticating
        ) { isOn in
            if isOn {
                locks.lock(scope, unlockedForNow: true)
            } else {
                Task { _ = await locks.removeLock(scope) }
            }
        }
    }
}

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
