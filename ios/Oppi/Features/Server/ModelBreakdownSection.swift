import Charts
import SwiftUI

// MARK: - Aggregated model (deduped by display name)

/// Multiple raw model names (e.g. "anthropic/claude-opus-4-6-20250514",
/// "anthropic/claude-opus-4-6") map to the same display name ("opus-4-6").
/// This struct merges them so the UI shows one row per logical model.
private struct AggregatedModel: Identifiable {
    let displayName: String
    /// Any raw model name from this group (for color lookup).
    let representativeModel: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    var share: Double

    var id: String { displayName }
}

/// Number of models shown before "Show more" disclosure.
private let topModelCount = 5

struct ModelBreakdownSection: View {

    let breakdown: [StatsModelBreakdown]

    @State private var showAll = false

    // MARK: - Aggregation

    private var aggregated: [AggregatedModel] {
        var byName: [String: AggregatedModel] = [:]

        for item in breakdown {
            let name = displayModelName(item.model)
            if var existing = byName[name] {
                existing = AggregatedModel(
                    displayName: name,
                    representativeModel: existing.representativeModel,
                    sessions: existing.sessions + item.sessions,
                    cost: existing.cost + item.cost,
                    tokens: existing.tokens + item.tokens,
                    share: existing.share + item.share
                )
                byName[name] = existing
            } else {
                byName[name] = AggregatedModel(
                    displayName: name,
                    representativeModel: item.model,
                    sessions: item.sessions,
                    cost: item.cost,
                    tokens: item.tokens,
                    share: item.share
                )
            }
        }

        return byName.values.sorted { $0.cost > $1.cost }
    }

    /// Models with non-zero cost, sorted by cost descending.
    private var nonZeroModels: [AggregatedModel] {
        aggregated.filter { $0.cost > 0.005 }
    }

    private var totalCost: Double {
        aggregated.reduce(0) { $0 + $1.cost }
    }

    private var visibleModels: [AggregatedModel] {
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
    private func donutChart(_ models: [AggregatedModel]) -> some View {
        if totalCost <= 0 {
            EmptyView()
        } else {
            ZStack {
                Chart(models) { item in
                    SectorMark(
                        angle: .value("Cost", item.cost),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(modelColor(item.representativeModel))
                }
                .chartLegend(.hidden)
                .frame(width: 140, height: 140)

                VStack(spacing: 2) {
                    Text(formatCost(totalCost))
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
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                    withAnimation(.easeInOut(duration: 0.2)) {
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

    private func modelRow(_ item: AggregatedModel) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(modelColor(item.representativeModel))
                .frame(width: 8, height: 8)

            Text(item.displayName)
                .font(.caption)
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.themeComment.opacity(0.12))
                        .frame(height: 5)
                    Capsule()
                        .fill(modelColor(item.representativeModel).opacity(0.55))
                        .frame(width: max(2, geo.size.width * item.share), height: 5)
                }
            }
            .frame(height: 5)

            Text(formatCost(item.cost))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.themeComment)
                .frame(width: 56, alignment: .trailing)

            Text("\(Int((item.share * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.themeComment)
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: - Formatting

    private func formatCost(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }
}
