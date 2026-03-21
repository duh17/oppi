import Charts
import SwiftUI

// MARK: - Chart data model

private struct ModelDayCost: Identifiable {
    let date: Date
    let model: String
    let cost: Double

    var id: String { "\(Int(date.timeIntervalSince1970))-\(model)" }
}

// MARK: - DailyCostChartView

struct DailyCostChartView: View {

    let daily: [StatsDailyEntry]

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

    // MARK: - Derived data

    /// Aggregate by display name per day so duplicate raw model names
    /// (e.g. "anthropic/claude-opus-4-6-20250514" and "claude-opus-4-6")
    /// merge into one bar segment with consistent color.
    private var chartData: [ModelDayCost] {
        var result: [ModelDayCost] = []
        for entry in daily {
            guard let date = Self.dateParser.date(from: entry.date) else { continue }
            if let byModel = entry.byModel, !byModel.isEmpty {
                // Group by display name to merge duplicates
                var byDisplay: [String: (raw: String, cost: Double)] = [:]
                for (model, data) in byModel where data.cost > 0 {
                    let name = displayModelName(model)
                    if let existing = byDisplay[name] {
                        byDisplay[name] = (existing.raw, existing.cost + data.cost)
                    } else {
                        byDisplay[name] = (model, data.cost)
                    }
                }
                for (_, value) in byDisplay {
                    result.append(ModelDayCost(date: date, model: value.raw, cost: value.cost))
                }
            } else if entry.cost > 0 {
                result.append(ModelDayCost(date: date, model: "other", cost: entry.cost))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private var selectedDayData: [ModelDayCost] {
        guard let sel = selectedDate else { return [] }
        let cal = Calendar.current
        return chartData
            .filter { cal.isDate($0.date, inSameDayAs: sel) }
            .sorted { $0.cost > $1.cost }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Daily Cost")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)

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
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.themeComment.opacity(0.08))
            .frame(height: 240)
            .overlay {
                Text("No data for this range")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
    }

    @ViewBuilder
    private var chartView: some View {
        Chart(chartData) { entry in
            BarMark(
                x: .value("Date", entry.date, unit: .day),
                y: .value("Cost", entry.cost)
            )
            .foregroundStyle(modelColor(entry.model))
        }
        .chartXSelection(value: $selectedDate)
        .animation(.none, value: chartData.map(\.id))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: axisStride)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.axisFormatter.string(from: date))
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        let label = v < 1.0
                            ? String(format: "$%.2f", v)
                            : String(format: "$%.1f", v)
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
            }
        }
        .frame(height: 240)
    }

    private var tooltipView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let first = selectedDayData.first {
                Text(Self.axisFormatter.string(from: first.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
            }
            ForEach(selectedDayData) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(modelColor(entry.model))
                        .frame(width: 7, height: 7)
                    Text(displayModelName(entry.model))
                        .font(.caption)
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "$%.3f", entry.cost))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.themeComment)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.themeComment.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
