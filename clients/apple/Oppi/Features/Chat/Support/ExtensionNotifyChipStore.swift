import Foundation
import Observation

/// Clock seam for the notify-chip auto-dismiss timer.
@MainActor
struct ExtensionNotifyClock {
    var now: () -> ContinuousClock.Instant = { ContinuousClock().now }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// Per-session, ephemeral extension `notify` chip state.
///
/// App-originated `extensionToast` sheets are a separate path.
@MainActor
@Observable
final class ExtensionNotifyChipStore {
    static let autoDismissDuration: Duration = .seconds(6)
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

    private var remaining: [String: Duration] = [:]
    private var startedAt: [String: ContinuousClock.Instant] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let clock: ExtensionNotifyClock

    init(clock: ExtensionNotifyClock = ExtensionNotifyClock()) {
        self.clock = clock
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
        remaining[sessionId] = Self.autoDismissDuration
        restartTimerIfNeeded(sessionId: sessionId)
    }

    func setExpanded(_ expanded: Bool, sessionId: String) {
        guard var session = states[sessionId], session.isExpanded != expanded else { return }
        session.isExpanded = expanded
        states[sessionId] = session
        if expanded {
            pauseTimer(sessionId: sessionId)
        } else {
            restartTimerIfNeeded(sessionId: sessionId)
        }
    }

    /// Chat for this session is no longer on screen. Collapse so auto-dismiss
    /// can run; entries stay until the timer fires, dismiss, or session end.
    func collapseForHiddenChat(sessionId: String) {
        setExpanded(false, sessionId: sessionId)
    }

    func dismiss(sessionId: String) {
        cancelTimer(sessionId: sessionId)
        states.removeValue(forKey: sessionId)
        remaining.removeValue(forKey: sessionId)
        startedAt.removeValue(forKey: sessionId)
    }

    private func pauseTimer(sessionId: String) {
        if let start = startedAt[sessionId] {
            let elapsed = clock.now() - start
            let current = remaining[sessionId] ?? .zero
            remaining[sessionId] = current > elapsed ? current - elapsed : .zero
        }
        startedAt[sessionId] = nil
        cancelTimer(sessionId: sessionId)
    }

    private func restartTimerIfNeeded(sessionId: String) {
        guard states[sessionId] != nil else { return }
        guard states[sessionId]?.isExpanded != true else { return }

        cancelTimer(sessionId: sessionId)
        let duration = remaining[sessionId] ?? Self.autoDismissDuration
        if duration <= .zero {
            dismiss(sessionId: sessionId)
            return
        }

        startedAt[sessionId] = clock.now()
        tasks[sessionId] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.dismiss(sessionId: sessionId)
        }
    }

    private func cancelTimer(sessionId: String) {
        tasks.removeValue(forKey: sessionId)?.cancel()
    }
}
