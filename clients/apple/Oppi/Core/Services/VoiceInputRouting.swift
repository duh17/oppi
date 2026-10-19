import Foundation

@MainActor
final class VoiceInputRouteResolver {
    typealias AvailabilityCheck = (
        VoiceInputManager.TranscriptionEngine,
        Locale
    ) async -> Bool

    private let isAvailable: AvailabilityCheck

    init(
        isAvailable: @escaping AvailabilityCheck = { engine, locale in
            await AppleOnDeviceVoiceProvider.isAvailable(for: engine, locale: locale)
        }
    ) {
        self.isAvailable = isAvailable
    }

    /// `serverDictationAvailable` is the server's `capabilities.dictationStream`: its
    /// dictation backend is configured and answering. Engine Server (and the legacy Auto,
    /// which the settings UI no longer offers) use the server only then; otherwise the take
    /// falls back to on-device dictation, which always works, instead of failing.
    func resolveEngine(
        mode: VoiceInputManager.EngineMode,
        fallback: VoiceInputManager.TranscriptionEngine,
        locale: Locale = .current,
        serverDictationAvailable: Bool = false
    ) async -> VoiceInputManager.TranscriptionEngine {
        switch mode {
        case .remote, .auto:
            if serverDictationAvailable {
                return .serverDictation
            }
            return await resolveOnDeviceEngine(preferred: fallback, locale: locale)
        case .onDevice:
            return await resolveOnDeviceEngine(preferred: fallback, locale: locale)
        }
    }

    private func resolveOnDeviceEngine(
        preferred: VoiceInputManager.TranscriptionEngine,
        locale: Locale
    ) async -> VoiceInputManager.TranscriptionEngine {
        guard preferred != .serverDictation else { return preferred }
        if await isAvailable(preferred, locale) {
            return preferred
        }

        let alternative: VoiceInputManager.TranscriptionEngine = preferred == .modernSpeech
            ? .classicDictation
            : .modernSpeech
        if await isAvailable(alternative, locale) {
            return alternative
        }

        // Keep the preferred route so its provider can surface a deterministic
        // locale/device error instead of silently switching to server dictation.
        return preferred
    }
}
