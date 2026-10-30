import Foundation

/// What a thread strip says about the states of its members: the live dots and the counts line.
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

        /// The bucket of one member, from the list's classification: no section means stopped, and a live
        /// member reads by the status the list resolved for it.
        init(_ classification: SessionListClassification) {
            guard let section = classification.section else {
                self = .stopped
                return
            }
            // A live member is never resolved as stopped or as working-through-Your-Turn; both fall to idle.
            self.init(section == .working ? SessionStatusKind.working : classification.status)
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

        /// Active members (working, needing the person, or in error) get a dot. Settled ones are only counted.
        var showsDot: Bool {
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
    /// One entry per active member, most urgent first (needs you, error, working), at most `maxDots`.
    let dots: [Bucket]
    /// Active members past `maxDots`.
    let hiddenDotCount: Int

    /// `classify` is the list's classification of a member, so the stopped count is the thread's stopped
    /// fold's count and nothing here depends on this device's seen state.
    init(rollup: SessionThreadRollup, classify: (Session) -> SessionListClassification) {
        var countByBucket: [Bucket: Int] = [:]
        for member in rollup.descendants {
            countByBucket[Bucket(classify(member)), default: 0] += 1
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

    /// Whether a member is working, needing the person, or in error: the strip draws its dots, headline,
    /// and full height only then.
    var isActive: Bool { !dots.isEmpty }

    /// "3 working · 1 needs you · 137 stopped".
    var text: String {
        counts.map(\.text).joined(separator: " · ")
    }
}
