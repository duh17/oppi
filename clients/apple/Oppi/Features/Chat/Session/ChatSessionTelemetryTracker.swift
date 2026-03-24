import Foundation
import os.log

private let log = Logger(subsystem: AppIdentifiers.subsystem, category: "ChatSessionTelemetry")

/// Tracks session-level telemetry: TTFT, fresh content lag, and session load timing.
///
/// Extracted from ChatSessionManager to isolate measurement state from connection lifecycle.
@MainActor
final class ChatSessionTelemetryTracker {
    struct TTFTContext {
        let startedAtMs: Int64
        let tags: [String: String]
    }

    private var pendingTTFTContext: TTFTContext?
    private var freshContentLagStartMs: Int64?
    private var freshContentLagRecorded = false
    private(set) var loadedFromCacheAtConnect = false
    private var observedTransportPath: ConnectionTransportPath = .paired
    private var sessionLoadStartMs: Int64?
    private var sessionLoadRecorded = false

    // MARK: - Session Load

    func startSessionLoad() {
        sessionLoadStartMs = ChatSessionTelemetry.nowMs()
        sessionLoadRecorded = false
    }

    func recordSessionLoadIfNeeded(path: String, itemCount: Int, sessionId: String, workspaceId: String? = nil) {
        guard !sessionLoadRecorded, let startMs = sessionLoadStartMs else { return }
        sessionLoadRecorded = true
        let durationMs = max(0, ChatSessionTelemetry.nowMs() - startMs)
        ChatSessionTelemetry.recordSessionLoad(
            durationMs: durationMs,
            sessionId: sessionId,
            workspaceId: workspaceId,
            path: path,
            itemCount: itemCount
        )
    }

    // MARK: - Fresh Content Lag

    func beginFreshContentLagMeasurement(hadCache: Bool) {
        freshContentLagStartMs = ChatSessionTelemetry.nowMs()
        freshContentLagRecorded = false
        loadedFromCacheAtConnect = hadCache
    }

    func markCacheLoaded() {
        loadedFromCacheAtConnect = true
    }

    func updateTransportPath(_ path: ConnectionTransportPath) {
        observedTransportPath = path
    }

    func recordFreshContentLagIfNeeded(reason: String, sessionId: String, workspaceId: String? = nil) {
        guard !freshContentLagRecorded, let startedAt = freshContentLagStartMs else { return }
        freshContentLagRecorded = true
        let durationMs = max(0, ChatSessionTelemetry.nowMs() - startedAt)
        ChatSessionTelemetry.recordFreshContentLag(
            durationMs: durationMs,
            sessionId: sessionId,
            workspaceId: workspaceId,
            reason: reason,
            cached: loadedFromCacheAtConnect,
            transport: observedTransportPath.rawValue
        )
    }

    // MARK: - TTFT

    /// Begin TTFT measurement. No-op if a measurement is already in flight.
    func startTTFT(modelTags: [String: String]) {
        guard pendingTTFTContext == nil else { return }
        pendingTTFTContext = TTFTContext(
            startedAtMs: ChatSessionTelemetry.nowMs(),
            tags: modelTags
        )
    }

    /// Complete TTFT measurement if `signal` is a completion event (textDelta or thinkingDelta).
    func completeTTFTIfNeeded(signal: ServerMessage, sessionId: String) {
        guard isTTFTCompletionSignal(signal), let context = pendingTTFTContext else { return }
        pendingTTFTContext = nil
        let ttftMs = max(0, ChatSessionTelemetry.nowMs() - context.startedAtMs)
        ChatSessionTelemetry.recordTTFT(
            durationMs: ttftMs,
            sessionId: sessionId,
            tags: context.tags
        )
    }

    func cancelTTFT() {
        pendingTTFTContext = nil
    }

    // MARK: - Reset

    func reset() {
        pendingTTFTContext = nil
        freshContentLagStartMs = nil
        freshContentLagRecorded = false
        loadedFromCacheAtConnect = false
        observedTransportPath = .paired
        sessionLoadStartMs = nil
        sessionLoadRecorded = false
    }

    // MARK: - Helpers

    private func isTTFTCompletionSignal(_ message: ServerMessage) -> Bool {
        if case .thinkingDelta = message { return true }
        if case .textDelta = message { return true }
        return false
    }

    /// Extract provider/model tags from the session's configured model string.
    static func modelTags(from sessionStore: SessionStore, sessionId: String) -> [String: String] {
        guard let rawModel = sessionStore.session(id: sessionId)?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawModel.isEmpty else {
            return [
                "provider": "unknown",
                "model": "unknown",
            ]
        }

        let parts = rawModel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let provider = String(parts[0]).isEmpty ? "unknown" : String(parts[0])
            let model = String(parts[1]).isEmpty ? "unknown" : String(parts[1])
            return [
                "provider": provider,
                "model": model,
            ]
        }

        return [
            "provider": "unknown",
            "model": rawModel,
        ]
    }
}
