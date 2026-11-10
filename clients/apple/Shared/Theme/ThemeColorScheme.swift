import Foundation

/// The light/dark side of a theme, without SwiftUI's `ColorScheme`.
///
/// The theme model is UIKit throughout, so the store and the catalog do not
/// name `ColorScheme`: `ThemeStore+UIKit` maps this to `UIUserInterfaceStyle`.
enum ThemeColorScheme: String, Sendable, CaseIterable {
    case light
    case dark
}
