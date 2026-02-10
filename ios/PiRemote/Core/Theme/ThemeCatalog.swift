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

enum ThemeID: String, CaseIterable, Codable, Sendable {
    case tokyoNight = "tokyo-night"
    case tokyoNightDay = "tokyo-night-day"
    case appleDark = "apple-dark"

    static let storageKey = "dev.chenda.PiRemote.theme.id"

    static func loadPersisted() -> ThemeID {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = ThemeID(rawValue: raw)
        else {
            return .tokyoNight
        }
        return value
    }

    var displayName: String {
        switch self {
        case .tokyoNight: return "Tokyo Night"
        case .tokyoNightDay: return "Tokyo Night Light"
        case .appleDark: return "Apple Dark"
        }
    }

    var detail: String {
        switch self {
        case .tokyoNight:
            return "Current terminal-matching dark palette."
        case .tokyoNightDay:
            return "Tokyo Night Day light palette."
        case .appleDark:
            return "Semantic iOS dark colors (system backgrounds + labels)."
        }
    }

    var preferredColorScheme: ColorScheme {
        switch self {
        case .tokyoNight, .appleDark:
            return .dark
        case .tokyoNightDay:
            return .light
        }
    }

    var palette: ThemePalette {
        switch self {
        case .tokyoNight:
            return ThemePalettes.tokyoNight
        case .tokyoNightDay:
            return ThemePalettes.tokyoNightDay
        case .appleDark:
            return ThemePalettes.appleDark
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

    static let appleDark = ThemePalette(
        bg: Color(uiColor: .systemBackground),
        bgDark: Color(uiColor: .secondarySystemBackground),
        bgHighlight: Color(uiColor: .tertiarySystemBackground),
        fg: Color(uiColor: .label),
        fgDim: Color(uiColor: .secondaryLabel),
        comment: Color(uiColor: .tertiaryLabel),
        blue: Color(uiColor: .systemBlue),
        cyan: Color(uiColor: .systemTeal),
        green: Color(uiColor: .systemGreen),
        orange: Color(uiColor: .systemOrange),
        purple: Color(uiColor: .systemPurple),
        red: Color(uiColor: .systemRed),
        yellow: Color(uiColor: .systemYellow)
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
