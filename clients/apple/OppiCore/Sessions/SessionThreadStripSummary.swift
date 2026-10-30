import Foundation

/// What a thread strip says about the states of its members: the live dots
/// and the counts line.
///
/// Counts and dots cover the members other than the root, as the strip's status
/// counts always did: the root row above the strip already shows its own status.
/// Words follow the session list's status words (`SessionStatusKind.label`,
/// lowercased), except that every blocked kind reads "needs you".
struct SessionThreadStripSummary: Equatable, Sendable {
    /// The most dots a strip draws; the rest are counted as "+N".
    static let maxDots = 12

    /// A state the strip counts. The blocked kinds (approval, question, sign-in) share one.
    enum Bucket: CaseIterable, Sendable {
        case working, needsYou, error, done, idle, stopped

        init(_ kind: SessionStatusKind) {
            switch kind {
            case .working: self = .working
            case .needsApproval, .question, .signIn: self = .needsYou
            case .error: self = .error
            case .done: self = .done
            case .idle: self = .idle
            case .stopped: self = .stopped
            }
        }

        /// The status whose tint and word this bucket uses.
        var kind: SessionStatusKind {
            switch self {
            case .working: .working
            case .needsYou: .needsApproval
            case .error: .error
            case .done: .done
            case .idle: .idle
            case .stopped: .stopped
            }
        }

        /// Members still going, or waiting on the person, get a dot. Settled ones are only counted.
        var showsDot: Bool {
            switch self {
            case .working, .needsYou, .error: true
            case .done, .idle, .stopped: false
            }
        }

        func text(count: Int) -> String {
            switch self {
            case .needsYou: count == 1 ? "1 needs you" : "\(count) need you"
            case .working, .error, .done, .idle, .stopped: "\(count) \(kind.label.lowercased())"
            }
        }
    }

    struct Count: Equatable, Sendable {
        let bucket: Bucket
        let count: Int

        var text: String { bucket.text(count: count) }
    }

    /// One entry per non-empty state: working, needs you, error, done, idle, stopped.
    let counts: [Count]
    /// One entry per active member, most urgent first (needs you, error, working), at most `maxDots`.
    let dots: [Bucket]
    /// Active members past `maxDots`.
    let hiddenDotCount: Int

    init(rollup: SessionThreadRollup, status: (Session) -> SessionStatusKind) {
        var countByBucket: [Bucket: Int] = [:]
        for member in rollup.descendants {
            countByBucket[Bucket(status(member)), default: 0] += 1
        }
        counts = Bucket.allCases.compactMap { bucket in
            countByBucket[bucket].map { Count(bucket: bucket, count: $0) }
        }
        let active = [Bucket.needsYou, .error, .working].flatMap { bucket in
            Array(repeating: bucket, count: countByBucket[bucket] ?? 0)
        }
        dots = Array(active.prefix(Self.maxDots))
        hiddenDotCount = active.count - dots.count
    }

    /// "3 working · 1 needs you · 23 done · 101 stopped".
    var text: String {
        counts.map(\.text).joined(separator: " · ")
    }
}
