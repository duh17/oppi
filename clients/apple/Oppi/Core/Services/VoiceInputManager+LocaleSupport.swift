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

    /// Preferred on-device engine before device and locale capabilities are checked.
    /// Runtime routing falls back to `DictationTranscriber` when the newer
    /// `SpeechTranscriber` model is unavailable.
    static func preferredEngine(for locale: Locale) -> TranscriptionEngine {
        _ = locale
        return .modernSpeech
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
