import Charts
import SwiftUI

/// Compact donut chart showing model share by cost.
///
/// Uses `SectorMark` with a 60% inner radius for the donut hole.
/// Overlays total cost in the center.
struct ModelDonutChart: View {

    let modelBreakdown: [StatsModelBreakdown]

    private var totalCost: Double {
        modelBreakdown.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        if modelBreakdown.isEmpty || totalCost == 0 {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
                .frame(width: 80, height: 80)
        } else {
            ZStack {
                Chart(modelBreakdown, id: \.model) { item in
                    SectorMark(
                        angle: .value("Cost", item.cost),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(modelColor(item.model))
                }
                .chartLegend(.hidden)
                .frame(width: 80, height: 80)

                // Center overlay
                VStack(spacing: 1) {
                    Text(String(format: "$%.2f", totalCost))
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("total")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 44)
            }
            .frame(width: 80, height: 80)
        }
    }
}
