import Charts
import SwiftUI

/// GitHub contributions-style activity heatmap.
///
/// X axis = week column (oldest at left), Y axis = day of week (Mon at top).
/// Cell color = dominant model that day, opacity = log-scaled session count.
/// Only meaningful for 30d and 90d ranges.
struct ActivityHeatmap: View {

    let daily: [StatsDailyEntry]

    // MARK: - Cell model

    private struct HeatCell: Identifiable {
        let id: String         // "\(weekCol)-\(displayRow)"
        let weekCol: Int
        let displayRow: Int    // Mon=6 (top of chart) .. Sun=0 (bottom)
        let sessions: Int
        let dominantModel: String?
    }

    // MARK: - Data transformation

    private var cells: [HeatCell] {
        guard !daily.isEmpty else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var parsed: [(date: Date, entry: StatsDailyEntry)] = []
        for entry in daily {
            if let d = fmt.date(from: entry.date) {
                parsed.append((d, entry))
            }
        }
        guard let oldest = parsed.map(\.date).min() else { return [] }

        // Offset of oldest date from Monday (Mon=0..Sun=6 in Mon-first week).
        let oldestGreg = cal.component(.weekday, from: oldest) // 1=Sun..7=Sat
        let oldestMonSun = (oldestGreg + 5) % 7                // Mon=0..Sun=6

        return parsed.map { date, entry in
            let greg    = cal.component(.weekday, from: date)   // 1=Sun..7=Sat
            let monSun  = (greg + 5) % 7                        // Mon=0..Sun=6
            let dayDiff = cal.dateComponents([.day], from: oldest, to: date).day ?? 0
            let weekCol = (dayDiff + oldestMonSun) / 7
            // Flip so Mon=6 renders at chart top (y increases upward).
            let displayRow = 6 - monSun

            let dominant = entry.byModel?
                .max(by: { $0.value.sessions < $1.value.sessions })?.key

            return HeatCell(
                id: "\(weekCol)-\(displayRow)",
                weekCol: weekCol,
                displayRow: displayRow,
                sessions: entry.sessions,
                dominantModel: dominant
            )
        }
    }

    private var maxSessions: Int { max(1, cells.map(\.sessions).max() ?? 1) }

    private func cellOpacity(_ n: Int) -> Double {
        guard n > 0 else { return 0 }
        return max(0.2, log(Double(n) + 1) / log(Double(maxSessions) + 1))
    }

    private func cellColor(_ cell: HeatCell) -> Color {
        guard cell.sessions > 0 else { return Color.gray.opacity(0.08) }
        return modelColor(cell.dominantModel ?? "").opacity(cellOpacity(cell.sessions))
    }

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            heatChart
            legendRow
        }
    }

    @ViewBuilder
    private var heatChart: some View {
        let allCells = cells
        if allCells.isEmpty {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
                .frame(height: 80)
                .overlay {
                    Text("No data")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
        } else {
            let maxWeek = allCells.map(\.weekCol).max() ?? 0
            Chart(allCells) { cell in
                RectangleMark(
                    xStart: .value("WkStart", cell.weekCol),
                    xEnd:   .value("WkEnd",   cell.weekCol + 1),
                    yStart: .value("DayStart", cell.displayRow),
                    yEnd:   .value("DayEnd",   cell.displayRow + 1)
                )
                .foregroundStyle(cellColor(cell))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [6, 4, 2]) { value in
                    AxisValueLabel {
                        let v = value.as(Int.self) ?? -1
                        let label = v == 6 ? "M" : v == 4 ? "W" : v == 2 ? "F" : ""
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartXScale(domain: 0...(maxWeek + 1))
            .chartYScale(domain: 0...7)
            .frame(height: 80)
        }
    }

    private var legendRow: some View {
        HStack(spacing: 6) {
            let models = Array(Set(cells.compactMap(\.dominantModel))).sorted()
            ForEach(models, id: \.self) { model in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(modelColor(model))
                        .frame(width: 7, height: 7)
                    Text(displayModelName(model))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("less")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            HStack(spacing: 1) {
                ForEach([0.1, 0.3, 0.55, 0.75, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green.opacity(opacity))
                        .frame(width: 6, height: 6)
                }
            }
            Text("more")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}
