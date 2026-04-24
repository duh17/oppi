import Charts
import SwiftUI

// MARK: - Chart data model

private struct ModelDayCost: Identifiable {
    let date: Date
    let model: String
    let value: Double

    var id: String { "\(Int(date.timeIntervalSince1970))-\(model)" }
}

// MARK: - DailyCostChartView

struct DailyCostChartView: View {

    let daily: [StatsDailyEntry]

    /// Which metric to chart. Defaults to cost.
    var metric: StatsMetric = .cost

    /// Called when the user selects a day (date string "YYYY-MM-DD").
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

    /// Aggregate by provider + stable model id so timestamp-only variants merge.
    private var chartData: [ModelDayCost] {
        var result: [ModelDayCost] = []
        for entry in daily {
            guard let date = Self.dateParser.date(from: entry.date) else { continue }
            if let byModel = entry.byModel, !byModel.isEmpty {
                var byIdentity: [String: (raw: String, sortKey: String, value: Double)] = [:]
                for (model, data) in byModel {
                    let value = metricValue(from: data)
                    guard value > 0 else { continue }
                    let identity = modelDisplayIdentity(model)
                    let key = identity.aggregationKey
                    let sortKey = "\(identity.displayName)|\(identity.providerDisplayName ?? "")"
                    if let existing = byIdentity[key] {
                        byIdentity[key] = (existing.raw, existing.sortKey, existing.value + value)
                    } else {
                        byIdentity[key] = (model, sortKey, value)
                    }
                }
                for (_, item) in byIdentity.sorted(by: { $0.value.sortKey < $1.value.sortKey }) {
                    result.append(ModelDayCost(date: date, model: item.raw, value: item.value))
                }
            } else {
                let value = metricValue(from: entry)
                if value > 0 {
                    result.append(ModelDayCost(date: date, model: "other", value: value))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private var selectedDayData: [ModelDayCost] {
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
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.chartTitle)
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

    /// Whether a bar entry belongs to the selected day.
    private func isSelected(_ entry: ModelDayCost) -> Bool {
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
                            dailyDetail(nil)
                        } else {
                            selectedDate = tappedDate
                            let dateString = Self.dateStringFormatter.string(from: tappedDate)
                            dailyDetail(dateString)
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
                        Text(yAxisLabel(v))
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
            }
        }
        .frame(height: 240)
    }

    /// Notify the parent of the selected date (or nil to clear).
    private func dailyDetail(_ dateString: String?) {
        if let dateString {
            onDaySelected?(dateString)
        }
    }

    private var tooltipView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let first = selectedDayData.first {
                Text(Self.axisFormatter.string(from: first.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeFg)
            }
            ForEach(selectedDayData) { entry in
                tooltipRow(for: entry)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.themeComment.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tooltipRow(for entry: ModelDayCost) -> some View {
        HStack(spacing: 8) {
            ProviderGlyph(provider: modelProviderKey(entry.model), size: 11, color: .themeComment)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayModelName(entry.model))
                    .font(.caption)
                    .foregroundStyle(modelColor(entry.model))
                    .lineLimit(1)

                if let provider = modelProviderLabel(entry.model) {
                    Text(provider)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(formatValue(entry.value))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.themeComment)
        }
    }

    // MARK: - Metric helpers

    private func metricValue(from data: DailyModelEntry) -> Double {
        switch metric {
        case .sessions: return Double(data.sessions)
        case .cost: return data.cost
        case .tokens: return Double(data.tokens)
        }
    }

    private func metricValue(from entry: StatsDailyEntry) -> Double {
        switch metric {
        case .sessions: return Double(entry.sessions)
        case .cost: return entry.cost
        case .tokens: return Double(entry.tokens)
        }
    }

    private func yAxisLabel(_ v: Double) -> String {
        switch metric {
        case .cost:
            return SessionFormatting.costString(v)
        case .sessions:
            return String(format: "%.0f", v)
        case .tokens:
            if v >= 1_000_000 {
                return String(format: "%.1fM", v / 1_000_000)
            } else if v >= 1_000 {
                return String(format: "%.0fK", v / 1_000)
            }
            return String(format: "%.0f", v)
        }
    }

    private func formatValue(_ v: Double) -> String {
        switch metric {
        case .cost:
            return SessionFormatting.costString(v)
        case .sessions:
            return String(format: "%.0f", v)
        case .tokens:
            if v >= 1_000_000 {
                return String(format: "%.1fM", v / 1_000_000)
            } else if v >= 1_000 {
                return String(format: "%.1fK", v / 1_000)
            }
            return String(format: "%.0f", v)
        }
    }
}
