import UIKit

/// Content families that share full-screen viewing preferences.
enum FullScreenReaderContentFamily: String, Codable, CaseIterable, Equatable {
    case markdown
    case code
    case source
    case diff
    case terminal
    case html
    case renderedDocument

    var supportsWrapping: Bool {
        switch self {
        case .code, .source, .diff, .terminal:
            return true
        case .markdown, .html, .renderedDocument:
            return false
        }
    }

    var supportsSpacing: Bool {
        switch self {
        case .markdown, .renderedDocument:
            return true
        case .code, .source, .diff, .terminal, .html:
            return false
        }
    }

    var defaultPreferences: FullScreenReaderPreferences {
        switch self {
        case .source:
            return FullScreenReaderPreferences(wrapsText: true)
        default:
            return FullScreenReaderPreferences(wrapsText: false)
        }
    }
}

enum FullScreenReaderTextSize: Int, Codable, CaseIterable, Equatable {
    case small = 0
    case standard = 1
    case large = 2
    case extraLarge = 3

    var displayName: String {
        switch self {
        case .small: return String(localized: "Small")
        case .standard: return String(localized: "Standard")
        case .large: return String(localized: "Large")
        case .extraLarge: return String(localized: "Extra Large")
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.88
        case .standard: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.32
        }
    }

    var canDecrease: Bool { self != .small }
    var canIncrease: Bool { self != .extraLarge }

    func adjusted(by delta: Int) -> Self {
        let nextRaw = min(
            Self.extraLarge.rawValue,
            max(Self.small.rawValue, rawValue + delta)
        )
        return Self(rawValue: nextRaw) ?? self
    }
}

enum FullScreenReaderSpacing: String, Codable, CaseIterable, Equatable {
    case compact
    case standard
    case relaxed

    var displayName: String {
        switch self {
        case .compact: return String(localized: "Compact")
        case .standard: return String(localized: "Standard")
        case .relaxed: return String(localized: "Relaxed")
        }
    }

    var markdownStackSpacing: CGFloat {
        switch self {
        case .compact: return 5
        case .standard: return 8
        case .relaxed: return 12
        }
    }

    var markdownLineSpacing: CGFloat {
        switch self {
        case .compact: return 0
        case .standard: return 1.5
        case .relaxed: return 4
        }
    }
}

struct FullScreenReaderPreferences: Codable, Equatable {
    var textSize: FullScreenReaderTextSize
    var spacing: FullScreenReaderSpacing
    var wrapsText: Bool

    init(
        textSize: FullScreenReaderTextSize = .standard,
        spacing: FullScreenReaderSpacing = .standard,
        wrapsText: Bool = false
    ) {
        self.textSize = textSize
        self.spacing = spacing
        self.wrapsText = wrapsText
    }

    var textScale: CGFloat {
        textSize.scale
    }
}

@MainActor
final class FullScreenReaderPreferencesStore {
    static let shared = FullScreenReaderPreferencesStore()

    private let defaults: UserDefaults
    private let keyPrefix = "oppi.fullScreenReaderPreferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preferences(for family: FullScreenReaderContentFamily) -> FullScreenReaderPreferences {
        let key = key(for: family)
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(FullScreenReaderPreferences.self, from: data)
        else {
            return family.defaultPreferences
        }
        return decoded
    }

    func setPreferences(
        _ preferences: FullScreenReaderPreferences,
        for family: FullScreenReaderContentFamily
    ) {
        if preferences == family.defaultPreferences {
            defaults.removeObject(forKey: key(for: family))
            return
        }

        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key(for: family))
    }

    func resetPreferences(for family: FullScreenReaderContentFamily) {
        defaults.removeObject(forKey: key(for: family))
    }

    private func key(for family: FullScreenReaderContentFamily) -> String {
        "\(keyPrefix).\(family.rawValue)"
    }
}
