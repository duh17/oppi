import Foundation

/// Per-session usage telemetry (`AppSessionUsage`): one snapshot when a session
/// settles, at most once a minute while it stays ready, and at once when it stops
/// or fails. These are capacity and cost diagnostics, not live counters. Each
/// `ServerConnection` owns one and forgets a session when its stream or the
/// session goes away.
@MainActor
final class SessionUsageMetricsReporter {
    struct Snapshot: Equatable {
        let provider: String
        let model: String
        let messageCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let mutatingToolCalls: Int
        let filesChanged: Int
        let contextTokens: Int
        let contextWindow: Int

        var hasUsageSignal: Bool {
            messageCount > 0
                || totalTokens > 0
                || mutatingToolCalls > 0
                || filesChanged > 0
                || contextTokens > 0
        }
    }

    /// Minimum spacing for repeated snapshots of a session that stays ready.
    static let minimumInterval: TimeInterval = 60

    /// Last emitted snapshot per session, so an unchanged one is never sent twice.
    private var snapshots: [String: Snapshot] = [:]
    private var lastEmittedAt: [String: Date] = [:]

    func reportIfNeeded(_ session: Session) {
        let snapshot = Self.snapshot(from: session)
        let now = Date()
        guard shouldEmit(for: session, snapshot: snapshot, now: now) else { return }
        snapshots[session.id] = snapshot
        lastEmittedAt[session.id] = now

        Telemetry.record(
            AppSessionUsage(
                messageCount: snapshot.messageCount,
                inputTokens: snapshot.inputTokens,
                outputTokens: snapshot.outputTokens,
                mutatingToolCalls: snapshot.mutatingToolCalls,
                filesChanged: snapshot.filesChanged,
                contextTokens: snapshot.contextTokens,
                contextWindow: snapshot.contextWindow,
                provider: snapshot.provider,
                model: snapshot.model
            ),
            sessionId: session.id,
            workspaceId: session.workspaceId
        )
    }

    func shouldEmit(
        for session: Session,
        snapshot: Snapshot,
        now: Date = Date()
    ) -> Bool {
        guard snapshot.hasUsageSignal else { return false }
        guard snapshots[session.id] != snapshot else { return false }

        if session.status == .stopped || session.status == .error {
            return true
        }

        guard session.status.isTerminal else { return false }
        guard let lastEmittedAt = lastEmittedAt[session.id] else { return true }
        return now.timeIntervalSince(lastEmittedAt) >= Self.minimumInterval
    }

    func forget(sessionId: String) {
        snapshots.removeValue(forKey: sessionId)
        lastEmittedAt.removeValue(forKey: sessionId)
    }

    func forgetAll() {
        snapshots.removeAll()
        lastEmittedAt.removeAll()
    }

    static func snapshot(from session: Session) -> Snapshot {
        let (provider, model) = parseModelTags(session.model)
        let inputTokens = max(0, session.tokens.input)
        let outputTokens = max(0, session.tokens.output)
        let mutatingToolCalls = max(0, session.changeStats?.mutatingToolCalls ?? 0)
        let filesChanged = max(0, session.changeStats?.filesChanged ?? 0)
        let contextTokens = max(0, session.contextTokens ?? 0)
        let contextWindow = max(0, session.contextWindow ?? 0)

        return Snapshot(
            provider: provider,
            model: model,
            messageCount: max(0, session.messageCount),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: inputTokens + outputTokens,
            mutatingToolCalls: mutatingToolCalls,
            filesChanged: filesChanged,
            contextTokens: contextTokens,
            contextWindow: contextWindow
        )
    }

    private static func parseModelTags(_ rawModel: String?) -> (provider: String, model: String) {
        guard let rawModel,
              !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("unknown", "unknown")
        }

        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let provider = String(parts[0]).isEmpty ? "unknown" : String(parts[0])
            let model = String(parts[1]).isEmpty ? "unknown" : String(parts[1])
            return (provider, model)
        }

        return ("unknown", trimmed)
    }
}
