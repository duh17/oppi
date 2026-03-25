import Charts
import SwiftUI

// MARK: - Metric enum

/// Which metric the bar chart displays.
enum StatsMetric: String, CaseIterable {
    case sessions
    case cost
    case tokens

    var chartTitle: String {
        switch self {
        case .sessions: "Daily Sessions"
        case .cost: "Daily Cost"
        case .tokens: "Daily Tokens"
        }
    }
}

// MARK: - Chart data model

private struct ModelDayValue: Identifiable {
    let date: Date
    let model: String
    let value: Double

    var id: String { "\(Int(date.timeIntervalSince1970))-\(model)" }
}

// MARK: - DailyCostChart

struct DailyCostChart: View {

    let daily: [StatsDailyEntry]
    var metric: StatsMetric = .cost
    var onDaySelected: ((String) -> Void)?

    @State private var selectedDate: Date?

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let dateStringFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Derived data

    private var chartData: [ModelDayValue] {
        var result: [ModelDayValue] = []
        for entry in daily {
            guard let date = Self.dateParser.date(from: entry.date) else { continue }
            if let byModel = entry.byModel, !byModel.isEmpty {
                // Aggregate by display name so duplicates merge
                var byDisplay: [String: (raw: String, value: Double)] = [:]
                for (model, data) in byModel {
                    let v = metricValue(from: data)
                    guard v > 0 else { continue }
                    let name = displayModelName(model)
                    if let existing = byDisplay[name] {
                        byDisplay[name] = (existing.raw, existing.value + v)
                    } else {
                        byDisplay[name] = (model, v)
                    }
                }
                for (_, item) in byDisplay.sorted(by: { $0.key < $1.key }) {
                    result.append(ModelDayValue(date: date, model: item.raw, value: item.value))
                }
            } else {
                let v = metricValue(from: entry)
                if v > 0 {
                    result.append(ModelDayValue(date: date, model: "other", value: v))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private var selectedDayData: [ModelDayValue] {
        guard let sel = selectedDate else { return [] }
        let cal = Calendar.current
        return chartData
            .filter { cal.isDate($0.date, inSameDayAs: sel) }
            .sorted { $0.value > $1.value }
    }

    private var axisStride: Int {
        let count = daily.count
        if count <= 7 { return 1 }
        if count <= 14 { return 2 }
        if count <= 30 { return 7 }
        return 14
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.chartTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if chartData.isEmpty {
                emptyPlaceholder
            } else {
                chartView
                if !selectedDayData.isEmpty {
                    tooltipView
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Subviews

    private var emptyPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.08))
            .frame(height: 180)
            .overlay {
                Text("No data for this range")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
    }

    private func isSelected(_ entry: ModelDayValue) -> Bool {
        guard let sel = selectedDate else { return false }
        return Calendar.current.isDate(entry.date, inSameDayAs: sel)
    }

    @ViewBuilder
    private var chartView: some View {
        Chart(chartData) { entry in
            BarMark(
                x: .value("Date", entry.date, unit: .day),
                y: .value(metric.chartTitle, entry.value)
            )
            .foregroundStyle(modelColor(entry.model))
            .opacity(selectedDate == nil || isSelected(entry) ? 1.0 : 0.3)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let plotOrigin = geo[plotFrame].origin
                        let x = location.x - plotOrigin.x
                        guard let tappedDate: Date = proxy.value(atX: x) else { return }

                        let cal = Calendar.current
                        if let current = selectedDate,
                           cal.isDate(current, inSameDayAs: tappedDate) {
                            selectedDate = nil
                        } else {
                            selectedDate = tappedDate
                            let dateString = Self.dateStringFormatter.string(from: tappedDate)
                            onDaySelected?(dateString)
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selectedDate)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: axisStride)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.axisFormatter.string(from: date))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(yAxisLabel(v))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 180)
    }

    private var tooltipView: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let first = selectedDayData.first {
                Text(Self.axisFormatter.string(from: first.date))
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            ForEach(selectedDayData) { entry in
                HStack(spacing: 4) {
                    Circle()
                        .fill(modelColor(entry.model))
                        .frame(width: 6, height: 6)
                    Text(displayModelName(entry.model))
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Text(formatValue(entry.value))
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Metric helpers

    private func metricValue(from data: DailyModelEntry) -> Double {
        switch metric {
        case .sessions: Double(data.sessions)
        case .cost: data.cost
        case .tokens: Double(data.tokens)
        }
    }

    private func metricValue(from entry: StatsDailyEntry) -> Double {
        switch metric {
        case .sessions: Double(entry.sessions)
        case .cost: entry.cost
        case .tokens: Double(entry.tokens)
        }
    }

    private func yAxisLabel(_ v: Double) -> String {
        switch metric {
        case .cost:
            return v < 1.0 ? String(format: "$%.2f", v) : String(format: "$%.1f", v)
        case .sessions:
            return String(format: "%.0f", v)
        case .tokens:
            if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
            if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
            return String(format: "%.0f", v)
        }
    }

    private func formatValue(_ v: Double) -> String {
        switch metric {
        case .cost:
            return String(format: "$%.3f", v)
        case .sessions:
            return String(format: "%.0f", v)
        case .tokens:
            if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
            if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
            return String(format: "%.0f", v)
        }
    }
}
