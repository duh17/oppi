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

    func resolveEngine(
        mode: VoiceInputManager.EngineMode,
        fallback: VoiceInputManager.TranscriptionEngine,
        locale: Locale = .current,
        serverCredentials: ServerCredentials? = nil,
        serverDictationAvailable: Bool = false
    ) async -> VoiceInputManager.TranscriptionEngine {
        switch mode {
        case .onDevice:
            return await resolveOnDeviceEngine(preferred: fallback, locale: locale)
        case .remote:
            return .serverDictation
        case .auto:
            // Legacy path: prefer server dictation whenever a server is in play.
            // The settings UI no longer exposes Auto because dictation routing
            // should be explicit, but stale preferences may still exist.
            if serverCredentials != nil || serverDictationAvailable {
                return .serverDictation
            }
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
