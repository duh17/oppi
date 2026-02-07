import SwiftUI

/// Ephemeral cross-session live event feed (v1: placeholder).
///
/// Shows connected-session events only. No persistence.
/// v2: durable audit history via `GET /activity?since=<ts>`.
struct LiveFeedView: View {
    @Environment(TimelineReducer.self) private var reducer

    var body: some View {
        Group {
            if reducer.items.isEmpty {
                ContentUnavailableView(
                    "No Live Events",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Events will appear here when a session is active.")
                )
            } else {
                List(reducer.items) { item in
                    LiveEventRow(item: item)
                }
            }
        }
        .navigationTitle("Live")
    }
}

private struct LiveEventRow: View {
    let item: ChatItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.caption)
                .frame(width: 20)

            Text(summary)
                .font(.subheadline)
                .lineLimit(2)
        }
    }

    private var iconName: String {
        switch item {
        case .userMessage: return "person.fill"
        case .assistantMessage: return "cpu"
        case .thinking: return "brain"
        case .toolCall: return "terminal"
        case .permission: return "exclamationmark.shield"
        case .permissionResolved: return "checkmark.shield"
        case .systemEvent: return "info.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch item {
        case .error: return .red
        case .permission: return .orange
        case .permissionResolved: return .green
        case .toolCall(_, _, _, _, _, let isError, _): return isError ? .red : .blue
        default: return .secondary
        }
    }

    private var summary: String {
        switch item {
        case .userMessage(_, let text, _): return "You: \(text)"
        case .assistantMessage(_, let text, _): return String(text.prefix(100))
        case .thinking: return "Thinking…"
        case .toolCall(_, let tool, let args, _, _, _, _): return "\(tool): \(args)"
        case .permission(let req): return "⚠️ \(req.displaySummary)"
        case .permissionResolved(_, let action): return action == .allow ? "✓ Allowed" : "✗ Denied"
        case .systemEvent(_, let msg): return msg
        case .error(_, let msg): return "Error: \(msg)"
        }
    }
}
