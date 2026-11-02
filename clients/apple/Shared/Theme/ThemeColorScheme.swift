import Foundation

/// The light/dark side of a theme, without SwiftUI's `ColorScheme`.
///
/// The theme model is platform-color and UIKit/AppKit throughout, so the store
/// and the catalog cannot name `ColorScheme`: each platform's adapter maps this
/// to the framework value (`ThemeStore+UIKit` to `UIUserInterfaceStyle`, the
/// Mac's `Theme+SwiftUI.swift` to `ColorScheme`).
enum ThemeColorScheme: String, Sendable, CaseIterable {
    case light
    case dark
}
