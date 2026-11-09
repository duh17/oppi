import Foundation
import Observation

/// Per-session, ephemeral extension `notify` chip state.
///
/// App-originated `extensionToast` sheets are a separate path.
@MainActor
@Observable
final class ExtensionNotifyChipStore {
    static let maxEntries = 5
    static let fallbackDisplayName = "Extension"

    struct Entry: Equatable, Identifiable, Sendable {
        let id: UUID
        let message: String
        let notifyType: String?
        let extensionDisplayName: String
    }

    struct SessionState: Equatable {
        var entries: [Entry]
        var isExpanded: Bool

        var newest: Entry { entries[0] }
        var count: Int { entries.count }
    }

    private(set) var states: [String: SessionState] = [:]

    @ObservationIgnored private var timer: NoticeDismissTimer<String>!

    init(environment: NoticeTimerEnvironment = NoticeTimerEnvironment()) {
        timer = NoticeDismissTimer(environment: environment) { [weak self] sessionId in
            self?.dismiss(sessionId: sessionId)
        }
    }

    func state(for sessionId: String) -> SessionState? {
        states[sessionId]
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

        let entry = Entry(
            id: UUID(),
            message: trimmed,
            notifyType: notifyType,
            extensionDisplayName: resolvedName
        )
        var session = states[sessionId] ?? SessionState(entries: [], isExpanded: false)
        session.entries.insert(entry, at: 0)
        if session.entries.count > Self.maxEntries {
            session.entries = Array(session.entries.prefix(Self.maxEntries))
        }
        states[sessionId] = session
        timer.start(sessionId, message: trimmed)
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
}
