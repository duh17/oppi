import Charts
import SwiftUI

struct ModelBreakdownSection: View {

    let breakdown: [StatsModelBreakdown]

    private var totalCost: Double {
        breakdown.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        if !breakdown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Models")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                donutChart

                modelList
            }
        }
    }

    // MARK: - Donut chart

    @ViewBuilder
    private var donutChart: some View {
        if totalCost == 0 {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.themeComment.opacity(0.06))
                .frame(width: 140, height: 140)
        } else {
            ZStack {
                Chart(breakdown, id: \.model) { item in
                    SectorMark(
                        angle: .value("Cost", item.cost),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(modelColor(item.model))
                }
                .chartLegend(.hidden)
                .frame(width: 140, height: 140)

                VStack(spacing: 2) {
                    Text(String(format: "$%.2f", totalCost))
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
            ForEach(breakdown, id: \.model) { item in
                modelRow(item)
            }
        }
    }

    private func modelRow(_ item: StatsModelBreakdown) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(modelColor(item.model))
                .frame(width: 8, height: 8)

            Text(displayModelName(item.model))
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
                        .fill(modelColor(item.model).opacity(0.55))
                        .frame(width: max(2, geo.size.width * item.share), height: 5)
                }
            }
            .frame(height: 5)

            Text(String(format: "$%.2f", item.cost))
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
}
