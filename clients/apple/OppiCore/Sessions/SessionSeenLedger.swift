import Foundation

/// Per-device record of when each session's outcome was last seen.
///
/// A `done` or `error` program status is unseen while its `since` is newer than
/// the time this device last saw the session. The ledger is the only seen
/// mechanism: opening a session's chat or a thread marks sessions seen, and
/// every status surface reads `seenAt(for:)`. The app persists it per server,
/// so an unopened result stays Done across relaunches.
struct SessionSeenLedger: Codable, Equatable, Sendable {
    /// Outcomes that began before this are seen. The device has no record of
    /// them, and the first launch must not paint every earlier run Done.
    private(set) var baseline: Date
    private var seenAtBySession: [String: Date] = [:]

    init(baseline: Date = .distantPast) {
        self.baseline = baseline
    }

    /// When this device last saw the session, never earlier than the baseline.
    func seenAt(for sessionId: String) -> Date {
        max(baseline, seenAtBySession[sessionId] ?? baseline)
    }

    /// Sessions only move forward: marking an earlier time never makes a seen outcome unseen.
    mutating func markSeen(_ sessionId: String, at date: Date) {
        guard date > seenAt(for: sessionId) else { return }
        seenAtBySession[sessionId] = date
    }

    mutating func forget(_ sessionId: String) {
        seenAtBySession.removeValue(forKey: sessionId)
    }

    /// Bound the stored ledger: outcomes from before `cutoff` count as seen, and
    /// watermarks at or before the new baseline carry no information.
    mutating func expire(before cutoff: Date) {
        guard cutoff > baseline else { return }
        baseline = cutoff
        seenAtBySession = seenAtBySession.filter { $0.value > cutoff }
    }
}
