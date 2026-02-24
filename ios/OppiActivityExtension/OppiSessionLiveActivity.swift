import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Aggregate Live Activity + Dynamic Island UI for Oppi sessions.
struct PiSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiSessionAttributes.self) { context in
            LockScreenView(context: context)
                .widgetURL(deepLinkURL(for: context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: phaseIcon(context.state.primaryPhase))
                            .accessibilityHidden(true)
                        Text(context.state.primarySessionName)
                            .font(.caption.bold())
                            .lineLimit(1)
                    }
                    .foregroundStyle(phaseColor(context.state.primaryPhase))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(context.state.primarySessionName), \(phaseLabel(context.state.primaryPhase))")
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.pendingApprovalCount > 0 {
                        Text("+\(context.state.pendingApprovalCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    } else {
                        Text(phaseLabel(context.state.primaryPhase))
                            .font(.caption2.bold())
                            .foregroundStyle(phaseColor(context.state.primaryPhase))
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if let summary = context.state.topPermissionSummary,
                       !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approval required")
                                .font(.caption.bold())
                            Text(summary)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if let activity = context.state.primaryLastActivity,
                              !activity.isEmpty {
                        Text(activity)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(sessionSummary(context.state))
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Spacer()

                            if context.state.primaryPhase == .working,
                               let start = context.state.sessionStartDate {
                                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let permissionId = context.state.topPermissionId {
                            PermissionActionButtons(permissionId: permissionId)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: phaseIcon(context.state.primaryPhase))
                    .font(.caption2)
                    .foregroundStyle(phaseColor(context.state.primaryPhase))
                    .symbolEffect(.pulse, options: .repeating, isActive: shouldPulse(context.state.primaryPhase))
                    .accessibilityLabel(accessibilitySummary(context.state))
            } compactTrailing: {
                if context.state.pendingApprovalCount > 0 {
                    Text("\(context.state.pendingApprovalCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText())
                        .accessibilityLabel("\(context.state.pendingApprovalCount) pending approvals")
                } else if context.state.primaryPhase == .working,
                          let start = context.state.sessionStartDate {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Session timer")
                } else {
                    Text(phaseShortLabel(context.state.primaryPhase))
                        .font(.caption2.bold())
                        .foregroundStyle(phaseColor(context.state.primaryPhase))
                        .accessibilityLabel(phaseLabel(context.state.primaryPhase))
                }
            } minimal: {
                Image(systemName: phaseIcon(context.state.primaryPhase))
                    .font(.caption2)
                    .foregroundStyle(phaseColor(context.state.primaryPhase))
                    .accessibilityLabel(accessibilitySummary(context.state))
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let context: ActivityViewContext<PiSessionAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: phaseIcon(context.state.primaryPhase))
                            .font(.caption)
                            .foregroundStyle(phaseColor(context.state.primaryPhase))
                            .accessibilityHidden(true)
                        Text(context.state.primarySessionName)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                    }

                    if let summary = context.state.topPermissionSummary,
                       !summary.isEmpty {
                        Text(summary)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } else if let activity = context.state.primaryLastActivity,
                              !activity.isEmpty {
                        Text(activity)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(phaseLabel(context.state.primaryPhase))
                        .font(.caption2.bold())
                        .foregroundStyle(phaseColor(context.state.primaryPhase))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(phaseColor(context.state.primaryPhase).opacity(0.15))
                        .clipShape(Capsule())

                    if context.state.pendingApprovalCount > 0 {
                        Text("\(context.state.pendingApprovalCount) approvals")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    } else {
                        Text(sessionSummary(context.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if context.state.primaryPhase == .working,
                       let start = context.state.sessionStartDate {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Session timer")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary(context.state))

            if let permissionId = context.state.topPermissionId {
                PermissionActionButtons(permissionId: permissionId)
            }
        }
        .padding(16)
    }
}

private struct PermissionActionButtons: View {
    let permissionId: String

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: DenyPermissionIntent(permissionId: permissionId)) {
                Label("Deny", systemImage: "xmark")
                    .font(.caption2.bold())
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityLabel("Deny permission request")

            Button(intent: ApprovePermissionIntent(permissionId: permissionId)) {
                Label("Approve", systemImage: "checkmark")
                    .font(.caption2.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityLabel("Approve permission request")
        }
    }
}

// MARK: - Helpers

private func phaseLabel(_ phase: SessionPhase) -> String {
    switch phase {
    case .working: return "Working"
    case .awaitingReply: return "Your turn"
    case .needsApproval: return "Approval"
    case .error: return "Attention"
    case .ended: return "Idle"
    }
}

private func phaseShortLabel(_ phase: SessionPhase) -> String {
    switch phase {
    case .working: return "Run"
    case .awaitingReply: return "Reply"
    case .needsApproval: return "Ask"
    case .error: return "Err"
    case .ended: return "Idle"
    }
}

private func phaseIcon(_ phase: SessionPhase) -> String {
    switch phase {
    case .working: return "waveform.path.ecg"
    case .awaitingReply: return "bubble.left.fill"
    case .needsApproval: return "exclamationmark.shield.fill"
    case .error: return "exclamationmark.triangle.fill"
    case .ended: return "terminal"
    }
}

private func phaseColor(_ phase: SessionPhase) -> Color {
    switch phase {
    case .working: return .yellow
    case .awaitingReply: return .green
    case .needsApproval: return .orange
    case .error: return .red
    case .ended: return .secondary
    }
}

private func shouldPulse(_ phase: SessionPhase) -> Bool {
    switch phase {
    case .working, .needsApproval:
        return true
    case .awaitingReply, .error, .ended:
        return false
    }
}

private func sessionSummary(_ state: PiSessionAttributes.ContentState) -> String {
    if state.totalActiveSessions <= 1 {
        return phaseLabel(state.primaryPhase)
    }
    if state.sessionsWorking > 0 {
        return "\(state.sessionsWorking) working · \(state.totalActiveSessions) active"
    }
    if state.sessionsAwaitingReply > 0 {
        return "\(state.sessionsAwaitingReply) awaiting reply"
    }
    return "\(state.totalActiveSessions) active"
}

/// VoiceOver summary combining session name, phase, and key details.
private func accessibilitySummary(_ state: PiSessionAttributes.ContentState) -> String {
    var parts = ["\(state.primarySessionName), \(phaseLabel(state.primaryPhase))"]
    if state.pendingApprovalCount > 0 {
        parts.append("\(state.pendingApprovalCount) pending approval\(state.pendingApprovalCount == 1 ? "" : "s")")
    }
    if let activity = state.primaryLastActivity, !activity.isEmpty {
        parts.append(activity)
    }
    return parts.joined(separator: ". ")
}

/// Deep link URL for tapping the Live Activity.
///
/// HIG: "Take people directly to related details and actions."
/// - Permission pending → `oppi://permission/<id>` (navigates to approval UI)
/// - Otherwise → `oppi://session/<id>` (opens the primary session)
private func deepLinkURL(for state: PiSessionAttributes.ContentState) -> URL? {
    if let permissionId = state.topPermissionId,
       let encoded = permissionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
        return URL(string: "oppi://permission/\(encoded)")
    }
    if let sessionId = state.primarySessionId,
       let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
        return URL(string: "oppi://session/\(encoded)")
    }
    return nil
}
