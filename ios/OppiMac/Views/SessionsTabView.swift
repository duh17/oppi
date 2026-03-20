import SwiftUI

/// Live sessions panel shown in the Sessions tab of the menu bar popover.
///
/// Displays a compact summary row (active count, cost, memory) followed by
/// per-session ``SessionRowView`` cards. Shows an empty state when no sessions
/// are running.
struct SessionsTabView: View {

    let monitor: MacSessionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stats = monitor.stats {
                summaryRow(stats: stats)
                Divider()
                sessionList(stats.activeSessions)
            } else {
                loadingState
            }
        }
    }

    // MARK: - Summary row

    @ViewBuilder
    private func summaryRow(stats: ServerStats) -> some View {
        let total = stats.activeSessions.count
        let busy = stats.activeSessions.filter { $0.status == "busy" }.count

        HStack(spacing: 10) {
            // Active / busy count
            Label {
                Text(busy > 0 ? "\(busy)/\(total)" : "\(total)")
                    .font(.caption)
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(busy > 0 ? .orange : .secondary)
            }

            // Today's cost
            Label {
                Text("$\(String(format: "%.2f", stats.totals.cost))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "dollarsign")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Memory (RSS)
            Label {
                Text("\(Int(stats.memory.rss)) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "memorychip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Session list

    @ViewBuilder
    private func sessionList(_ sessions: [StatsActiveSession]) -> some View {
        if sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRowView(session: session)
                        if index < sessions.count - 1 {
                            Divider()
                                .padding(.leading, 20)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    // MARK: - Empty / loading states

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "bolt.slash")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("No active sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            Spacer()
        }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 12)
            Spacer()
        }
    }
}
