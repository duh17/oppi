import SwiftUI

/// Number of models shown before "Show more" toggle.
private let topModelCount = 5

// MARK: - ModelBreakdownView

/// Model list with share bars, cache stats, and show-more toggle.
struct ModelBreakdownView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let breakdown: [StatsModelBreakdown]

    @State private var showAll = false

    // MARK: - Aggregation

    private var aggregated: [AggregatedStatsModel] {
        aggregateStatsModels(breakdown, sortedBy: .cost)
    }

    private var nonZeroModels: [AggregatedStatsModel] {
        aggregated.nonZeroStatsModels(for: .cost)
    }

    private var visibleModels: [AggregatedStatsModel] {
        let models = nonZeroModels
        if showAll || models.count <= topModelCount {
            return models
        }
        return Array(models.prefix(topModelCount))
    }

    private var hiddenCount: Int {
        max(0, nonZeroModels.count - topModelCount)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(visibleModels) { item in
                modelRow(item)
            }

            if !showAll, hiddenCount > 0 {
                Button {
                    withAnimation(
                        ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)
                    ) { showAll = true }
                } label: {
                    Text("Show \(hiddenCount) more")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else if showAll, hiddenCount > 0 {
                Button {
                    withAnimation(
                        ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)
                    ) { showAll = false }
                } label: {
                    Text("Show less")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Row

    private func modelRow(_ item: AggregatedStatsModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                leadingIdentity(item)
                    .frame(width: 112, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 4)
                        Capsule()
                            .fill(modelColor(item.representativeModel).opacity(0.55))
                            .frame(width: max(2, geo.size.width * item.share), height: 4)
                    }
                }
                .frame(height: 4)

                Text(SessionFormatting.costString(item.cost))
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)

                Text("\(Int((item.share * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }

            if item.cacheRead > 0 || (item.cacheWrite ?? 0) > 0 {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 17)

                    if let cacheRate = item.cacheRate {
                        Text("cache \(Int((cacheRate * 100).rounded()))%")
                            .foregroundStyle(.green)
                    }

                    Text("R: \(formatTokens(item.cacheRead))")
                        .foregroundStyle(.secondary)

                    Text(formatModelCacheWriteLabel(item.cacheWrite))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .font(.system(size: 9))
                .padding(.leading, 5)
            }
        }
    }

    private func leadingIdentity(_ item: AggregatedStatsModel) -> some View {
        HStack(alignment: .center, spacing: 6) {
            ProviderGlyph(provider: item.provider, size: 11, color: .secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayName)
                    .font(.caption2)
                    .foregroundStyle(modelColor(item.representativeModel))
                    .lineLimit(1)

                if let providerDisplayName = item.providerDisplayName {
                    Text(providerDisplayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Formatting

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
