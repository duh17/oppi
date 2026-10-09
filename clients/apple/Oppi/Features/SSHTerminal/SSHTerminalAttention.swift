import Foundation
import Observation
import SwiftUI

// What a host program raises for the person in this terminal, from every
// source, and which of it floats over the grid.
//
//   engine effect callbacks ──► sources ──► SSHTerminalNotice ──► SSHTerminalAttention ──► card, haptic
//   (OSC 7501, OSC 9/777, BEL)  (stores)    (one value per source) (order, dismissal)
//
// Adding a source (Kitty OSC 99, Herdr's blocked agents, …) is: its store or
// feed, one `SSHTerminalNotice` case with its slot, its place in `candidates`,
// and its copy in `SSHTerminalNoticeCard`.

/// A one-shot message a host program raised. Unlike an OSC 7501 record it has
/// no state that settles: it shows once and goes.
struct SSHTerminalAlert: Hashable, Sendable, Identifiable {
    enum Source: Hashable, Sendable {
        /// OSC 9 (iTerm2) or OSC 777 `notify` (rxvt, Ghostty).
        case notification
        /// BEL. Shells ring it for ordinary things such as a failed completion,
        /// so it is felt and never covers the grid.
        case bell
    }

    /// Arrival order in this terminal; two alerts never share it.
    let id: UInt64
    let source: Source
    /// Remote, title-grade text. Either may be empty, never both for a notification.
    let title: String
    let body: String
}

/// One-shot alerts copied out of the engine's effect callbacks. Plain Swift
/// state with no path back into the terminal, like
/// `SSHTerminalProgramStatusStore`. Only the newest of each source matters,
/// and a burst counts once (`SSHTerminalNotice.burstInterval`).
@MainActor @Observable
final class SSHTerminalAlertFeed {
    private(set) var notification: SSHTerminalAlert?
    private(set) var bell: SSHTerminalAlert?
    @ObservationIgnored private var serial: UInt64 = 0
    @ObservationIgnored private var lastNotification: ContinuousClock.Instant?
    @ObservationIgnored private var lastBell: ContinuousClock.Instant?

    /// A notification within the burst interval of the previous one updates
    /// its text and keeps its id, so a program printing OSC 9 in a loop is
    /// one notice: it cannot undo a dismissal, hold the card up, or repeat
    /// the haptic. The same words after a pause are a new notification.
    func notify(title: String, body: String, at now: ContinuousClock.Instant = .now) {
        let title = SSHTerminalDisplayText.sanitized(title, limit: SSHTerminalDisplayText.titleLimit)
        let body = SSHTerminalDisplayText.sanitized(body, limit: SSHTerminalDisplayText.messageLimit)
        guard !title.isEmpty || !body.isEmpty else { return }
        defer { lastNotification = now }
        if let current = notification, let lastNotification,
           lastNotification.duration(to: now) < SSHTerminalNotice.burstInterval {
            notification = SSHTerminalAlert(id: current.id, source: .notification, title: title, body: body)
            return
        }
        notification = next(.notification, title: title, body: body)
    }

    func ring(at now: ContinuousClock.Instant = .now) {
        if let lastBell, lastBell.duration(to: now) < SSHTerminalNotice.burstInterval { return }
        lastBell = now
        bell = next(.bell, title: "", body: "")
    }

    private func next(_ source: SSHTerminalAlert.Source, title: String, body: String) -> SSHTerminalAlert {
        serial &+= 1
        return SSHTerminalAlert(id: serial, source: source, title: title, body: body)
    }
}

/// What the floating card can show: one value per source, so ordering,
/// dismissal, and feedback read one type.
enum SSHTerminalNotice: Hashable, Sendable {
    /// A program waits on the person (OSC 7501 blocked).
    case blocked(SSHTerminalBlockedNotice)
    /// A program said something once (OSC 9, OSC 777).
    case alert(SSHTerminalAlert)

    /// Reports closer together than this are one burst. Each source counts a
    /// burst as one notice, and the warning haptic repeats no faster.
    static let burstInterval: Duration = .seconds(1)

