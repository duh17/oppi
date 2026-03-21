import SwiftUI

// MARK: - Session Row

/// Unified session row used in both active (tree) and stopped (flat) sections.
///
/// Tree features (indentation, disclosure, child badge) are opt-in via the `tree`
/// parameter. When nil, the row renders as a simple flat row.
struct SessionRow: View {
    let session: Session
    let pendingCount: Int
    let lineageHint: String?
    let tree: TreeConfig?

    struct TreeConfig {
        let row: SessionTreeHelper.FlatRow
        let isExpanded: Bool
        let statusCounts: SessionTreeHelper.StatusCounts?
        let onToggleExpand: () -> Void
    }

    init(session: Session, pendingCount: Int, lineageHint: String? = nil, tree: TreeConfig? = nil) {
        self.session = session
        self.pendingCount = pendingCount
        self.lineageHint = lineageHint
        self.tree = tree
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

    // Tree geometry constants
    private static let indentPerLevel: CGFloat = 24
    private static let treeLineX: CGFloat = 12
    private static let treeBranchWidth: CGFloat = 10

    var body: some View {
        HStack(spacing: 0) {
            // Tree indentation + lines (only for child/grandchild rows)
            if let tree, tree.row.depth > 0 {
                treeIndentation(row: tree.row)
            }

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
                if session.changeStats != nil || (tree?.row.hasChildren == true) {
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

                        // Child badge (tree mode only)
                        if let tree, tree.row.hasChildren {
                            childBadge(tree: tree)
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

                    if session.cost > 0 {
                        Text(costString(session.cost))
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

    // MARK: - Tree Lines

    @ViewBuilder
    private func treeIndentation(row: SessionTreeHelper.FlatRow) -> some View {
        ZStack(alignment: .leading) {
            ForEach(row.parentLinesContinue, id: \.self) { depth in
                let xOffset = CGFloat(depth) * Self.indentPerLevel + Self.treeLineX
                Rectangle()
                    .fill(Color.themeBgHighlight)
                    .frame(width: 2)
                    .offset(x: xOffset)
            }

            let myX = CGFloat(row.depth - 1) * Self.indentPerLevel + Self.treeLineX
            Rectangle()
                .fill(Color.themeBgHighlight)
                .frame(width: 2)
                .frame(maxHeight: .infinity, alignment: row.isLastChild ? .top : .center)
                .clipped()
                .offset(x: myX)

            Rectangle()
                .fill(Color.themeBgHighlight)
                .frame(width: Self.treeBranchWidth, height: 2)
                .offset(x: myX + 2, y: 0)
        }
        .frame(width: CGFloat(row.depth) * Self.indentPerLevel)
    }

    // MARK: - Child Badge

    @ViewBuilder
    private func childBadge(tree: TreeConfig) -> some View {
        Button {
            tree.onToggleExpand()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: tree.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.appBadge)
                    .foregroundStyle(.themeCyan)

                if let counts = tree.statusCounts, !tree.isExpanded {
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
                } else {
                    Text("\(tree.row.childCount)")
                        .foregroundStyle(.themeCyan)
                }
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.themeCyan.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func costString(_ cost: Double) -> String {
        SessionFormatting.costString(cost)
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
