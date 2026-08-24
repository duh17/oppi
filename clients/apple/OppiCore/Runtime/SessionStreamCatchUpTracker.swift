import Foundation

/// Queue-sync phase for a focused session stream.
enum SessionStreamQueueSyncPhase: String, Equatable, Sendable {
    case initial
    case retry
}

/// Platform-neutral focused session stream lifecycle state.
enum SessionStreamState: Equatable, Sendable {
    case idle
    case connectingTransport(sessionId: String)
    case queueSync(sessionId: String, phase: SessionStreamQueueSyncPhase)
    case streaming(sessionId: String)
    case resubscribing(sessionId: String)
}

/// Tracks durable event sequence progress for focused session catch-up.
///
/// The server can report the current durable event sequence after a reconnect.
/// This tracker decides whether the client is already current, should fetch a
/// gap, or must reset after a server-side sequence regression.
struct SessionStreamCatchUpTracker: Equatable, Sendable {
    enum CatchUpDecision: Equatable, Sendable {
        case noGap
        case fetchSince(Int)
        case seqRegression(resetTo: Int)
        case epochChanged(resetTo: Int)
        case missingEpoch(resetTo: Int)
    }

    private var lastSeenSeqBySession: [String: Int] = [:]
    private var runtimeEpochBySession: [String: String] = [:]

    init() {}

    mutating func seedLastSeenSeq(sessionId: String, value: Int) {
        lastSeenSeqBySession[sessionId] = value
    }

    mutating func seedRuntimeEpoch(sessionId: String, value: String?) {
        if let value, !value.isEmpty {
            runtimeEpochBySession[sessionId] = value
        } else {
            runtimeEpochBySession.removeValue(forKey: sessionId)
        }
    }

    func lastSeenSeq(sessionId: String) -> Int {
        lastSeenSeqBySession[sessionId] ?? 0
    }

    func runtimeEpoch(sessionId: String) -> String? {
        runtimeEpochBySession[sessionId]
    }

    mutating func consumeLiveSeq(sessionId: String, seq: Int) -> Bool {
        let current = lastSeenSeqBySession[sessionId] ?? 0
        guard seq > current else { return false }
        lastSeenSeqBySession[sessionId] = seq
        return true
    }

    mutating func catchUpDecision(
        sessionId: String,
        currentSeq: Int,
        runtimeEpoch: String? = nil
    ) -> CatchUpDecision {
        if let runtimeEpoch {
            let storedEpoch = runtimeEpochBySession[sessionId]
            if storedEpoch == nil {
                runtimeEpochBySession[sessionId] = runtimeEpoch
                // A persisted seq without an epoch is unsafe to apply to this
                // ring. Reset to 0 so bootstrap events on the new ring are not
                // rejected. A zero cursor is a first observation, not a stale seq.
                let lastSeen = lastSeenSeqBySession[sessionId] ?? 0
                if lastSeen > 0 {
                    lastSeenSeqBySession[sessionId] = 0
                    return .missingEpoch(resetTo: 0)
                }
            } else if storedEpoch != runtimeEpoch {
                lastSeenSeqBySession[sessionId] = 0
                runtimeEpochBySession[sessionId] = runtimeEpoch
                return .epochChanged(resetTo: 0)
            }
        }

        let lastSeen = lastSeenSeqBySession[sessionId] ?? 0

        if currentSeq < lastSeen {
            lastSeenSeqBySession[sessionId] = currentSeq
            return .seqRegression(resetTo: currentSeq)
        }

        if currentSeq == lastSeen {
            return .noGap
        }

        return .fetchSince(lastSeen)
    }

    mutating func applyCatchUpProgress(sessionId: String, seq: Int) {
        let current = lastSeenSeqBySession[sessionId] ?? 0
        if seq > current {
            lastSeenSeqBySession[sessionId] = seq
        }
    }
}
