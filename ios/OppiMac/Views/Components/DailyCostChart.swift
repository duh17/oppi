import Charts
import SwiftUI

// MARK: - Shared model-color helpers (used by DailyCostChart + ModelBreakdownView)

/// Brand-aligned model colors.
///
/// Anthropic (Claude): warm orange/sienna family — opus is deep amber,
/// sonnet is warm orange, haiku is light apricot.
/// OpenAI: ChatGPT teal green.
/// Google: Gemini blue.
/// Local/MLX: neutral gray.
func modelColor(_ model: String) -> Color {
    let lower = model.lowercased()
    // Anthropic — orange variants
    if lower.contains("opus")   { return Color(red: 0.80, green: 0.42, blue: 0.17) } // #CC6B2C deep amber
    if lower.contains("sonnet") { return Color(red: 0.91, green: 0.57, blue: 0.31) } // #E8924E warm orange
    if lower.contains("haiku")  { return Color(red: 0.94, green: 0.72, blue: 0.48) } // #F0B87A apricot
    // OpenAI — teal green
    if lower.contains("gpt") || lower.contains("codex") { return Color(red: 0.06, green: 0.64, blue: 0.50) } // #10A37F
    // Google — Gemini blue
    if lower.contains("gemini") { return Color(red: 0.26, green: 0.52, blue: 0.96) } // #4285F4
    // Local/MLX — neutral
    if lower.contains("mlx")    { return Color(red: 0.55, green: 0.55, blue: 0.60) } // #8C8C99
    // Deterministic fallback
    let hue = Double(abs(model.hashValue % 300) + 30) / 360.0
    return Color(hue: hue, saturation: 0.5, brightness: 0.65)
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
    let date: Date
    let model: String
    let cost: Double

    var id: String { "\(Int(date.timeIntervalSince1970))-\(model)" }
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
            .frame(height: 180)
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
        .animation(.none, value: chartData.map(\.id))
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
