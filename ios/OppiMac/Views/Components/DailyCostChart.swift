import Charts
import SwiftUI

// MARK: - Shared model-color helpers (used by DailyCostChart + ModelBreakdownView)

func modelColor(_ model: String) -> Color {
    let lower = model.lowercased()
    if lower.contains("sonnet") { return .green }
    if lower.contains("opus")   { return .blue }
    if lower.contains("haiku")  { return .teal }
    if lower.contains("gpt")    { return .orange }
    if lower.contains("gemini") { return Color(red: 0.2, green: 0.6, blue: 1.0) }
    // Deterministic color for unknown models
    let hue = Double(abs(model.hashValue % 300) + 30) / 360.0
    return Color(hue: hue, saturation: 0.55, brightness: 0.70)
}

/// Shorten model names for display.
/// "anthropic/claude-sonnet-4-6-20250514" → "sonnet-4-6"
func displayModelName(_ model: String) -> String {
    // Strip provider prefix (e.g. "anthropic/")
    let last = String(model.split(separator: "/").last ?? Substring(model))
    var cleaned = last.replacingOccurrences(of: "claude-", with: "")
    // Drop trailing 8-digit date segment
    let parts = cleaned.split(separator: "-")
    if let tail = parts.last, tail.count >= 8, tail.allSatisfy(\.isNumber) {
        cleaned = parts.dropLast().joined(separator: "-")
    }
    return cleaned
}

// MARK: - Chart data model

private struct ModelDayCost: Identifiable {
    let id = UUID()
    let date: Date
    let model: String
    let cost: Double
}

// MARK: - DailyCostChart

struct DailyCostChart: View {

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

    private var chartData: [ModelDayCost] {
        var result: [ModelDayCost] = []
        for entry in daily {
            guard let date = Self.dateParser.date(from: entry.date) else { continue }
            if let byModel = entry.byModel, !byModel.isEmpty {
                for (model, data) in byModel where data.cost > 0 {
                    result.append(ModelDayCost(date: date, model: model, cost: data.cost))
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
        if count <= 7  { return 1 }
        if count <= 14 { return 2 }
        if count <= 30 { return 7 }
        return 14
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Daily Cost")
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
            .frame(height: 120)
            .overlay {
                Text("No data for this range")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
                        let label = v < 1.0
                            ? String(format: "$%.2f", v)
                            : String(format: "$%.1f", v)
                        Text(label)
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 120)
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
                    Text(String(format: "$%.3f", entry.cost))
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