    /// Which notice this is, apart from its text. Dismissal, expiry, and the
    /// haptic follow the key, so live text updates never restart them.
    enum Key: Hashable, Sendable {
        case blocked(recordID: String, notice: UInt64)
        case alert(UInt64)
    }

    var key: Key {
        switch self {
        case .blocked(let blocked): .blocked(recordID: blocked.recordID, notice: blocked.notice)
        case .alert(let alert): .alert(alert.id)
        }
    }

    /// Each source dismisses on its own, so folding away a notification never
    /// brings back a blocked card the person already folded.
    enum Slot: Hashable, Sendable {
        case blocked
        case alert
    }

    var slot: Slot {
        switch self {
        case .blocked: .blocked
        case .alert: .alert
        }
    }

    /// Time on screen without a tap. A blocked card stays while the program waits.
    var lifetime: Duration? {
        switch self {
        case .blocked: nil
        case .alert: .seconds(6)
        }
    }
}

/// Which notice floats over the terminal grid and what the person folded
/// away. Sources decide what is true; this only orders and dismisses.
struct SSHTerminalAttention {
    private var dismissed = [SSHTerminalNotice.Slot: SSHTerminalNotice.Key]()

    /// Toolbar glyph frame, for the card to fold into. Written from layout and
    /// never observed, so a frame change does not refresh the screen.
    let glyphFrame = SSHTerminalGlyphFrame()
    /// The card's layout frame. Changes only when its layout does.
    var cardFrame: CGRect = .zero

    /// The first candidate the person has not folded away. `candidates` is
    /// in priority order.
    func notice(from candidates: [SSHTerminalNotice]) -> SSHTerminalNotice? {
        candidates.first { dismissed[$0.slot] != $0.key }
    }

    /// Stays down until its source raises a different notice.
    mutating func dismiss(_ key: SSHTerminalNotice.Key) {
        dismissed[Self.slot(of: key)] = key
    }

    private static func slot(of key: SSHTerminalNotice.Key) -> SSHTerminalNotice.Slot {
        switch key {
        case .blocked: .blocked
        case .alert: .alert
        }
    }

    /// Every source's current notice, highest priority first: a program that
    /// waits on the person outranks a one-shot message.
    @MainActor
    static func candidates(
        programStatus: SSHTerminalProgramStatusStore,
        alerts: SSHTerminalAlertFeed,
        isStopped: Bool
    ) -> [SSHTerminalNotice] {
        var candidates = [SSHTerminalNotice]()
        if let blocked = SSHTerminalProgramStatusPresentation.blockedNotice(
            store: programStatus, isStopped: isStopped, seenAt: SSHTerminalProgramStatusPresentation.seenAt
        ) {
            candidates.append(.blocked(blocked))
        }
        if let alert = alerts.notification { candidates.append(.alert(alert)) }
        return candidates
    }
}

/// What the person feels and how long a notice stays: a warning haptic for
/// each new card, a light tap for a bell, and a one-shot notice folding itself
/// away after its lifetime. A blocked card stays while the program waits.
struct SSHTerminalAttentionFeedback: ViewModifier {
    let notice: SSHTerminalNotice?
    let bell: SSHTerminalAlert?
    let expire: (SSHTerminalNotice.Key) -> Void

    @State private var warnings = 0
    @State private var lastWarning: ContinuousClock.Instant?

    func body(content: Content) -> some View {
        content
            .task(id: notice?.key) {
                guard let notice, let lifetime = notice.lifetime else { return }
                try? await Task.sleep(for: lifetime)
                if !Task.isCancelled { expire(notice.key) }
            }
            // A program that blocks and unblocks in a loop raises a new card
            // each time; the haptic still repeats no faster than one burst.
            .onChange(of: notice?.key) { _, key in
                let now = ContinuousClock.now
                guard key != nil else { return }
                if let lastWarning, lastWarning.duration(to: now) < SSHTerminalNotice.burstInterval { return }
                lastWarning = now
                warnings += 1
            }
            .sensoryFeedback(.warning, trigger: warnings)
            .sensoryFeedback(.impact(weight: .light), trigger: bell) { _, new in new != nil }
    }
}
