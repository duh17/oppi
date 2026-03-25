import SwiftUI

// MARK: - Session Row

/// Unified session row used in both active and stopped sections.
///
/// Child session summary (agent count + status badge) is opt-in via the `children`
/// parameter. When nil, the row renders as a simple flat row.
struct SessionRow: View {
    let session: Session
    let pendingCount: Int
    let lineageHint: String?
    let children: ChildSummary?

    /// Summary of spawned child sessions, shown as a badge on parent rows.
    struct ChildSummary {
        let childCount: Int
        let statusCounts: SessionTreeHelper.StatusCounts
        let aggregateCost: Double
    }

    init(session: Session, pendingCount: Int, lineageHint: String? = nil, children: ChildSummary? = nil) {
        self.session = session
        self.pendingCount = pendingCount
        self.lineageHint = lineageHint
        self.children = children
    }

    private var title: String {
        session.displayTitle
    }

    private var modelShort: String? {
        SessionFormatting.shortModelName(session.model)
    }

    private var contextPercent: Double? {
        guard let used = session.contextTokens,
              let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }

    var body: some View {
        HStack(spacing: 0) {
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

                // Row 2: lineage hint (stopped sessions only)
                if let lineageHint, !lineageHint.isEmpty {
                    Text(lineageHint)
                        .font(.caption)
                        .foregroundStyle(.themeFgDim)
                        .lineLimit(1)
                }

                // Row 3: change stats + child badge
                if session.changeStats != nil || children != nil {
                    HStack(spacing: 8) {
                        if let stats = session.changeStats {
                            Text(filesTouchedSummary(stats.filesChanged))
                                .foregroundStyle(changeSummaryColor(stats))

                            Text("+\(stats.addedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffAdded)

                            Text("-\(stats.removedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffRemoved)
                        }

                        if let children {
                            childBadge(children: children)
                        }
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

                    let displayCost = children?.aggregateCost ?? session.cost
                    if displayCost > 0 {
                        Text(costString(displayCost))
                    }
                }
                .font(.caption)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
            }
            .padding(.leading, 8)

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

    // MARK: - Child Badge

    @ViewBuilder
    private func childBadge(children: ChildSummary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.appBadge)
                .foregroundStyle(.themeCyan)

            let counts = children.statusCounts
            if counts.working > 0 {
                Text("\u{23F3}\(counts.working)")
                    .foregroundStyle(.themeOrange)
            }
            if counts.done > 0 {
                Text("\u{2713}\(counts.done)")
                    .foregroundStyle(.themeGreen)
            }
            if counts.error > 0 {
                Text("\u{2717}\(counts.error)")
                    .foregroundStyle(.themeRed)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.themeCyan.opacity(0.1), in: Capsule())
    }

    // MARK: - Helpers

    private func costString(_ cost: Double) -> String {
        SessionFormatting.costString(cost)
    }

    private func filesTouchedSummary(_ filesChanged: Int) -> String {
        filesChanged == 1 ? String(localized: "1 file touched") : String(localized: "\(filesChanged) files touched")
    }

    private func changeSummaryColor(_ stats: SessionChangeStats) -> Color {
        if stats.filesChanged >= 25 {
            return .themeRed
        }
        if stats.filesChanged >= 10 {
            return .themeOrange
        }
        return .themeGreen
    }
}

// MARK: - Context Gauge

/// Compact context usage indicator using app theme colors.
struct NativeContextGauge: View {
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
