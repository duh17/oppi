import Foundation
import SwiftUI

/// Summary returned by `GET /themes`.
struct RemoteThemeSummary: Codable, Sendable, Identifiable {
    let name: String
    let filename: String
    let colorScheme: String

    var id: String { filename }
}

/// Full theme returned by `GET /themes/:name`.
struct RemoteTheme: Codable, Sendable {
    let name: String
    let colorScheme: String?
    let colors: RemoteThemeColors
}

struct RemoteThemeColors: Codable, Sendable {
    let bg: String
    let bgDark: String
    let bgHighlight: String
    let fg: String
    let fgDim: String
    let comment: String
    let blue: String
    let cyan: String
    let green: String
    let orange: String
    let purple: String
    let red: String
    let yellow: String
}

// MARK: - Conversion

extension RemoteTheme {
    /// Convert to a live `ThemePalette` the app can use immediately.
    func toPalette() -> ThemePalette? {
        guard
            let bg = Color(hex: colors.bg),
            let bgDark = Color(hex: colors.bgDark),
            let bgHighlight = Color(hex: colors.bgHighlight),
            let fg = Color(hex: colors.fg),
            let fgDim = Color(hex: colors.fgDim),
            let comment = Color(hex: colors.comment),
            let blue = Color(hex: colors.blue),
            let cyan = Color(hex: colors.cyan),
            let green = Color(hex: colors.green),
            let orange = Color(hex: colors.orange),
            let purple = Color(hex: colors.purple),
            let red = Color(hex: colors.red),
            let yellow = Color(hex: colors.yellow)
        else { return nil }

        return ThemePalette(
            bg: bg, bgDark: bgDark, bgHighlight: bgHighlight,
            fg: fg, fgDim: fgDim, comment: comment,
            blue: blue, cyan: cyan, green: green,
            orange: orange, purple: purple, red: red, yellow: yellow
        )
    }
}

// MARK: - Hex Parsing

private extension Color {
    /// Parse `#RRGGBB` hex string.
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let rgb = UInt32(str, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

// MARK: - Local Persistence

/// Stores imported custom themes in UserDefaults so they survive app restarts.
enum CustomThemeStore {
    private static let storageKey = "\(AppIdentifiers.subsystem).customThemes"

    /// Save a remote theme locally.
    static func save(_ theme: RemoteTheme) {
        var themes = loadAll()
        themes[theme.name] = theme
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Load all saved custom themes.
    static func loadAll() -> [String: RemoteTheme] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let themes = try? JSONDecoder().decode([String: RemoteTheme].self, from: data)
        else { return [:] }
        return themes
    }

    /// Load a specific theme by name.
    static func load(name: String) -> RemoteTheme? {
        loadAll()[name]
    }

    /// Delete a custom theme.
    static func delete(name: String) {
        var themes = loadAll()
        themes.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Get all custom theme names.
    static func names() -> [String] {
        Array(loadAll().keys).sorted()
    }
}
