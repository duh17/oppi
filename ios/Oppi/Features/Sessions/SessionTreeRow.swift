import SwiftUI

/// A session row displayed within a parent-child tree in WorkspaceDetailView.
///
/// Handles indentation, tree line connectors, disclosure triangles for parent rows,
/// and child count badges. Standalone (depth-0, no children) rows show an empty
/// spacer where the disclosure triangle would be, keeping text alignment consistent.
struct SessionTreeRow: View {
    let row: SessionTreeHelper.FlatRow
    let pendingCount: Int
    let isExpanded: Bool
    let statusCounts: SessionTreeHelper.StatusCounts?
    let onToggleExpand: () -> Void

    // Tree geometry constants
    private static let indentPerLevel: CGFloat = 24
    private static let treeLineX: CGFloat = 12
    private static let treeBranchWidth: CGFloat = 10
    private static let disclosureWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            // Tree indentation + lines for child/grandchild rows
            if row.depth > 0 {
                treeIndentation
            }

            // Disclosure triangle or spacer for alignment
            if row.hasChildren {
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .frame(width: Self.disclosureWidth, height: Self.disclosureWidth)
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                    .frame(width: Self.disclosureWidth)
            }

            // Status dot
            Circle()
                .fill(row.session.status.color)
                .frame(width: 10, height: 10)
                .opacity(row.session.status == .busy || row.session.status == .stopping ? 0.8 : 1)
                .animation(
                    row.session.status == .busy || row.session.status == .stopping
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: row.session.status
                )
                .padding(.leading, 4)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(row.session.displayTitle)
                    .font(.body)
                    .fontWeight(pendingCount > 0 ? .semibold : .regular)
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)

                // Change stats (files touched, lines added/removed)
                if let stats = row.session.changeStats {
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

                HStack(spacing: 6) {
                    if let model = shortModelName(row.session.model) {
                        Text(model)
                    }
                    if row.session.messageCount > 0 {
                        Text("\(row.session.messageCount) msgs")
                    }
                    if row.session.cost > 0 {
                        Text(costString(row.session.cost))
                    }

                    // Child badge
                    if row.hasChildren {
                        childBadge
                    }
                }
                .font(.caption)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
            }
            .padding(.leading, 8)

            Spacer(minLength: 4)

            // Trailing
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.session.lastActivity.relativeString())
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
    private var treeIndentation: some View {
        ZStack(alignment: .leading) {
            // Parent-level tree lines that continue through this row
            ForEach(row.parentLinesContinue, id: \.self) { depth in
                let xOffset = CGFloat(depth) * Self.indentPerLevel + Self.treeLineX
                Rectangle()
                    .fill(Color.themeBgHighlight)
                    .frame(width: 2)
                    .offset(x: xOffset)
            }

            // Vertical line at current depth
            let myX = CGFloat(row.depth - 1) * Self.indentPerLevel + Self.treeLineX
            Rectangle()
                .fill(Color.themeBgHighlight)
                .frame(width: 2)
                .frame(maxHeight: .infinity, alignment: row.isLastChild ? .top : .center)
                .clipped()
                .offset(x: myX)

            // Horizontal branch connector
            Rectangle()
                .fill(Color.themeBgHighlight)
                .frame(width: Self.treeBranchWidth, height: 2)
                .offset(x: myX + 2, y: 0)
        }
        .frame(width: CGFloat(row.depth) * Self.indentPerLevel)
    }

    // MARK: - Child Badge

    @ViewBuilder
    private var childBadge: some View {
        if let counts = statusCounts, !isExpanded {
            // Collapsed: show condensed status counts
            HStack(spacing: 3) {
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
        } else {
            // Expanded or default: show child count
            Text("\(row.childCount) \(row.childCount == 1 ? "child" : "children")")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.themeCyan)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.themeCyan.opacity(0.1), in: Capsule())
        }
    }

    // MARK: - Helpers

    private func shortModelName(_ model: String?) -> String? {
        SessionFormatting.shortModelName(model)
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

    private func costString(_ cost: Double) -> String {
        SessionFormatting.costString(cost)
    }
}
