import Foundation

@MainActor
final class ChatSessionRuntimeTelemetryTracker {
    private struct TTFTContext {
        let startedAtMs: Int64
        let provider: String
        let model: String
    }

    private let effects: any ChatSessionEffectsStatePort
    private let sessionId: String
    private var pendingTTFTContext: TTFTContext?
    private var freshContentLagStartMs: Int64?
    private var freshContentLagRecorded = false
    private(set) var loadedFromCacheAtConnect = false
    private var observedTransportPath: ConnectionTransportPath = .paired
    private var sessionLoadStartMs: Int64?
    private var sessionLoadRecorded = false
    private var sessionSwitchStartMs: Int64?
    private var sessionSwitchRecorded = false

    init(sessionId: String, effects: any ChatSessionEffectsStatePort) {
        self.sessionId = sessionId
        self.effects = effects
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    /// Drops the open switch, load, and freshness measurements. A visit that was
    /// abandoned or backgrounded before its first content measures the time
    /// the app sat idle (a suspended app once reported a 1.08 h session switch),
    /// not the load.
    func cancelLoadMeasurements() {
        sessionSwitchStartMs = nil
        sessionSwitchRecorded = true
        sessionLoadStartMs = nil
        sessionLoadRecorded = true
        freshContentLagStartMs = nil
        freshContentLagRecorded = true
    }

    func startSessionLoad() {
        sessionLoadStartMs = Self.nowMs()
        sessionLoadRecorded = false
    }

    func recordSessionLoadIfNeeded(
        path: ChatSessionRuntimeTelemetry.LoadPath,
        itemCount: Int,
        workspaceId: String? = nil
    ) {
        guard !sessionLoadRecorded, let startMs = sessionLoadStartMs else { return }
        sessionLoadRecorded = true
        effects.recordTelemetry(
            .sessionLoad(
                durationMs: max(0, Self.nowMs() - startMs),
                workspaceId: workspaceId,
                path: path,
                itemCount: itemCount
            ),
            sessionId: sessionId
        )
        recordSessionSwitchIfNeeded()
    }

    func beginFreshContentLagMeasurement(hadCache: Bool) {
        freshContentLagStartMs = Self.nowMs()
        freshContentLagRecorded = false
        loadedFromCacheAtConnect = hadCache
    }

    func markCacheLoaded() {
        loadedFromCacheAtConnect = true
    }

    func updateTransportPath(_ path: ConnectionTransportPath) {
        observedTransportPath = path
    }

    func recordFreshContentLagIfNeeded(
        reason: ChatSessionRuntimeTelemetry.FreshnessReason,
        workspaceId: String? = nil
    ) {
        guard !freshContentLagRecorded, let startedAt = freshContentLagStartMs else { return }
        freshContentLagRecorded = true
        effects.recordTelemetry(
            .freshContentLag(
                durationMs: max(0, Self.nowMs() - startedAt),
                workspaceId: workspaceId,
                reason: reason,
                cached: loadedFromCacheAtConnect,
                transport: observedTransportPath.rawValue
            ),
            sessionId: sessionId
        )
    }

    func startSessionSwitch() {
        sessionSwitchStartMs = Self.nowMs()
        sessionSwitchRecorded = false
    }

    private func recordSessionSwitchIfNeeded() {
        guard !sessionSwitchRecorded, let startMs = sessionSwitchStartMs else { return }
        sessionSwitchRecorded = true
        effects.recordTelemetry(
            .sessionSwitch(
                durationMs: max(0, Self.nowMs() - startMs),
                cached: loadedFromCacheAtConnect
            ),
            sessionId: sessionId
        )
    }

    func startTTFT(provider: String, model: String) {
        guard pendingTTFTContext == nil else { return }
        pendingTTFTContext = TTFTContext(startedAtMs: Self.nowMs(), provider: provider, model: model)
    }

    func completeTTFTIfNeeded(signal: ServerMessage) {
        guard isTTFTCompletionSignal(signal) else { return }
        completeTTFT()
    }

    /// The first token arrived: a delta, or the answer in flight in `pi.live`.
    func completeTTFT() {
        guard let context = pendingTTFTContext else { return }
        pendingTTFTContext = nil
        effects.recordTelemetry(
            .timeToFirstToken(
                durationMs: max(0, Self.nowMs() - context.startedAtMs),
                provider: context.provider,
                model: context.model
            ),
            sessionId: sessionId
        )
    }

    func cancelTTFT() {
        pendingTTFTContext = nil
    }

    private func isTTFTCompletionSignal(_ message: ServerMessage) -> Bool {
        if case .thinkingDelta = message { return true }
        if case .textDelta = message { return true }
        return false
    }
}
