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
    }

    private var lastSeenSeqBySession: [String: Int] = [:]

    init() {}

    mutating func seedLastSeenSeq(sessionId: String, value: Int) {
        lastSeenSeqBySession[sessionId] = value
    }

    func lastSeenSeq(sessionId: String) -> Int {
        lastSeenSeqBySession[sessionId] ?? 0
    }

    mutating func consumeLiveSeq(sessionId: String, seq: Int) -> Bool {
        let current = lastSeenSeqBySession[sessionId] ?? 0
        guard seq > current else { return false }
        lastSeenSeqBySession[sessionId] = seq
        return true
    }

    mutating func catchUpDecision(sessionId: String, currentSeq: Int) -> CatchUpDecision {
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
