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
                        Image(systemName: primarySymbol(context.state))
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
                    } else if let activity = centerActivityText(context.state) {
                        Text(activity)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if context.state.pendingApprovalCount == 0,
                               let changeSummary = changeStatsSummary(context.state) {
                                ChangeStatsSummaryView(summary: changeSummary)
                            } else {
                                Text(sessionSummary(context.state))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

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
                Image(systemName: primarySymbol(context.state))
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
                } else if let badge = compactChangeBadge(context.state) {
                    Text(badge)
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(phaseColor(context.state.primaryPhase))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel(compactChangeAccessibilityLabel(context.state))
                } else {
                    Text(phaseShortLabel(context.state.primaryPhase))
                        .font(.caption2.bold())
                        .foregroundStyle(phaseColor(context.state.primaryPhase))
                        .accessibilityLabel(phaseLabel(context.state.primaryPhase))
                }
            } minimal: {
                Image(systemName: primarySymbol(context.state))
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
                        Image(systemName: primarySymbol(context.state))
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
                    } else if let activity = centerActivityText(context.state) {
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
                    } else if let changeSummary = changeStatsSummary(context.state) {
                        ChangeStatsSummaryView(summary: changeSummary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
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

private func primarySymbol(_ state: PiSessionAttributes.ContentState) -> String {
    if state.primaryPhase == .working,
       let tool = state.primaryTool,
       !tool.isEmpty {
        return toolSymbol(tool)
    }
    return phaseIcon(state.primaryPhase)
}

private func toolSymbol(_ tool: String) -> String {
    switch tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "bash": return "terminal.fill"
    case "read": return "doc.text.fill"
    case "write": return "square.and.pencil"
    case "edit": return "pencil.and.scribble"
    default: return "hammer.fill"
    }
}

private func compactChangeBadge(_ state: PiSessionAttributes.ContentState) -> String? {
    let mutatingTools = max(state.primaryMutatingToolCalls ?? 0, 0)
    guard mutatingTools > 0 else { return nil }

    let added = max(state.primaryAddedLines ?? 0, 0)
    let removed = max(state.primaryRemovedLines ?? 0, 0)
    let changedLineTotal = added + removed
    if changedLineTotal > 0 {
        return "Δ\(compactCountLabel(changedLineTotal))"
    }

    let filesChanged = max(state.primaryFilesChanged ?? 0, 0)
    if filesChanged > 0 {
        return "F\(compactCountLabel(filesChanged))"
    }

    return "T\(compactCountLabel(mutatingTools))"
}

private struct ChangeStatsSnapshot {
    let mutatingToolCalls: Int
    let filesChanged: Int
    let addedLines: Int
    let removedLines: Int
}

private struct ChangeStatsSummaryView: View {
    let summary: ChangeStatsSnapshot

    var body: some View {
        HStack(spacing: 6) {
            if summary.filesChanged > 0 {
                Text(fileCountLabel(summary.filesChanged))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(toolCountLabel(summary.mutatingToolCalls))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if summary.addedLines > 0 {
                Text("+\(summary.addedLines)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.green)
            }

            if summary.removedLines > 0 {
                Text("-\(summary.removedLines)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.red)
            }

            if summary.addedLines == 0,
               summary.removedLines == 0,
               summary.filesChanged > 0 {
                Text(toolCountLabel(summary.mutatingToolCalls))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

private func changeStatsSummary(_ state: PiSessionAttributes.ContentState) -> ChangeStatsSnapshot? {
    let mutatingTools = max(state.primaryMutatingToolCalls ?? 0, 0)
    guard mutatingTools > 0 else { return nil }

    return ChangeStatsSnapshot(
        mutatingToolCalls: mutatingTools,
        filesChanged: max(state.primaryFilesChanged ?? 0, 0),
        addedLines: max(state.primaryAddedLines ?? 0, 0),
        removedLines: max(state.primaryRemovedLines ?? 0, 0)
    )
}

private func compactChangeAccessibilityLabel(_ state: PiSessionAttributes.ContentState) -> String {
    let mutatingTools = max(state.primaryMutatingToolCalls ?? 0, 0)
    let filesChanged = max(state.primaryFilesChanged ?? 0, 0)
    let added = max(state.primaryAddedLines ?? 0, 0)
    let removed = max(state.primaryRemovedLines ?? 0, 0)

    var parts = [
        mutatingTools == 1 ? "1 mutating tool call" : "\(mutatingTools) mutating tool calls"
    ]

    if filesChanged > 0 {
        parts.append(filesChanged == 1 ? "1 file changed" : "\(filesChanged) files changed")
    }

    if added > 0 || removed > 0 {
        if added > 0 {
            parts.append("\(added) lines added")
        }
        if removed > 0 {
            parts.append("\(removed) lines removed")
        }
    }

    return parts.joined(separator: ", ")
}

private func compactCountLabel(_ value: Int) -> String {
    let clamped = max(0, value)
    if clamped < 1_000 {
        return "\(clamped)"
    }
    if clamped < 1_000_000 {
        return "\(clamped / 1_000)k"
    }
    return "\(clamped / 1_000_000)m"
}

private func fileCountLabel(_ count: Int) -> String {
    count == 1 ? "1 file" : "\(count) files"
}

private func toolCountLabel(_ count: Int) -> String {
    count == 1 ? "1 tool" : "\(count) tools"
}

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
            return "Idle"
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

private func centerActivityText(_ state: PiSessionAttributes.ContentState) -> String? {
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

    let generic = Set([
        "working",
        "your turn",
        "approval required",
        "attention needed",
        "session ended",
        "idle"
    ])

    return generic.contains(normalized) ? nil : raw
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
