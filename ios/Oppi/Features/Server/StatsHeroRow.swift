import SwiftUI

struct StatsHeroRow: View {
    let totals: StatsTotals
    let daily: [StatsDailyEntry]

    var body: some View {
        HStack(spacing: 0) {
            heroBox(title: "Sessions", value: "\(totals.sessions)",
                    trend: trendInfo(values: daily.map { Double($0.sessions) }, costMetric: false))
            Divider().frame(height: 44)
            heroBox(title: "Cost", value: formatCost(totals.cost),
                    trend: trendInfo(values: daily.map { $0.cost }, costMetric: true))
            Divider().frame(height: 44)
            heroBox(title: "Tokens", value: formatTokens(totals.tokens),
                    trend: trendInfo(values: daily.map { Double($0.tokens) }, costMetric: false))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Hero box

    private func heroBox(title: String, value: String, trend: TrendInfo?) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.themeComment)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.themeFg)
            if let trend {
                Label(trend.label, systemImage: trend.arrow)
                    .font(.caption2)
                    .foregroundStyle(trend.color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Trend

    private struct TrendInfo {
        let arrow: String
        let label: String
        let color: Color
    }

    private func trendInfo(values: [Double], costMetric: Bool) -> TrendInfo? {
        guard values.count >= 2 else { return nil }

        let mid = values.count / 2
        let firstHalf = values.prefix(mid).reduce(0, +)
        let secondHalf = values.suffix(from: mid).reduce(0, +)

        guard firstHalf > 0 else { return nil }

        let delta = (secondHalf - firstHalf) / firstHalf
        guard abs(delta) >= 0.05 else { return nil }

        let rising = delta > 0
        let pct = String(format: "%.0f%%", abs(delta) * 100)

        if costMetric {
            return TrendInfo(
                arrow: rising ? "arrow.up.right" : "arrow.down.right",
                label: pct,
                color: rising ? .themeOrange : .themeGreen
            )
        } else {
            return TrendInfo(
                arrow: rising ? "arrow.up.right" : "arrow.down.right",
                label: pct,
                color: .themeComment
            )
        }
    }

    // MARK: - Formatting

    private func formatCost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
