import SwiftUI

/// A compact list of models sorted by cost, each with a color dot,
/// proportional share bar, cost, and share percentage.
struct ModelBreakdownView: View {

    let breakdown: [StatsModelBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(breakdown, id: \.model) { item in
                modelRow(item)
            }
        }
    }

    // MARK: - Row

    private func modelRow(_ item: StatsModelBreakdown) -> some View {
        HStack(spacing: 5) {
            // Color dot
            Circle()
                .fill(modelColor(item.model))
                .frame(width: 7, height: 7)

            // Short name
            Text(displayModelName(item.model))
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)

            // Proportional bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 4)
                    Capsule()
                        .fill(modelColor(item.model).opacity(0.55))
                        .frame(width: max(2, geo.size.width * item.share), height: 4)
                }
            }
            .frame(height: 4)

            // Cost
            Text(String(format: "$%.2f", item.cost))
                .font(.caption2)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)

            // Share %
            Text("\(Int((item.share * 100).rounded()))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}
