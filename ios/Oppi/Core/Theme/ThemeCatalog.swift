import Foundation
import SwiftUI
import UIKit
import os

/// Flat color palette used by legacy `.tokyo*` color accessors.
///
/// Most views still reference `Color.tokyo...` directly. This palette layer lets
/// us switch themes globally without rewriting every call site in one pass.
struct ThemePalette: Sendable {
    let bg: Color
    let bgDark: Color
    let bgHighlight: Color

    let fg: Color
    let fgDim: Color
    let comment: Color

    let blue: Color
    let cyan: Color
    let green: Color
    let orange: Color
    let purple: Color
    let red: Color
    let yellow: Color
}

enum ThemeID: Hashable, Codable, Sendable {
    case tokyoNight
    case tokyoNightStorm
    case tokyoNightDay
    case appleDark
    case custom(String)

    /// All built-in themes for pickers. Custom themes added separately.
    static let builtins: [ThemeID] = [.tokyoNight, .tokyoNightStorm, .tokyoNightDay, .appleDark]

    static let storageKey = "\(AppIdentifiers.subsystem).theme.id"

    /// Stable string ID for persistence.
    var rawValue: String {
        switch self {
        case .tokyoNight: return "tokyo-night"
        case .tokyoNightStorm: return "tokyo-night-storm"
        case .tokyoNightDay: return "tokyo-night-day"
        case .appleDark: return "apple-dark"
        case .custom(let name): return "custom:\(name)"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "tokyo-night": self = .tokyoNight
        case "tokyo-night-storm": self = .tokyoNightStorm
        case "tokyo-night-day": self = .tokyoNightDay
        case "apple-dark": self = .appleDark
        default:
            if rawValue.hasPrefix("custom:") {
                self = .custom(String(rawValue.dropFirst("custom:".count)))
            } else {
                self = .tokyoNight
            }
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func loadPersisted() -> ThemeID {
        guard let raw = UserDefaults.standard.string(forKey: storageKey)
        else { return .tokyoNight }
        return ThemeID(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .tokyoNight: return "Tokyo Night"
        case .tokyoNightStorm: return "Tokyo Night Storm"
        case .tokyoNightDay: return "Tokyo Night Light"
        case .appleDark: return "Apple Dark"
        case .custom(let name): return name
        }
    }

    var detail: String {
        switch self {
        case .tokyoNight:
            return "Deepest dark palette, matches terminal."
        case .tokyoNightStorm:
            return "Slightly lighter dark with blue-tinted backgrounds."
        case .tokyoNightDay:
            return "Tokyo Night Day light palette."
        case .appleDark:
            return "Native dark with muted, frosted accents. Less color, more glass."
        case .custom:
            return "Custom theme imported from server."
        }
    }

    var preferredColorScheme: ColorScheme {
        switch self {
        case .tokyoNight, .tokyoNightStorm, .appleDark, .custom:
            return .dark
        case .tokyoNightDay:
            return .light
        }
    }

    var palette: ThemePalette {
        switch self {
        case .tokyoNight:
            return ThemePalettes.tokyoNight
        case .tokyoNightStorm:
            return ThemePalettes.tokyoNightStorm
        case .tokyoNightDay:
            return ThemePalettes.tokyoNightDay
        case .appleDark:
            return ThemePalettes.appleDark
        case .custom(let name):
            if let remote = CustomThemeStore.load(name: name),
               let palette = remote.toPalette() {
                return palette
            }
            return ThemePalettes.tokyoNight // fallback
        }
    }
}

enum ThemePalettes {
    static let tokyoNight = ThemePalette(
        bg: Color(red: 26.0 / 255.0, green: 27.0 / 255.0, blue: 38.0 / 255.0),
        bgDark: Color(red: 22.0 / 255.0, green: 22.0 / 255.0, blue: 30.0 / 255.0),
        bgHighlight: Color(red: 41.0 / 255.0, green: 46.0 / 255.0, blue: 66.0 / 255.0),
        fg: Color(red: 192.0 / 255.0, green: 202.0 / 255.0, blue: 245.0 / 255.0),
        fgDim: Color(red: 169.0 / 255.0, green: 177.0 / 255.0, blue: 214.0 / 255.0),
        comment: Color(red: 86.0 / 255.0, green: 95.0 / 255.0, blue: 137.0 / 255.0),
        blue: Color(red: 122.0 / 255.0, green: 162.0 / 255.0, blue: 247.0 / 255.0),
        cyan: Color(red: 125.0 / 255.0, green: 207.0 / 255.0, blue: 255.0 / 255.0),
        green: Color(red: 158.0 / 255.0, green: 206.0 / 255.0, blue: 106.0 / 255.0),
        orange: Color(red: 255.0 / 255.0, green: 158.0 / 255.0, blue: 100.0 / 255.0),
        purple: Color(red: 187.0 / 255.0, green: 154.0 / 255.0, blue: 247.0 / 255.0),
        red: Color(red: 247.0 / 255.0, green: 118.0 / 255.0, blue: 142.0 / 255.0),
        yellow: Color(red: 224.0 / 255.0, green: 175.0 / 255.0, blue: 104.0 / 255.0)
    )

    /// Tokyo Night Storm — lighter/bluer backgrounds, same accents as Night.
    /// Source: https://github.com/folke/tokyonight.nvim (extras/lua/tokyonight_storm.lua)
    static let tokyoNightStorm = ThemePalette(
        bg: Color(red: 36.0 / 255.0, green: 40.0 / 255.0, blue: 59.0 / 255.0),         // #24283b
        bgDark: Color(red: 31.0 / 255.0, green: 35.0 / 255.0, blue: 53.0 / 255.0),      // #1f2335
        bgHighlight: Color(red: 41.0 / 255.0, green: 46.0 / 255.0, blue: 66.0 / 255.0), // #292e42
        fg: Color(red: 192.0 / 255.0, green: 202.0 / 255.0, blue: 245.0 / 255.0),       // #c0caf5
        fgDim: Color(red: 169.0 / 255.0, green: 177.0 / 255.0, blue: 214.0 / 255.0),    // #a9b1d6
        comment: Color(red: 86.0 / 255.0, green: 95.0 / 255.0, blue: 137.0 / 255.0),    // #565f89
        blue: Color(red: 122.0 / 255.0, green: 162.0 / 255.0, blue: 247.0 / 255.0),     // #7aa2f7
        cyan: Color(red: 125.0 / 255.0, green: 207.0 / 255.0, blue: 255.0 / 255.0),     // #7dcfff
        green: Color(red: 158.0 / 255.0, green: 206.0 / 255.0, blue: 106.0 / 255.0),    // #9ece6a
        orange: Color(red: 255.0 / 255.0, green: 158.0 / 255.0, blue: 100.0 / 255.0),   // #ff9e64
        purple: Color(red: 187.0 / 255.0, green: 154.0 / 255.0, blue: 247.0 / 255.0),   // #bb9af7
        red: Color(red: 247.0 / 255.0, green: 118.0 / 255.0, blue: 142.0 / 255.0),      // #f7768e
        yellow: Color(red: 224.0 / 255.0, green: 175.0 / 255.0, blue: 104.0 / 255.0)    // #e0af68
    )

    static let tokyoNightDay = ThemePalette(
        bg: Color(red: 225.0 / 255.0, green: 226.0 / 255.0, blue: 231.0 / 255.0),
        bgDark: Color(red: 208.0 / 255.0, green: 213.0 / 255.0, blue: 227.0 / 255.0),
        bgHighlight: Color(red: 196.0 / 255.0, green: 200.0 / 255.0, blue: 218.0 / 255.0),
        fg: Color(red: 55.0 / 255.0, green: 96.0 / 255.0, blue: 191.0 / 255.0),
        fgDim: Color(red: 97.0 / 255.0, green: 114.0 / 255.0, blue: 176.0 / 255.0),
        comment: Color(red: 132.0 / 255.0, green: 140.0 / 255.0, blue: 181.0 / 255.0),
        blue: Color(red: 46.0 / 255.0, green: 125.0 / 255.0, blue: 233.0 / 255.0),
        cyan: Color(red: 0.0 / 255.0, green: 113.0 / 255.0, blue: 151.0 / 255.0),
        green: Color(red: 88.0 / 255.0, green: 117.0 / 255.0, blue: 57.0 / 255.0),
        orange: Color(red: 177.0 / 255.0, green: 92.0 / 255.0, blue: 0.0 / 255.0),
        purple: Color(red: 120.0 / 255.0, green: 71.0 / 255.0, blue: 189.0 / 255.0),
        red: Color(red: 198.0 / 255.0, green: 67.0 / 255.0, blue: 67.0 / 255.0),
        yellow: Color(red: 140.0 / 255.0, green: 108.0 / 255.0, blue: 62.0 / 255.0)
    )

    /// Apple Liquid Glass — native dark with desaturated, frosted accents.
    ///
    /// Backgrounds and text use system semantic colors for full adaptivity.
    /// Accent colors are intentionally muted to feel like system colors viewed
    /// through frosted glass — less vibrant, more cohesive, closer to how
    /// Apple's own apps use color sparingly in dark mode.
    static let appleDark = ThemePalette(
        bg: Color(uiColor: .systemBackground),
        bgDark: Color(uiColor: .secondarySystemBackground),
        bgHighlight: Color(uiColor: .tertiarySystemBackground),
        fg: Color(uiColor: .label),
        fgDim: Color(uiColor: .secondaryLabel),
        comment: Color(uiColor: .tertiaryLabel),
        blue:   Color(red: 100.0 / 255, green: 155.0 / 255, blue: 230.0 / 255), // #649BE6 — soft blue
        cyan:   Color(red: 120.0 / 255, green: 185.0 / 255, blue: 178.0 / 255), // #78B9B2 — muted teal
        green:  Color(red: 115.0 / 255, green: 185.0 / 255, blue: 135.0 / 255), // #73B987 — sage
        orange: Color(red: 205.0 / 255, green: 160.0 / 255, blue: 110.0 / 255), // #CDA06E — warm amber
        purple: Color(red: 160.0 / 255, green: 145.0 / 255, blue: 200.0 / 255), // #A091C8 — dusty lavender
        red:    Color(red: 220.0 / 255, green: 110.0 / 255, blue: 115.0 / 255), // #DC6E73 — rosewood
        yellow: Color(red: 200.0 / 255, green: 182.0 / 255, blue: 120.0 / 255)  // #C8B678 — warm khaki
    )
}

enum ThemeRuntimeState {
    private static let state = OSAllocatedUnfairLock(initialState: ThemeID.loadPersisted())

    static func currentThemeID() -> ThemeID {
        state.withLock { $0 }
    }

    static func setThemeID(_ themeID: ThemeID) {
        state.withLock { $0 = themeID }
    }

    static func currentPalette() -> ThemePalette {
        currentThemeID().palette
    }
}
