import Foundation
import Observation

/// Per-session, ephemeral notices above the composer: an extension's `ctx.ui.notify()` and
/// the session's own launch warnings, on one pill and one dismiss policy.
///
/// App-originated `extensionToast` sheets are a separate path.
@MainActor
@Observable
final class ExtensionNotifyChipStore {
    static let maxEntries = 5
    static let fallbackDisplayName = "Extension"

    /// Who an entry speaks for. The pill titles and the drawer's labels come from here, never
    /// from the message text: the text is the server's or an extension's, and a new source
    /// must not need the view changed.
    enum Source: Equatable, Sendable {
        case extensionNotify(name: String)
        /// The session's launch warnings: resources the server dropped instead of starting with.
        case session
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let id: UUID
        let message: String
        let notifyType: String?
        let source: Source

        /// The pill's short title.
        var title: String {
            switch source {
            case .extensionNotify(let name): name
            case .session: String(localized: "Warning")
            }
        }

        /// Where the drawer says the entry came from.
        var originLabel: String {
            switch source {
            case .extensionNotify(let name): String(localized: "From extension · \(name)")
            case .session: String(localized: "From this session")
            }
        }

        /// Who it is from and what it says, for VoiceOver on the collapsed pill.
        var voiceLabel: String {
            switch source {
            case .extensionNotify(let name): String(localized: "Notification from \(name): \(message)")
            case .session: String(localized: "Session warning: \(message)")
            }
        }
    }

    struct SessionState: Equatable {
        var entries: [Entry]
        var isExpanded: Bool

        var newest: Entry { entries[0] }
        var count: Int { entries.count }
    }

    private(set) var states: [String: SessionState] = [:]

    /// The warnings each session has already shown. A repaint, a chat re-entry, or a dismissed
    /// pill must not bring them back, so the set, not the chip's presence, is the record.
    @ObservationIgnored private var announcedWarnings: [String: [String]] = [:]

    @ObservationIgnored private var timer: NoticeDismissTimer<String>!

    init(environment: NoticeTimerEnvironment = NoticeTimerEnvironment()) {
        timer = NoticeDismissTimer(environment: environment) { [weak self] sessionId in
            self?.dismiss(sessionId: sessionId)
        }
    }

    func state(for sessionId: String) -> SessionState? {
        states[sessionId]
    }

    /// The warnings worth showing: trimmed, blank ones dropped, each once (the server repeats a
    /// launch warning across its records).
    static func messages(from warnings: [String]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for warning in warnings ?? [] {
            let trimmed = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    func apply(
        message: String?,
        notifyType: String?,
        displayName: String?,
        sessionId: String
    ) {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }

        let resolvedName: String = {
            guard let displayName else { return Self.fallbackDisplayName }
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? Self.fallbackDisplayName : name
        }()

        insert(
            Entry(
                id: UUID(),
                message: trimmed,
                notifyType: notifyType,
                source: .extensionNotify(name: resolvedName)
            ),
            sessionId: sessionId
        )
        timer.start(sessionId, message: trimmed)
    }

    /// The session's launch warnings, on the chip an extension's notice uses: the pill keeps
    /// their text for a tap, and the notice timer drops them like any other notice. The
    /// warnings show once per session, however often the chat or the footer repaints.
    func applyWarnings(_ warnings: [String]?, sessionId: String) {
        let messages = Self.messages(from: warnings)
        guard !messages.isEmpty, announcedWarnings[sessionId] != messages else { return }
        announcedWarnings[sessionId] = messages
        // One entry: the pill counts notices, and every warning stays readable in the drawer.
        let message = messages.joined(separator: "\n\n")
        insert(
            Entry(id: UUID(), message: message, notifyType: "warning", source: .session),
            sessionId: sessionId
        )
        timer.start(sessionId, message: message)
    }

    func setExpanded(_ expanded: Bool, sessionId: String) {
        guard var session = states[sessionId], session.isExpanded != expanded else { return }
        session.isExpanded = expanded
        states[sessionId] = session
        timer.setPaused(expanded, for: sessionId)
    }

    /// Chat for this session is no longer on screen. Collapse so auto-dismiss
    /// can run; entries stay until the timer fires, dismiss, or session end.
    func collapseForHiddenChat(sessionId: String) {
        setExpanded(false, sessionId: sessionId)
    }

    func dismiss(sessionId: String) {
        timer.cancel(sessionId)
        states.removeValue(forKey: sessionId)
    }

    private func insert(_ entry: Entry, sessionId: String) {
        var session = states[sessionId] ?? SessionState(entries: [], isExpanded: false)
        session.entries.insert(entry, at: 0)
        if session.entries.count > Self.maxEntries {
            session.entries = Array(session.entries.prefix(Self.maxEntries))
        }
        states[sessionId] = session
    }
}
