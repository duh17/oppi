import Foundation

/// Per-device record of when each session's outcome was last seen.
///
/// A `done` or `error` program status is unseen while its `since` is newer than
/// the time this device last saw the session. The ledger is the only seen
/// mechanism: opening a session's chat or a thread marks sessions seen, and
/// every status surface reads `seenAt(for:)`.
struct SessionSeenLedger: Equatable, Sendable {
    /// Outcomes that began before this are seen. The device has no record of
    /// them, and a fresh launch must not paint every earlier run Done.
    let baseline: Date
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
}
