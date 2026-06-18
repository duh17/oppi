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

/// Persisted stepped text-size values. Current UI stores a continuous text scale,
/// but decoding this enum preserves saved reader preferences.
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
    static let minimumTextScale: CGFloat = 0.85
    static let standardTextScale: CGFloat = 1.0
    static let maximumTextScale: CGFloat = 1.35

    var textScale: CGFloat
    var spacing: FullScreenReaderSpacing
    var wrapsText: Bool

    init(
        textScale: CGFloat = Self.standardTextScale,
        spacing: FullScreenReaderSpacing = .standard,
        wrapsText: Bool = false
    ) {
        self.textScale = Self.clampedTextScale(textScale)
        self.spacing = spacing
        self.wrapsText = wrapsText
    }

    static func clampedTextScale(_ scale: CGFloat) -> CGFloat {
        min(maximumTextScale, max(minimumTextScale, scale))
    }

    private enum CodingKeys: String, CodingKey {
        case textScale
        case textSize
        case spacing
        case wrapsText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let scale = try container.decodeIfPresent(CGFloat.self, forKey: .textScale) {
            textScale = Self.clampedTextScale(scale)
        } else if let storedTextSize = try container.decodeIfPresent(FullScreenReaderTextSize.self, forKey: .textSize) {
            textScale = Self.clampedTextScale(storedTextSize.scale)
        } else {
            textScale = Self.standardTextScale
        }
        spacing = try container.decodeIfPresent(FullScreenReaderSpacing.self, forKey: .spacing) ?? .standard
        wrapsText = try container.decodeIfPresent(Bool.self, forKey: .wrapsText) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(textScale, forKey: .textScale)
        try container.encode(spacing, forKey: .spacing)
        try container.encode(wrapsText, forKey: .wrapsText)
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
        return normalized(decoded, for: family)
    }

    func setPreferences(
        _ preferences: FullScreenReaderPreferences,
        for family: FullScreenReaderContentFamily
    ) {
        let normalized = normalized(preferences, for: family)
        if normalized == family.defaultPreferences {
            defaults.removeObject(forKey: key(for: family))
            return
        }

        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: key(for: family))
    }

    func resetPreferences(for family: FullScreenReaderContentFamily) {
        defaults.removeObject(forKey: key(for: family))
    }

    private func key(for family: FullScreenReaderContentFamily) -> String {
        "\(keyPrefix).\(family.rawValue)"
    }

    private func normalized(
        _ preferences: FullScreenReaderPreferences,
        for family: FullScreenReaderContentFamily
    ) -> FullScreenReaderPreferences {
        var normalized = preferences
        if !family.supportsWrapping {
            normalized.wrapsText = family.defaultPreferences.wrapsText
        }
        if !family.supportsSpacing {
            normalized.spacing = family.defaultPreferences.spacing
        }
        return normalized
    }
}
