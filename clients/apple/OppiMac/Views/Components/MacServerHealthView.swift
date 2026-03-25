import SwiftUI

/// Server health section showing memory usage, uptime, and active session count.
///
/// Matches the iOS `ServerHealthSection` feature set with Mac-appropriate styling.
struct MacServerHealthView: View {

    let memory: StatsMemory
    let serverInfo: ServerHealthMonitor.ServerInfo?
    let activeSessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server")
                .font(.caption)
                .foregroundStyle(.secondary)

            memoryBar

            if let uptime = serverInfo?.uptime {
                infoRow(label: "Uptime", value: uptime)
            }
            if let version = serverInfo?.version, version != "unknown" {
                infoRow(label: "Version", value: version)
            }
            infoRow(label: "Active Sessions", value: "\(activeSessionCount)")
        }
    }

    // MARK: - Memory bar

    private var heapUsedMB: Int { Int(memory.heapUsed.rounded()) }
    private var heapTotalMB: Int { Int(memory.heapTotal.rounded()) }
    private var rssMB: Int { Int(memory.rss.rounded()) }

    private var heapFraction: Double {
        guard memory.heapTotal > 0 else { return 0 }
        return min(memory.heapUsed / memory.heapTotal, 1.0)
    }

    private var barColor: Color {
        if heapFraction >= 0.9 { return .red }
        if heapFraction >= 0.7 { return .orange }
        return .green
    }

    private var memoryBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heap: \(heapUsedMB) MB / \(heapTotalMB) MB")
                .font(.caption2.monospacedDigit())

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * heapFraction, height: 4)
                }
            }
            .frame(height: 4)

            Text("RSS: \(rssMB) MB")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Info row

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2.monospacedDigit())
        }
    }
}
