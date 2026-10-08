import Foundation

/// Roll-up of a record tree's statuses: a thread (root session plus delegated
/// sessions) or an SSH-terminal record tree (root record plus child records).
///
/// The spec defines no roll-up ("the terminal decides"), so this is the one
/// place Oppi decides. The root keeps its own status; the counts cover the
/// other members, so the root never counts twice.
struct SessionStatusRollup: Equatable, Sendable {
    /// Root's own status, when the tree has a loaded root.
    let root: SessionStatusKind?
    /// Statuses of the members other than the root.
    private let others: [SessionStatusKind: Int]

    init(root: SessionStatusKind?, others: some Sequence<SessionStatusKind>) {
        self.root = root
        self.others = others.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Members other than the root with this status.
    func count(_ kind: SessionStatusKind) -> Int {
        others[kind] ?? 0
    }

    /// Blocked kinds in headline order: a permission gates tool use, then sign-in, then a question.
    private static let blockedPrecedence: [SessionStatusKind] = [.needsApproval, .signIn, .question]
    /// Chip and headline order. Seen done/error are already Idle, so only unseen outcomes rank above rest.
    private static let precedence: [SessionStatusKind] =
        blockedPrecedence + [.working, .error, .done, .idle, .stopped]

    /// What the whole tree is doing: blocked (with its kind) > working > error > done > idle > stopped.
    /// Nil for an empty tree.
    var headline: SessionStatusKind? {
        Self.precedence.first { kind in root == kind || count(kind) > 0 }
    }

    struct Chip: Equatable, Sendable, Identifiable {
        let kind: SessionStatusKind
        let count: Int
        let text: String

        var id: SessionStatusKind { kind }
    }

    /// One chip per non-empty state, in headline order: "1 needs approval · 2 working ·
    /// 1 failed · 3 done · 4 finished".
    var chips: [Chip] {
        Self.precedence.compactMap { kind in
            let count = count(kind)
            return count > 0 ? Chip(kind: kind, count: count, text: Self.chipText(kind, count: count)) : nil
        }
    }

    /// The root's own chip text, e.g. "Root: Idle".
    var rootChipText: String? {
        root.map { "Root: \($0.label)" }
    }

    /// Chips joined for a compact line.
    var summaryText: String {
        chips.map(\.text).joined(separator: " · ")
    }

    static func chipText(_ kind: SessionStatusKind, count: Int) -> String {
        let one = count == 1
        return switch kind {
        case .needsApproval: "\(count) \(one ? "needs" : "need") approval"
        case .signIn: "\(count) \(one ? "needs" : "need") sign-in"
        case .question: "\(count) \(one ? "question" : "questions")"
        case .working: "\(count) working"
        case .error: "\(count) failed"
        case .done: "\(count) done"
        case .idle: "\(count) idle"
        case .stopped: "\(count) finished"
        }
    }
}

extension SessionThreadRollup {
    /// Roll-up of this thread. `status` resolves each member, so callers supply this
    /// device's seen state and pending asks.
    func statusRollup(status: (Session) -> SessionStatusKind) -> SessionStatusRollup {
        SessionStatusRollup(root: status(root), others: descendants.map(status))
    }
}
