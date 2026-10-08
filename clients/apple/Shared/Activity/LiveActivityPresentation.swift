import SwiftUI

struct LiveActivityChangeStatsSummary {
    let mutatingToolCalls: Int
    let filesChanged: Int
    let addedLines: Int
    let removedLines: Int
}

enum LiveActivityPresentation {
    private static let genericActivities: Set<String> = [
        "working",
        "your turn",
        "attention needed",
        "session ended",
        "done",
        "needs approval",
        "question",
        "sign-in",
    ]

    static func primarySymbol(for state: PiSessionAttributes.ContentState) -> String {
        if state.primaryPhase == .blocked {
            switch state.primaryBlockedKind {
            case "permission": return "hand.raised.fill"
            case "auth": return "lock.fill"
            default: return "questionmark.bubble.fill"
            }
        }
        if state.primaryPhase == .working,
           let tool = state.primaryTool,
           !tool.isEmpty {
            return toolSymbol(tool)
        }
        return phaseIcon(state.primaryPhase)
    }

    static func toolSymbol(_ tool: String) -> String {
        switch normalizedToolName(tool) {
        case "bash": return "terminal.fill"
        case "read": return "doc.text.fill"
        case "write": return "square.and.pencil"
        case "edit": return "pencil.and.scribble"
        default: return "hammer.fill"
        }
    }

    /// Status text for the primary session: a blocked session names what it waits for.
    /// An unknown kind reads as a question.
    static func statusLabel(_ state: PiSessionAttributes.ContentState) -> String {
        guard state.primaryPhase == .blocked else { return phaseLabel(state.primaryPhase) }
        switch state.primaryBlockedKind {
        case "permission": return "Needs approval"
        case "auth": return "Sign-in"
        default: return "Question"
        }
    }

    static func statusShortLabel(_ state: PiSessionAttributes.ContentState) -> String {
        guard state.primaryPhase == .blocked else { return phaseShortLabel(state.primaryPhase) }
        switch state.primaryBlockedKind {
        case "permission": return "Approve"
        case "auth": return "Sign in"
        default: return "Ask"
        }
    }

    static func phaseLabel(_ phase: SessionPhase) -> String {
        switch phase {
        case .working: return "Working"
        case .blocked: return "Needs you"
        case .done: return "Done"
        case .awaitingReply: return "Your turn"
        case .error: return "Attention"
        case .ended: return "Done"
        }
    }

    static func phaseShortLabel(_ phase: SessionPhase) -> String {
        switch phase {
        case .working: return "Run"
        case .blocked: return "Ask"
        case .done: return "Done"
        case .awaitingReply: return "Reply"
        case .error: return "Err"
        case .ended: return "Done"
        }
    }

    static func phaseIcon(_ phase: SessionPhase) -> String {
        switch phase {
        case .working: return "waveform.path.ecg"
        case .blocked: return "exclamationmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .awaitingReply: return "bubble.left.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .ended: return "checkmark.circle.fill"
        }
    }

    static func phaseColor(_ phase: SessionPhase) -> Color {
        switch phase {
        case .working:
            return Color(red: 0.48, green: 0.64, blue: 0.97)
        case .blocked:
            return Color(red: 0.98, green: 0.52, blue: 0.18)
        case .done, .awaitingReply:
            return Color(red: 0.35, green: 0.86, blue: 0.62)
        case .error:
            return Color(red: 0.96, green: 0.37, blue: 0.34)
        case .ended:
            return Color(red: 0.74, green: 0.76, blue: 0.80)
        }
    }

    static func sessionSummary(_ state: PiSessionAttributes.ContentState) -> String {
        if state.totalActiveSessions <= 1 {
            switch state.primaryPhase {
            case .working:
                return "1 active"
            case .blocked:
                return "Waiting on you"
            case .done:
                return "Done"
            case .awaitingReply:
                return "Awaiting input"
            case .error:
                return "Needs attention"
            case .ended:
                return "Done"
            }
        }

        if let blocked = state.sessionsBlocked, blocked > 0 {
            return "\(blocked) \(blocked == 1 ? "needs" : "need") you · \(state.totalActiveSessions) active"
        }

        if state.sessionsWorking > 0 {
            return "\(state.sessionsWorking) working · \(state.totalActiveSessions) active"
        }

        if state.sessionsAwaitingReply > 0 {
            return state.sessionsAwaitingReply == 1
                ? "1 awaiting reply"
                : "\(state.sessionsAwaitingReply) awaiting reply"
        }

        return "\(state.totalActiveSessions) active"
    }

    static func centerActivityText(_ state: PiSessionAttributes.ContentState) -> String? {
        guard let raw = state.primaryLastActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let normalized = raw.lowercased()
        if normalized == phaseLabel(state.primaryPhase).lowercased()
            || normalized == statusLabel(state).lowercased() {
            return nil
        }
        if normalized == sessionSummary(state).lowercased() {
            return nil
        }

        return genericActivities.contains(normalized) ? nil : raw
    }

    static func changeStatsSummary(
        _ state: PiSessionAttributes.ContentState
    ) -> LiveActivityChangeStatsSummary? {
        let mutatingTools = max(state.primaryMutatingToolCalls ?? 0, 0)
        guard mutatingTools > 0 else { return nil }

        return LiveActivityChangeStatsSummary(
            mutatingToolCalls: mutatingTools,
            filesChanged: max(state.primaryFilesChanged ?? 0, 0),
            addedLines: max(state.primaryAddedLines ?? 0, 0),
            removedLines: max(state.primaryRemovedLines ?? 0, 0)
        )
    }

    private static func normalizedToolName(_ tool: String) -> String {
        tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
