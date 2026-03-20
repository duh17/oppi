import SwiftUI

struct StatsTabView: View {

    @Bindable var monitor: MacSessionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Range picker
            Picker("Range", selection: $monitor.selectedRange) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let stats = monitor.stats {
                heroStats(stats)
                DailyCostChart(daily: stats.daily)
                if !stats.modelBreakdown.isEmpty {
                    ModelBreakdownView(breakdown: stats.modelBreakdown)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Hero stats

    @ViewBuilder
    private func heroStats(_ stats: ServerStats) -> some View {
        HStack(spacing: 0) {
            heroBox(
                title: "Sessions",
                value: "\(stats.totals.sessions)",
                trend: trendInfo(values: stats.daily.map { Double($0.sessions) }, costMetric: false)
            )
            Divider().frame(height: 40)
            heroBox(
                title: "Cost",
                value: formatCost(stats.totals.cost),
                trend: trendInfo(values: stats.daily.map { $0.cost }, costMetric: true)
            )
            Divider().frame(height: 40)
            heroBox(
                title: "Tokens",
                value: formatTokens(stats.totals.tokens),
                trend: trendInfo(values: stats.daily.map { Double($0.tokens) }, costMetric: false)
            )
        }
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func heroBox(title: String, value: String, trend: TrendInfo?) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.8)
                .lineLimit(1)
            if let trend {
                HStack(spacing: 2) {
                    Text(trend.arrow)
                    Text(trend.label)
                }
                .font(.system(size: 9))
                .foregroundStyle(trend.color)
            } else {
                // Reserve height so boxes stay the same size
                Text(" ")
                    .font(.system(size: 9))
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

    /// Compare first half vs second half of the range.
    /// `costMetric`: rising cost = orange, falling = green.
    /// Other metrics: change shown in secondary color.
    private func trendInfo(values: [Double], costMetric: Bool) -> TrendInfo? {
        guard values.count >= 4 else { return nil }
        let mid = values.count / 2
        let first = values[0..<mid].reduce(0, +)
        let second = values[mid...].reduce(0, +)
        guard first > 0 else { return nil }
        let delta = (second - first) / first
        guard abs(delta) >= 0.05 else { return nil }

        let pct = "\(Int((abs(delta) * 100).rounded()))%"
        if delta > 0 {
            let color: Color = costMetric ? .orange : .secondary
            return TrendInfo(arrow: "↑", label: pct, color: color)
        } else {
            let color: Color = costMetric ? .green : .secondary
            return TrendInfo(arrow: "↓", label: pct, color: color)
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
