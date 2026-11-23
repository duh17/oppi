import Foundation

/// How big a list draws its icon: the person's choice in Settings › Session
/// Rows › Icon Size, which sizes the session list's icons and the Agents
/// list's alike. Three tested sizes rather than a slider, so every row either
/// list draws is one of them.
///
/// The sizes themselves are the contract with the row: `SessionRowIdentity`
/// turns one into the circle's side, the column it sits in, and where the text
/// starts past it.
enum SessionIconSize: String, CaseIterable, Sendable, Codable {
    case small
    case medium
    case large

    var displayName: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }
}
