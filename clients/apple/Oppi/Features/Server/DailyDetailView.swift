import Charts
import SwiftUI

// MARK: - DailyDetailView

/// Hourly drill-down for a single day.
///
/// Shows an hourly stacked bar chart and a session list below.
/// Presented inline when the user taps a bar in the daily cost chart.
struct DailyDetailView: View {

    let detail: DailyDetail
    let onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.displayDayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                    Text("\(detail.totals.sessions) sessions — \(SessionFormatting.costString(detail.totals.cost))")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.themeComment)
                }
                .buttonStyle(.plain)
            }

            if !detail.hourlyCostValues.isEmpty {
                hourlyChart
            }

            if !detail.sessions.isEmpty {
                sessionList
            }
        }
        .padding(12)
        .background(.themeComment.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Hourly Chart

    private var hourlyChart: some View {
        Chart(detail.hourlyCostValues) { entry in
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
                        Text(statsHourLabel(h))
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
                        Text(SessionFormatting.costString(v))
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
            }
        }
        .chartXScale(domain: 0...23)
        .frame(height: 160)
    }

    // MARK: - Session List

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeComment)
                .padding(.bottom, 6)

            ForEach(detail.sessions.prefix(10), id: \.id) { session in
                sessionRow(session)
                if session.id != detail.sessions.prefix(10).last?.id {
                    Divider().padding(.leading, 24)
                }
            }

            if detail.sessions.count > 10 {
                Text("+\(detail.sessions.count - 10) more")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .padding(.top, 4)
            }
        }
    }

    private func sessionRow(_ session: StatsDailySession) -> some View {
        let model = session.model ?? "unknown"

        return HStack(spacing: 8) {
            ProviderGlyph(provider: modelProviderKey(model), size: 11, color: .themeComment)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? "Session \(String(session.id.prefix(8)))")
                    .font(.caption)
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)

                Text(displayModelName(model))
                    .font(.caption2)
                    .foregroundStyle(modelColor(model))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let provider = modelProviderLabel(model) {
                        Text(provider)
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }

                    if let ws = session.workspaceName {
                        Text(ws)
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(SessionFormatting.costString(session.cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.themeFg)

                Text(statsTimeLabel(epochMilliseconds: session.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
            }
        }
        .padding(.vertical, 5)
    }
}
