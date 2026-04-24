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
                var byIdentity: [String: (raw: String, sortKey: String, cost: Double)] = [:]
                for (model, data) in byModel where data.cost > 0 {
                    let identity = modelDisplayIdentity(model)
                    let key = identity.aggregationKey
                    let sortKey = "\(identity.displayName)|\(identity.providerDisplayName ?? "")"
                    if let existing = byIdentity[key] {
                        byIdentity[key] = (existing.raw, existing.sortKey, existing.cost + data.cost)
                    } else {
                        byIdentity[key] = (model, sortKey, data.cost)
                    }
                }
                for (_, value) in byIdentity.sorted(by: { $0.value.sortKey < $1.value.sortKey }) {
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("\(detail.totals.sessions) sessions — \(SessionFormatting.costString(detail.totals.cost))")
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

            if !chartData.isEmpty {
                hourlyChart
            }

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
                        Text(SessionFormatting.costString(v))
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
        let model = session.model ?? "unknown"

        return HStack(spacing: 6) {
            ProviderGlyph(provider: modelProviderKey(model), size: 10, color: .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.name ?? "Session \(String(session.id.prefix(8)))")
                    .font(.caption2)
                    .lineLimit(1)

                Text(displayModelName(model))
                    .font(.system(size: 9))
                    .foregroundStyle(modelColor(model))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let provider = modelProviderLabel(model) {
                        Text(provider)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if let ws = session.workspaceName {
                        Text(ws)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(SessionFormatting.costString(session.cost))
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

    private func formatTime(_ epochMs: Double) -> String {
        let date = Date(timeIntervalSince1970: epochMs / 1000)
        return Self.timeFormatter.string(from: date)
    }
}
