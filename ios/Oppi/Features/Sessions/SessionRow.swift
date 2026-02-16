import SwiftUI

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    let pendingCount: Int
    let lineageHint: String?

    init(session: Session, pendingCount: Int, lineageHint: String? = nil) {
        self.session = session
        self.pendingCount = pendingCount
        self.lineageHint = lineageHint
    }

    private var title: String {
        session.name ?? "Session \(String(session.id.prefix(8)))"
    }

    private var modelShort: String? {
        guard let model = session.model, !model.isEmpty else { return nil }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    private var contextPercent: Double? {
        guard let used = session.contextTokens,
              let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(session.status.nativeColor)
                .frame(width: 10, height: 10)
                .opacity(session.status == .busy || session.status == .stopping ? 0.8 : 1)
                .animation(
                    session.status == .busy || session.status == .stopping
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: session.status
                )

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: name
                Text(title)
                    .font(.body)
                    .fontWeight(pendingCount > 0 ? .semibold : .regular)
                    .lineLimit(1)

                // Row 2: lineage hint
                if let lineageHint, !lineageHint.isEmpty {
                    Text(lineageHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Row 3: change status
                if let stats = session.changeStats {
                    HStack(spacing: 8) {
                        Text(filesTouchedSummary(stats.filesChanged))
                            .foregroundStyle(changeSummaryColor(stats))

                        Text("+\(stats.addedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoGreen)

                        Text("-\(stats.removedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoRed)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }

                // Row 4: model + compact metrics
                HStack(spacing: 6) {
                    if let model = modelShort {
                        Text(model)
                    }

                    if session.messageCount > 0 {
                        Text("\(session.messageCount) msgs")
                    }

                    if let pct = contextPercent {
                        NativeContextGauge(percent: pct)
                    }

                    if session.cost > 0 {
                        Text(costString(session.cost))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Trailing: time + pending badge
            VStack(alignment: .trailing, spacing: 4) {
                Text(session.lastActivity.relativeString())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func costString(_ cost: Double) -> String {
        cost >= 0.01
            ? String(format: "$%.2f", cost)
            : String(format: "$%.3f", cost)
    }

    private func filesTouchedSummary(_ filesChanged: Int) -> String {
        filesChanged == 1 ? "1 file touched" : "\(filesChanged) files touched"
    }

    private func changeSummaryColor(_ stats: SessionChangeStats) -> Color {
        if stats.filesChanged >= 25 || stats.mutatingToolCalls >= 80 {
            return .tokyoRed
        }
        if stats.filesChanged >= 10 || stats.mutatingToolCalls >= 30 {
            return .tokyoOrange
        }
        return .tokyoGreen
    }
}

// MARK: - Context Gauge

/// Compact context usage indicator using system colors.
private struct NativeContextGauge: View {
    let percent: Double

    private var clamped: Double { min(max(percent, 0), 1) }

    private var tint: Color {
        if clamped > 0.9 { return .red }
        if clamped > 0.7 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: 24 * clamped)
            }
            .frame(width: 24, height: 4)

            Text("\(Int((clamped * 100).rounded()))%")
                .monospacedDigit()
        }
    }
}

// MARK: - Native Status Colors

extension SessionStatus {
    /// System-compatible status colors (not Tokyo Night).
    var nativeColor: Color {
        switch self {
        case .starting: return .blue
        case .ready: return .green
        case .busy: return .yellow
        case .stopping: return .orange
        case .stopped: return .secondary
        case .error: return .red
        }
    }
}
