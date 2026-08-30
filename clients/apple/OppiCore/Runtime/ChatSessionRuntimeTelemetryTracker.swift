import Foundation

@MainActor
final class ChatSessionRuntimeTelemetryTracker {
    private struct TTFTContext {
        let startedAtMs: Int64
        let tags: [String: String]
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

    func startSessionLoad() {
        sessionLoadStartMs = Self.nowMs()
        sessionLoadRecorded = false
    }

    func recordSessionLoadIfNeeded(path: String, itemCount: Int, workspaceId: String? = nil) {
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

    func recordFreshContentLagIfNeeded(reason: String, workspaceId: String? = nil) {
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

    func startTTFT(modelTags: [String: String]) {
        guard pendingTTFTContext == nil else { return }
        pendingTTFTContext = TTFTContext(startedAtMs: Self.nowMs(), tags: modelTags)
    }

    func completeTTFTIfNeeded(signal: ServerMessage) {
        guard isTTFTCompletionSignal(signal), let context = pendingTTFTContext else { return }
        pendingTTFTContext = nil
        effects.recordTelemetry(
            .timeToFirstToken(
                durationMs: max(0, Self.nowMs() - context.startedAtMs),
                tags: context.tags
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
