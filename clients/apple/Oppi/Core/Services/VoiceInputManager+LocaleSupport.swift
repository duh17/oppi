import Foundation

extension VoiceInputManager {
    /// Resolve locale from a keyboard language string (BCP 47).
    /// Priority: active keyboard → persisted last keyboard → device locale.
    static func resolvedLocale(keyboardLanguage: String? = nil) -> Locale {
        if let lang = AppPreferences.Keyboard.normalize(keyboardLanguage) {
            return Locale(identifier: lang)
        }
        if let stored = AppPreferences.Keyboard.lastLanguage {
            return Locale(identifier: stored)
        }
        return Locale.current
    }

    /// On-device engine routing.
    ///
    /// Prefer `SpeechTranscriber` for the in-app mic path. Recent device runs
    /// show `DictationTranscriber` pre-warming successfully, then failing during
    /// session activation with a generic `NSError`; `SpeechTranscriber` uses the
    /// same on-device framework but has been more reliable for app-owned audio
    /// capture.
    static func preferredEngine(for locale: Locale) -> TranscriptionEngine {
        _ = locale
        return .modernSpeech
    }

    // periphery:ignore - API surface for voice availability checks
    /// Whether the preferred engine for `locale` supports that locale.
    static func isAvailable(for locale: Locale = .current) async -> Bool {
        let engine = preferredEngine(for: locale)
        switch engine {
        case .serverDictation:
            return true
        case .modernSpeech, .classicDictation:
            return await AppleOnDeviceVoiceProvider.isAvailable(for: engine, locale: locale)
        }
    }

    // periphery:ignore - API surface for voice model availability checks
    /// Whether the preferred engine model for `locale` is installed.
    static func isModelInstalled(for locale: Locale) async -> Bool {
        let engine = preferredEngine(for: locale)
        switch engine {
        case .serverDictation:
            return true
        case .modernSpeech, .classicDictation:
            return await AppleOnDeviceVoiceProvider.isModelInstalled(for: engine, locale: locale)
        }
    }

    /// Compact language label for display in the mic button.
    /// CJK languages get their native script character, others get 2-letter code.
    static func languageLabel(for locale: Locale) -> String {
        let langCode = locale.language.languageCode?.identifier ?? "en"
        switch langCode {
        case "zh": return "中"
        case "ja": return "あ"
        case "ko": return "한"
        default: return langCode.uppercased().prefix(2).description
        }
    }
}
