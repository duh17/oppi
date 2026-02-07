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
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("\(context.state.pendingPermissions) pending")
                                .font(.caption.bold())
                        }
                    } else if let tool = context.state.activeTool {
                        HStack(spacing: 4) {
                            Image(systemName: iconForTool(tool))
                                .foregroundStyle(.secondary)
                            Text(tool)
                                .font(.caption.monospaced())
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
                        Text("Tap to approve")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text(elapsedString(context.state.elapsedSeconds))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // Compact leading — small icon
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(statusColor(context.state.status))
            } compactTrailing: {
                // Compact trailing — pending count or status
                if context.state.pendingPermissions > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("\(context.state.pendingPermissions)")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.orange)
                } else {
                    StatusDot(status: context.state.status)
                }
            } minimal: {
                // Minimal (when sharing with another Live Activity)
                ZStack {
                    Image(systemName: "terminal")
                        .font(.caption2)
                    if context.state.pendingPermissions > 0 {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: 6, y: -6)
                    }
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

                if let tool = context.state.activeTool {
                    Text(tool)
                        .font(.caption.monospaced())
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
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("\(context.state.pendingPermissions) pending")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.orange)
                } else {
                    Text(elapsedString(context.state.elapsedSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .activityBackgroundTint(
            context.state.pendingPermissions > 0 ? .orange.opacity(0.15) : .clear
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
    }
}

// MARK: - Helpers

private func statusColor(_ status: String) -> Color {
    switch status {
    case "busy": return .yellow
    case "ready": return .green
    case "stopped": return .gray
    case "error": return .red
    default: return .secondary
    }
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
