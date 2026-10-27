import Foundation

/// Ambient app state at the moment an event is recorded. The single provider
/// of `screen`, `stream_state`, `agents`, and `voice`: every event that carries
/// any of them reads it here, so a memory or CPU sample cannot lack a screen.
struct TelemetryContext: Sendable, Equatable {
    let screen: String
    let streamState: String
    let agents: TelemetryTag.Agents
    let voice: TelemetryTag.Voice

    /// Value for any `name` tag the app cannot determine.
    static let unknown = TelemetryName.fallback

    init(crashContext: MetricKitCrashContext?, agentsRunning: Bool, voiceActive: Bool) {
        screen = crashContext?.screen.map(TelemetryName.sanitize) ?? Self.unknown
        streamState = crashContext.map { TelemetryName.sanitize($0.streamState) } ?? Self.unknown
        agents = agentsRunning ? .running : .idle
        voice = voiceActive ? .on : .off
    }

    /// The screen alone. Readable from any thread, so the stall watchdog can
    /// tag its events without hopping to the main actor.
    static var currentScreen: String {
        MetricKitCrashContextStore.snapshot()?.screen.map(TelemetryName.sanitize) ?? unknown
    }

    @MainActor
    static func current(screenAwake: ScreenAwakeController = .shared) -> Self {
        Self(
            crashContext: MetricKitCrashContextStore.snapshot(),
            agentsRunning: screenAwake.hasRunningSession,
            voiceActive: screenAwake.isVoiceInputActive
        )
    }
}
