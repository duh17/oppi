import Charts
import SwiftUI

// MARK: - DailyCostChart

struct DailyCostChart: View {

    let daily: [StatsDailyEntry]
    var metric: StatsMetric = .cost
    var onDaySelected: ((String) -> Void)?

    @State private var selectedDate: Date?

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

    private var chartData: [StatsModelDayValue] {
        metric.modelDayValues(from: daily)
    }

    private var selectedDayData: [StatsModelDayValue] {
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

    private func isSelected(_ entry: StatsModelDayValue) -> Bool {
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
                        Text(metric.axisLabel(v))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 180)
    }

    private var tooltipView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let first = selectedDayData.first {
                Text(Self.axisFormatter.string(from: first.date))
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            ForEach(selectedDayData) { entry in
                tooltipRow(for: entry)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func tooltipRow(for entry: StatsModelDayValue) -> some View {
        HStack(spacing: 6) {
            ProviderGlyph(provider: modelProviderKey(entry.model), size: 10, color: .secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(displayModelName(entry.model))
                    .font(.caption2)
                    .foregroundStyle(modelColor(entry.model))
                    .lineLimit(1)

                if let provider = modelProviderLabel(entry.model) {
                    Text(provider)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(metric.displayValue(entry.value))
                .font(.caption2)
                .monospacedDigit()
        }
    }
}
