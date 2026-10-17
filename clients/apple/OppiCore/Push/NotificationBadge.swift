import Foundation

/// The app icon badge counts Oppi notifications waiting in Notification Center: decrypted
/// pushes and the app's own banners alike. Each new notification sets it, and the app
/// recounts when it becomes active, after the user cleared or opened some.
enum NotificationBadge {
    /// The badge for a notification about to be delivered as `identifier`. A push that
    /// replaces a delivered one (same collapse ID) adds nothing.
    static func count(deliveredIdentifiers: [String], adding identifier: String) -> Int {
        deliveredIdentifiers.contains(identifier) ? deliveredIdentifiers.count : deliveredIdentifiers.count + 1
    }
}
