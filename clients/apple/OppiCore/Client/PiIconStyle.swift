import Foundation

/// How the Pi mark is drawn: the official brand colors, or one color that
/// follows the theme foreground.
enum PiIconStyle: String, CaseIterable, Sendable, Codable {
    case color
    case monochrome

    var displayName: String {
        switch self {
        case .color: return "Color"
        case .monochrome: return "Monochrome"
        }
    }
}
