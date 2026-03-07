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
        "approval required",
        "attention needed",
        "session ended",
        "done",
    ]

    static func primarySymbol(for state: PiSessionAttributes.ContentState) -> String {
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

    static func phaseLabel(_ phase: SessionPhase) -> String {
        switch phase {
        case .working: return "Working"
        case .awaitingReply: return "Your turn"
        case .needsApproval: return "Approval"
        case .error: return "Attention"
        case .ended: return "Done"
        }
    }

    static func phaseShortLabel(_ phase: SessionPhase) -> String {
        switch phase {
        case .working: return "Run"
        case .awaitingReply: return "Reply"
        case .needsApproval: return "Ask"
        case .error: return "Err"
        case .ended: return "Done"
        }
    }

    static func phaseIcon(_ phase: SessionPhase) -> String {
        switch phase {
        case .working: return "waveform.path.ecg"
        case .awaitingReply: return "bubble.left.fill"
        case .needsApproval: return "exclamationmark.shield.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .ended: return "checkmark.circle.fill"
        }
    }

    static func phaseColor(_ phase: SessionPhase) -> Color {
        switch phase {
        case .working:
            return Color(red: 0.98, green: 0.79, blue: 0.24)
        case .awaitingReply:
            return Color(red: 0.35, green: 0.86, blue: 0.62)
        case .needsApproval:
            return Color(red: 0.99, green: 0.56, blue: 0.22)
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
            case .awaitingReply:
                return "Awaiting input"
            case .needsApproval:
                let approvals = max(state.pendingApprovalCount, 1)
                return approvals == 1 ? "1 approval pending" : "\(approvals) approvals pending"
            case .error:
                return "Needs attention"
            case .ended:
                return "Done"
            }
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
        if normalized == phaseLabel(state.primaryPhase).lowercased() {
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
