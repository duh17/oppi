import Foundation

@MainActor
final class VoiceInputRouteResolver {

    func resolveEngine(
        mode: VoiceInputManager.EngineMode,
        fallback: VoiceInputManager.TranscriptionEngine,
        serverCredentials: ServerCredentials? = nil,
        asrAvailable: Bool = false
    ) async -> VoiceInputManager.TranscriptionEngine {
        switch mode {
        case .onDevice:
            return fallback
        case .remote:
            return .serverDictation
        case .auto:
            // Legacy path: prefer server dictation whenever a server is in play.
            // The settings UI no longer exposes Auto because dictation routing
            // should be explicit, but stale preferences may still exist.
            if serverCredentials != nil || asrAvailable {
                return .serverDictation
            }
            return fallback
        }
    }
}
