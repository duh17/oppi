import SwiftUI

struct StatsTabView: View {

    @Bindable var monitor: MacSessionMonitor
    let healthMonitor: ServerHealthMonitor

    @State private var selectedMetric: StatsMetric = .cost
    @State private var dailyDetail: DailyDetail?
    @State private var dailyDetailCache: [String: DailyDetail] = [:]
    @State private var isLoadingDetail = false

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
            .onChange(of: monitor.selectedRange) {
                dailyDetail = nil
                dailyDetailCache = [:]
            }

            if let stats = monitor.stats {
                VStack(alignment: .leading, spacing: 8) {
                    heroStats(stats)

                    DailyCostChart(
                        daily: stats.daily,
                        metric: selectedMetric,
                        onDaySelected: { dateString in
                            Task { await loadDailyDetail(date: dateString) }
                        }
                    )

                    if isLoadingDetail {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }

                    if let dailyDetail {
                        MacDailyDetailView(detail: dailyDetail) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.dailyDetail = nil
                            }
                        }
                    }

                    modelSection(stats)
                    workspaceSection(stats)
                    serverHealthSection(stats)
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

    // MARK: - Model section

    @ViewBuilder
    private func modelSection(_ stats: ServerStats) -> some View {
        if !stats.modelBreakdown.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ModelBreakdownView(breakdown: stats.modelBreakdown)
                ModelDonutChart(modelBreakdown: stats.modelBreakdown)
            }
        }
    }

    // MARK: - Workspace breakdown

    @ViewBuilder
    private func workspaceSection(_ stats: ServerStats) -> some View {
        if !stats.workspaceBreakdown.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text("Workspaces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                WorkspaceBreakdownView(workspaces: stats.workspaceBreakdown)
            }
        }
    }

    // MARK: - Server health

    @ViewBuilder
    private func serverHealthSection(_ stats: ServerStats) -> some View {
        Divider()
        MacServerHealthView(
            memory: stats.memory,
            serverInfo: healthMonitor.serverInfo,
            activeSessionCount: stats.activeSessions.count
        )
    }

    // MARK: - Hero stats

    @ViewBuilder
    private func heroStats(_ stats: ServerStats) -> some View {
        HStack(spacing: 0) {
            heroBox(
                title: "Sessions",
                value: "\(stats.totals.sessions)",
                trend: trendInfo(values: stats.daily.map { Double($0.sessions) }, costMetric: false),
                metric: .sessions
            )
            Divider().frame(height: 40)
            heroBox(
                title: "Cost",
                value: formatCost(stats.totals.cost),
                trend: trendInfo(values: stats.daily.map { $0.cost }, costMetric: true),
                metric: .cost
            )
            Divider().frame(height: 40)
            heroBox(
                title: "Tokens",
                value: formatTokens(stats.totals.tokens),
                trend: trendInfo(values: stats.daily.map { Double($0.tokens) }, costMetric: false),
                metric: .tokens
            )
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func heroBox(title: String, value: String, trend: TrendInfo?, metric: StatsMetric) -> some View {
        Button {
            selectedMetric = metric
        } label: {
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
                    Text(" ")
                        .font(.system(size: 9))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                if selectedMetric == metric {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.blue)
                        .frame(width: 28, height: 2)
                        .padding(.bottom, 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Trend

    private struct TrendInfo {
        let arrow: String
        let label: String
        let color: Color
    }

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

    // MARK: - Daily detail loading

    private func loadDailyDetail(date: String) async {
        if let cached = dailyDetailCache[date] {
            withAnimation(.easeInOut(duration: 0.2)) {
                dailyDetail = cached
            }
            return
        }

        // Need the MacAPIClient — reconstruct from monitor's context
        let dataDir = NSString("~/.config/oppi").expandingTildeInPath
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else { return }
        let client = MacAPIClient(baseURL: URL(string: "https://localhost:7749")!, token: token)

        isLoadingDetail = true
        if let result = await client.fetchDailyDetail(date: date) {
            dailyDetailCache[date] = result
            withAnimation(.easeInOut(duration: 0.2)) {
                dailyDetail = result
            }
        }
        isLoadingDetail = false
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
