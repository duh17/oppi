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
        session.displayTitle
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
                .fill(session.status.color)
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
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)

                // Row 2: lineage hint
                if let lineageHint, !lineageHint.isEmpty {
                    Text(lineageHint)
                        .font(.caption)
                        .foregroundStyle(.themeFgDim)
                        .lineLimit(1)
                }

                // Row 3: change status
                if let stats = session.changeStats {
                    HStack(spacing: 8) {
                        Text(filesTouchedSummary(stats.filesChanged))
                            .foregroundStyle(changeSummaryColor(stats))

                        Text("+\(stats.addedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.themeDiffAdded)

                        Text("-\(stats.removedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.themeDiffRemoved)
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
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Trailing: time + pending badge
            VStack(alignment: .trailing, spacing: 4) {
                Text(session.lastActivity.relativeString())
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.themeBg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.themeOrange, in: Capsule())
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
        filesChanged == 1 ? String(localized: "1 file touched") : String(localized: "\(filesChanged) files touched")
    }

    private func changeSummaryColor(_ stats: SessionChangeStats) -> Color {
        if stats.filesChanged >= 25 || stats.mutatingToolCalls >= 80 {
            return .themeRed
        }
        if stats.filesChanged >= 10 || stats.mutatingToolCalls >= 30 {
            return .themeOrange
        }
        return .themeGreen
    }
}

// MARK: - Context Gauge

/// Compact context usage indicator using app theme colors.
private struct NativeContextGauge: View {
    let percent: Double

    private var clamped: Double { min(max(percent, 0), 1) }

    private var tint: Color {
        if clamped > 0.9 { return .themeRed }
        if clamped > 0.7 { return .themeOrange }
        return .themeGreen
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.themeBgHighlight)
                Capsule()
                    .fill(tint)
                    .frame(width: 24 * clamped)
            }
            .frame(width: 24, height: 4)

            Text("\(Int((clamped * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.themeComment)
        }
    }
}
