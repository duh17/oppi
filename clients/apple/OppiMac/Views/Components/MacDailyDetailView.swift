import Charts
import SwiftUI

// MARK: - MacDailyDetailView

/// Hourly drill-down for a single day. Shows an hourly stacked bar chart
/// and a session list. Presented inline when the user taps a bar in the
/// daily chart.
struct MacDailyDetailView: View {

    let detail: DailyDetail
    let onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.displayDayTitle)
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

            if !detail.hourlyCostValues.isEmpty {
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

                Text(statsTimeLabel(epochMilliseconds: session.createdAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
