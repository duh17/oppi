import Foundation

/// What a thread strip says about the states of its members: the status line (a dot for each member that
/// needs the person or is in error, then one working mark for the working ones) and the counts line.
///
/// Counts and dots cover the members other than the root, as the strip's status counts always did: the
/// root row above the strip already shows its own status.
///
/// Both read the list's own classification of a member, without this device's seen state
/// (`SessionListPresentation.classify`). A member counts as stopped exactly when the thread's own listing
/// folds it into stopped (`SessionThreadRollup.listing`), so the strip's stopped count is the fold's count;
/// every other member is live and reads as needs you (any blocked kind), error, working, or idle. Opening
/// or seeing a member therefore never changes the strip, and a settled outcome is idle here whether or not
/// the person has seen it: the strip has no "done".
///
/// The words are the session list's status words, shared with the SSH terminal's record-tree summary
/// (`SessionStatusRollup.chipText`), except that every blocked kind reads "needs you".
struct SessionThreadStripSummary: Equatable, Sendable {
    /// The most dots a strip draws; the rest are counted as "+N".
    static let maxDots = 12

    /// A state the strip counts. The blocked kinds (approval, question, sign-in) share one.
    enum Bucket: CaseIterable, Sendable {
        case working, needsYou, error, idle, stopped

        /// The bucket a status reads as. A settled outcome (done, idle) is one quiet state here.
        init(_ kind: SessionStatusKind) {
            switch kind {
            case .working: self = .working
            case .needsApproval, .question, .signIn: self = .needsYou
            case .error: self = .error
            case .done, .idle: self = .idle
            case .stopped: self = .stopped
            }
        }

        /// The status whose tint and word this bucket uses.
        var kind: SessionStatusKind {
            switch self {
            case .working: .working
            case .needsYou: .needsApproval
            case .error: .error
            case .idle: .idle
            case .stopped: .stopped
            }
        }

        /// Active members (working, needing the person, or in error) are drawn on the status line: a dot,
        /// or the working mark. Settled ones are only counted.
        var isDrawn: Bool {
            switch self {
            case .working, .needsYou, .error: true
            case .idle, .stopped: false
            }
        }

        /// The words every status summary shares (`SessionStatusRollup.chipText`), with the blocked
        /// kinds folded into "needs you".
        func text(count: Int) -> String {
            switch self {
            case .needsYou: count == 1 ? "1 needs you" : "\(count) need you"
            case .working, .error, .idle, .stopped: SessionStatusRollup.chipText(kind, count: count)
            }
        }
    }

    struct Count: Equatable, Sendable {
        let bucket: Bucket
        let count: Int

        var text: String { bucket.text(count: count) }
    }

    /// One entry per non-empty state: working, needs you, error, idle, stopped.
    let counts: [Count]
    /// One entry per member that needs the person or is in error, most urgent first, at most `maxDots`.
    let dots: [Bucket]
    /// Those members past `maxDots`.
    let hiddenDotCount: Int
    /// Working members: the strip draws one working mark for all of them, with this count beside it.
    let workingCount: Int

    /// `classify` is the list's classification of a member, so the stopped count is the thread's stopped
    /// fold's count and nothing here depends on this device's seen state.
    init(rollup: SessionThreadRollup, classify: (Session) -> SessionListClassification) {
        var countByBucket: [Bucket: Int] = [:]
        for member in rollup.descendants {
            // `settledKind` is the strip's one rule for what a member reads: stopped with no section, idle
            // for a settled outcome.
            countByBucket[Bucket(classify(member).settledKind), default: 0] += 1
        }
        counts = Bucket.allCases.compactMap { bucket in
            countByBucket[bucket].map { Count(bucket: bucket, count: $0) }
        }
        let marked = [Bucket.needsYou, .error].flatMap { bucket in
            Array(repeating: bucket, count: countByBucket[bucket] ?? 0)
        }
        dots = Array(marked.prefix(Self.maxDots))
        hiddenDotCount = marked.count - dots.count
        workingCount = countByBucket[.working] ?? 0
    }

    /// Whether a member is working, needing the person, or in error: the strip draws its status line, and
    /// keeps the Agents beside it, only then. A blocked member is always active, so the blocked line and
    /// the status line appear and disappear together.
    var isActive: Bool { !dots.isEmpty || workingCount > 0 }

    /// "3 working · 1 needs you · 137 stopped".
    var text: String {
        counts.map(\.text).joined(separator: " · ")
    }

    /// The counts the status line does not already draw: idle and stopped, in bucket order ("1 idle · 102
    /// stopped"). Working, needs you, and error are what the working mark and the dots say, so the drawn line
    /// leaves them out instead of repeating them in words. A settled thread draws no status line and
    /// counts nothing else, so this is its whole counts line.
    var quietText: String {
        counts.filter { !$0.bucket.isDrawn }.map(\.text).joined(separator: " · ")
    }
}
