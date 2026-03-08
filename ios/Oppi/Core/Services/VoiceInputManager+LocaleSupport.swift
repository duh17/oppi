import Foundation

extension VoiceInputManager {
    /// Resolve locale from a keyboard language string (BCP 47).
    /// Priority: active keyboard → persisted last keyboard → device locale.
    static func resolvedLocale(keyboardLanguage: String? = nil) -> Locale {
        if let lang = KeyboardLanguageStore.normalize(keyboardLanguage) {
            return Locale(identifier: lang)
        }
        if let stored = KeyboardLanguageStore.lastLanguage {
            return Locale(identifier: stored)
        }
        return Locale.current
    }

    /// On-device engine routing. DictationTranscriber (classic keyboard dictation
    /// model) is used for all locales — it's faster, adds punctuation, and has
    /// years of Apple tuning for short-form dictation. SpeechTranscriber (new
    /// model) is designed for long-form/meeting/lecture transcription and trades
    /// short-form latency for broader context handling.
    static func preferredEngine(for locale: Locale) -> TranscriptionEngine {
        // All locales use the classic dictation engine. The new SpeechTranscriber
        // model is optimized for long-form audio (Notes, Voice Memos) and has
        // worse latency/accuracy for short chat dictation.
        _ = locale
        return .classicDictation
    }

    // periphery:ignore - API surface for voice availability checks
    /// Whether the preferred engine for `locale` supports that locale.
    static func isAvailable(for locale: Locale = .current) async -> Bool {
        let engine = preferredEngine(for: locale)
        switch engine {
        case .remoteASR:
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
        case .remoteASR:
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
