import Charts
import SwiftUI

/// Number of models shown before "Show more" disclosure.
private let topModelCount = 5

struct ModelBreakdownSection: View {

    let breakdown: [StatsModelBreakdown]
    let metric: StatsMetric

    @State private var showAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Aggregation

    private var aggregated: [AggregatedStatsModel] {
        aggregateStatsModels(breakdown, sortedBy: metric)
    }

    /// Models with non-zero usage for the selected metric, sorted by that metric descending.
    private var nonZeroModels: [AggregatedStatsModel] {
        aggregated.nonZeroStatsModels(for: metric)
    }

    private var totalMetricValue: Double {
        aggregated.reduce(0) { $0 + $1.value(for: metric) }
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
        let models = nonZeroModels
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Models")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                donutChart(models)

                modelList
            }
        }
    }

    // MARK: - Donut chart

    @ViewBuilder
    private func donutChart(_ models: [AggregatedStatsModel]) -> some View {
        if totalMetricValue <= 0 {
            EmptyView()
        } else {
            ZStack {
                Chart(models) { item in
                    SectorMark(
                        angle: .value(metric.chartTitle, item.value(for: metric)),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(modelColor(item.representativeModel))
                }
                .chartLegend(.hidden)
                .frame(width: 140, height: 140)

                VStack(spacing: 2) {
                    Text(formatMetricValue(totalMetricValue))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.themeFg)
                    Text("total")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
                .frame(width: 80)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Model list

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleModels) { item in
                modelRow(item)
            }

            if !showAll, hiddenCount > 0 {
                Button {
                    withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
                        showAll = true
                    }
                } label: {
                    Text("Show \(hiddenCount) more")
                        .font(.caption)
                        .foregroundStyle(.themeBlue)
                }
                .padding(.top, 2)
            } else if showAll, hiddenCount > 0 {
                Button {
                    withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
                        showAll = false
                    }
                } label: {
                    Text("Show less")
                        .font(.caption)
                        .foregroundStyle(.themeBlue)
                }
                .padding(.top, 2)
            }
        }
    }

    private func modelRow(_ item: AggregatedStatsModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                leadingIdentity(item)
                    .frame(width: 126, alignment: .leading)

                GeometryReader { geo in
                    let share = metricShare(for: item)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.themeComment.opacity(0.12))
                            .frame(height: 5)
                        Capsule()
                            .fill(modelColor(item.representativeModel).opacity(0.55))
                            .frame(width: max(2, geo.size.width * share), height: 5)
                    }
                }
                .frame(height: 5)

                Text(formatMetricValue(item.value(for: metric)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.themeComment)
                    .frame(width: metricValueWidth, alignment: .trailing)

                Text("\(Int((metricShare(for: item) * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .frame(width: 30, alignment: .trailing)
            }

            if item.cacheRead > 0 || (item.cacheWrite ?? 0) > 0 {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 18)

                    if let cacheRate = item.cacheRate {
                        Text("cache \(Int((cacheRate * 100).rounded()))%")
                            .foregroundStyle(.themeGreen)
                    }

                    Text("R: \(item.cacheRead.formattedTokenCount())")
                        .foregroundStyle(.themeComment)

                    Text(formatModelCacheWriteLabel(item.cacheWrite))
                        .foregroundStyle(.themeComment)

                    Spacer()
                }
                .font(.caption2)
                .padding(.leading, 6)
            }
        }
    }

    private var metricValueWidth: CGFloat {
        switch metric {
        case .sessions: return 44
        case .cost: return 56
        case .tokens: return 58
        }
    }

    private func metricShare(for item: AggregatedStatsModel) -> Double {
        guard totalMetricValue > 0 else { return 0 }
        return max(0, item.value(for: metric) / totalMetricValue)
    }

    private func formatMetricValue(_ value: Double) -> String {
        switch metric {
        case .sessions:
            return String(format: "%.0f", value)
        case .cost:
            return SessionFormatting.costString(value)
        case .tokens:
            return Int(value.rounded()).formattedTokenCount()
        }
    }

    private func leadingIdentity(_ item: AggregatedStatsModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ProviderGlyph(provider: item.provider, size: 12, color: .themeComment)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.caption)
                    .foregroundStyle(modelColor(item.representativeModel))
                    .lineLimit(1)

                if let providerDisplayName = item.providerDisplayName {
                    Text(providerDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }
        }
    }
}
