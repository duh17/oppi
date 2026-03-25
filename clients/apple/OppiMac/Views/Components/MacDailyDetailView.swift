import Charts
import SwiftUI

// MARK: - Chart data

private struct HourlyCost: Identifiable {
    let hour: Int
    let model: String
    let cost: Double

    var id: String { "\(hour)-\(model)" }
}

// MARK: - MacDailyDetailView

/// Hourly drill-down for a single day. Shows an hourly stacked bar chart
/// and a session list. Presented inline when the user taps a bar in the
/// daily chart.
struct MacDailyDetailView: View {

    let detail: DailyDetail
    let onDismiss: () -> Void

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    // MARK: - Derived data

    private var chartData: [HourlyCost] {
        var result: [HourlyCost] = []
        for entry in detail.hourly {
            if let byModel = entry.byModel, !byModel.isEmpty {
                var byDisplay: [String: (raw: String, cost: Double)] = [:]
                for (model, data) in byModel where data.cost > 0 {
                    let name = displayModelName(model)
                    if let existing = byDisplay[name] {
                        byDisplay[name] = (existing.raw, existing.cost + data.cost)
                    } else {
                        byDisplay[name] = (model, data.cost)
                    }
                }
                for (_, value) in byDisplay.sorted(by: { $0.key < $1.key }) {
                    result.append(HourlyCost(hour: entry.hour, model: value.raw, cost: value.cost))
                }
            } else if entry.cost > 0 {
                result.append(HourlyCost(hour: entry.hour, model: "other", cost: entry.cost))
            }
        }
        return result.sorted { $0.hour < $1.hour }
    }

    private var dayTitle: String {
        guard let date = Self.dateParser.date(from: detail.date) else { return detail.date }
        return Self.dayFormatter.string(from: date)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("\(detail.totals.sessions) sessions — \(formatCost(detail.totals.cost))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Hourly chart
            if !chartData.isEmpty {
                hourlyChart
            }

            // Session list
            if !detail.sessions.isEmpty {
                sessionList
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Hourly chart

    private var hourlyChart: some View {
        Chart(chartData) { entry in
            BarMark(
                x: .value("Hour", entry.hour),
                y: .value("Cost", entry.cost)
            )
            .foregroundStyle(modelColor(entry.model))
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text(hourLabel(h))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v < 1 ? String(format: "$%.2f", v) : String(format: "$%.0f", v))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXScale(domain: 0...23)
        .frame(height: 120)
    }

    // MARK: - Session list

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sessions")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(detail.sessions.prefix(8), id: \.id) { session in
                sessionRow(session)
                if session.id != detail.sessions.prefix(8).last?.id {
                    Divider().padding(.leading, 16)
                }
            }

            if detail.sessions.count > 8 {
                Text("+\(detail.sessions.count - 8) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func sessionRow(_ session: StatsDailySession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(modelColor(session.model ?? ""))
                .frame(width: 5, height: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.name ?? "Session \(String(session.id.prefix(8)))")
                    .font(.caption2)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(displayModelName(session.model ?? "unknown"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    if let ws = session.workspaceName {
                        Text(ws)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(formatCost(session.cost))
                    .font(.caption2.monospacedDigit())

                Text(formatTime(session.createdAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Formatting

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }

    private func formatCost(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }

    private func formatTime(_ epochMs: Double) -> String {
        let date = Date(timeIntervalSince1970: epochMs / 1000)
        return Self.timeFormatter.string(from: date)
    }
}
