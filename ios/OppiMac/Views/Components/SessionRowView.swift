import SwiftUI

/// A compact card showing one active session's status, model, cost,
/// context usage, and thinking level.
struct SessionRowView: View {

    let session: StatsActiveSession

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            // Child-agent indent marker
            if session.parentSessionId != nil {
                Text("↳")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .padding(.top, 2)
            }

            StatusIndicatorView(status: session.status)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                // Name + model/cost row
                HStack(alignment: .firstTextBaseline) {
                    Text(session.name ?? "Session")
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 1) {
                        if let model = session.model {
                            Text(shortModelName(model))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("$\(String(format: "%.4f", session.cost))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Status text
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                // Context usage bar
                if let tokens = session.contextTokens,
                   let window = session.contextWindow,
                   window > 0 {
                    contextBar(fraction: Double(tokens) / Double(window))
                }

                // Thinking level indicator
                if let level = session.thinkingLevel, level != "off" {
                    thinkingIndicator(level: level)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private var statusText: String {
        switch session.status {
        case "busy":     "Running"
        case "starting": "Starting"
        case "ready":    "Idle"
        case "stopped":  "Stopped"
        case "error":    "Error"
        default:         session.status
        }
    }

    /// Shorten "anthropic/claude-sonnet-4-5-20251022" → "sonnet-4-5".
    private func shortModelName(_ model: String) -> String {
        let last = String(model.split(separator: "/").last ?? Substring(model))
        var cleaned = last
            .replacingOccurrences(of: "claude-", with: "")
        // Drop trailing date segment (8+ digits).
        let parts = cleaned.split(separator: "-")
        if let tail = parts.last, tail.count >= 8, tail.allSatisfy(\.isNumber) {
            cleaned = parts.dropLast().joined(separator: "-")
        }
        return cleaned
    }

    @ViewBuilder
    private func contextBar(fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1.0)
        let color: Color = clamped > 0.85 ? .red : clamped > 0.6 ? .orange : .blue

        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.15))
                    .frame(height: 2)
                Capsule()
                    .fill(color.opacity(0.7))
                    .frame(width: geo.size.width * clamped, height: 2)
            }
        }
        .frame(height: 2)
    }

    @ViewBuilder
    private func thinkingIndicator(level: String) -> some View {
        let filled = thinkingLevelInt(level)
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? Color.purple.opacity(0.75) : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: 7)
            }
        }
    }

    private func thinkingLevelInt(_ level: String) -> Int {
        switch level {
        case "minimal": return 1
        case "low":     return 2
        case "medium":  return 3
        case "high":    return 4
        case "xhigh":   return 5
        default:        return 0
        }
    }
}
