import Charts
import SwiftUI

/// Compact donut chart showing model share by cost.
///
/// Aggregates by display name so duplicate raw model names merge into
/// one sector per logical model.
struct ModelDonutChart: View {

    let modelBreakdown: [StatsModelBreakdown]

    // MARK: - Aggregation

    private struct DonutSlice: Identifiable {
        let displayName: String
        let representativeModel: String
        let cost: Double
        var id: String { displayName }
    }

    private var slices: [DonutSlice] {
        var byName: [String: DonutSlice] = [:]
        for item in modelBreakdown {
            let name = displayModelName(item.model)
            if let existing = byName[name] {
                byName[name] = DonutSlice(
                    displayName: name,
                    representativeModel: existing.representativeModel,
                    cost: existing.cost + item.cost
                )
            } else {
                byName[name] = DonutSlice(
                    displayName: name,
                    representativeModel: item.model,
                    cost: item.cost
                )
            }
        }
        return byName.values
            .filter { $0.cost > 0.005 }
            .sorted { $0.cost > $1.cost }
    }

    private var totalCost: Double {
        slices.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        if slices.isEmpty || totalCost == 0 {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
                .frame(width: 100, height: 100)
        } else {
            ZStack {
                Chart(slices) { item in
                    SectorMark(
                        angle: .value("Cost", item.cost),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(modelColor(item.representativeModel))
                }
                .chartLegend(.hidden)
                .frame(width: 100, height: 100)

                VStack(spacing: 1) {
                    Text(SessionFormatting.costString(totalCost))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("total")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 56)
            }
            .frame(width: 100, height: 100)
        }
    }
}
