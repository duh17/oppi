import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity + Dynamic Island UI for an active pi session.
///
/// Shows supervision state only — no token-level streaming.
/// Keeps battery/update budget low by using coarse state.
struct PiSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiSessionAttributes.self) { context in
            // Lock Screen / StandBy / Always-On Display presentation
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded Dynamic Island
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.sessionName, systemImage: "terminal")
                        .font(.caption2.bold())
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    StatusBadge(status: context.state.status)
                }

                DynamicIslandExpandedRegion(.center) {
                    if context.state.pendingPermissions > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: permissionRiskIcon(context.state.pendingPermissionRisk))
                                    .foregroundStyle(permissionRiskColor(context.state.pendingPermissionRisk))
                                Text(permissionHeadline(context.state))
                                    .font(.caption.bold())
                                    .lineLimit(1)
                            }

                            if let summary = context.state.pendingPermissionSummary,
                               !summary.isEmpty {
                                Text(summary)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if let tool = context.state.activeTool {
                        HStack(spacing: 4) {
                            Image(systemName: iconForTool(tool))
                                .foregroundStyle(.secondary)
                            Text("Running \(tool)")
                                .font(.caption)
                                .lineLimit(1)
                        }
                    } else if let event = context.state.lastEvent {
                        Text(event)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.pendingPermissions > 0 {
                        if let reason = context.state.pendingPermissionReason,
                           !reason.isEmpty {
                            Text(reason)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(permissionRiskColor(context.state.pendingPermissionRisk))
                        } else {
                            Text("Tap to review approval")
                                .font(.caption2)
                                .foregroundStyle(permissionRiskColor(context.state.pendingPermissionRisk))
                        }
                    } else {
                        Text(elapsedString(context.state.elapsedSeconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // Compact leading — small icon with motion hint while working.
                Image(systemName: compactLeadingSymbol(context.state))
                    .font(.caption2)
                    .foregroundStyle(statusColor(context.state.status))
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking(context.state.status))
            } compactTrailing: {
                if context.state.pendingPermissions > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: permissionRiskIcon(context.state.pendingPermissionRisk))
                            .font(.caption2)
                        Text("\(context.state.pendingPermissions)")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(permissionRiskColor(context.state.pendingPermissionRisk))
                } else if context.state.status == "busy" || context.state.status == "stopping" {
                    Text(elapsedCompactString(context.state.elapsedSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    StatusDot(status: context.state.status)
                }
            } minimal: {
                if context.state.pendingPermissions > 0 {
                    Image(systemName: permissionRiskIcon(context.state.pendingPermissionRisk))
                        .font(.caption2)
                        .foregroundStyle(permissionRiskColor(context.state.pendingPermissionRisk))
                } else if context.state.status == "error" {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(statusColor(context.state.status))
                }
            }
        }
    }
}

// MARK: - Lock Screen View

private struct LockScreenView: View {
    let context: ActivityViewContext<PiSessionAttributes>

    var body: some View {
        HStack(spacing: 12) {
            // Left: session info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption)
                    Text(context.attributes.sessionName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }

                if context.state.pendingPermissions > 0 {
                    if let summary = context.state.pendingPermissionSummary,
                       !summary.isEmpty {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let reason = context.state.pendingPermissionReason,
                       !reason.isEmpty {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let tool = context.state.activeTool {
                    Text("Running \(tool)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let event = context.state.lastEvent {
                    Text(event)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Right: status + pending
            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(status: context.state.status)

                if context.state.pendingPermissions > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: permissionRiskIcon(context.state.pendingPermissionRisk))
                            .font(.caption2)
                        Text(permissionHeadline(context.state))
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(permissionRiskColor(context.state.pendingPermissionRisk))

                    if let session = context.state.pendingPermissionSession,
                       !session.isEmpty {
                        Text(session)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(elapsedString(context.state.elapsedSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .activityBackgroundTint(
            context.state.pendingPermissions > 0
                ? permissionRiskColor(context.state.pendingPermissionRisk).opacity(0.15)
                : .clear
        )
    }
}

// MARK: - Shared Components

private struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(statusLabel)
            .font(.caption2.bold())
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.15))
            .clipShape(Capsule())
    }

    private var statusLabel: String {
        switch status {
        case "busy": return "Working"
        case "stopping": return "Stopping"
        case "ready": return "Ready"
        case "stopped": return "Done"
        case "error": return "Error"
        default: return status
        }
    }
}

private struct StatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
            .symbolEffect(.pulse, options: .repeating, isActive: isWorking(status))
    }
}

// MARK: - Helpers

private func statusColor(_ status: String) -> Color {
    switch status {
    case "busy": return .yellow
    case "stopping": return .orange
    case "ready": return .green
    case "stopped": return .gray
    case "error": return .red
    default: return .secondary
    }
}

private func isWorking(_ status: String) -> Bool {
    status == "busy" || status == "stopping"
}

private func compactLeadingSymbol(_ state: PiSessionAttributes.ContentState) -> String {
    if state.pendingPermissions > 0 {
        return permissionRiskIcon(state.pendingPermissionRisk)
    }
    if state.status == "error" {
        return "exclamationmark.triangle.fill"
    }
    if isWorking(state.status) {
        return "waveform.path.ecg"
    }
    return "terminal"
}

private func permissionRiskColor(_ risk: String?) -> Color {
    switch risk {
    case "critical": return .red
    case "high": return .orange
    case "medium": return .yellow
    case "low": return .green
    default: return .orange
    }
}

private func permissionRiskIcon(_ risk: String?) -> String {
    switch risk {
    case "critical": return "xmark.octagon.fill"
    case "high": return "exclamationmark.triangle.fill"
    case "medium": return "exclamationmark.shield"
    case "low": return "checkmark.shield"
    default: return "exclamationmark.triangle.fill"
    }
}

private func permissionHeadline(_ state: PiSessionAttributes.ContentState) -> String {
    if state.pendingPermissions <= 1 {
        return "Approval needed"
    }
    return "\(state.pendingPermissions) approvals"
}

private func iconForTool(_ tool: String) -> String {
    switch tool {
    case "Bash", "bash": return "terminal"
    case "Read", "read": return "doc.text"
    case "Write", "write": return "doc.badge.plus"
    case "Edit", "edit": return "pencil"
    case "__compaction": return "arrow.triangle.2.circlepath"
    default: return "gearshape"
    }
}

private func elapsedString(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%d:%02d", m, s)
}

private func elapsedCompactString(_ seconds: Int) -> String {
    if seconds >= 3600 {
        return "\(seconds / 3600)h"
    }
    if seconds >= 60 {
        return "\(seconds / 60)m"
    }
    return "\(max(1, seconds))s"
}
