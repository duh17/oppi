import SwiftUI

struct ServerHealthSection: View {
    let memory: StatsMemory
    let uptime: String?
    let platform: String?
    let activeSessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)

            memoryBar

            if let uptime {
                infoRow(label: "Uptime", value: uptime)
            }
            if let platform {
                infoRow(label: "Platform", value: platform)
            }
            infoRow(label: "Active Sessions", value: "\(activeSessionCount)")
        }
    }

    // MARK: - Memory bar

    // Server returns memory values already in MB.
    private var heapUsedMB: Int { Int(memory.heapUsed.rounded()) }
    private var heapTotalMB: Int { Int(memory.heapTotal.rounded()) }
    private var rssMB: Int { Int(memory.rss.rounded()) }

    /// RSS is the real process memory footprint. Thresholds:
    /// green < 256 MB, orange < 512 MB, red >= 512 MB.
    private var rssBarColor: Color {
        if memory.rss >= 512 { return .themeRed }
        if memory.rss >= 256 { return .themeOrange }
        return .themeGreen
    }

    /// Bar fill as fraction of 1 GB ceiling for visual scaling.
    private var rssFraction: Double {
        min(memory.rss / 1024, 1.0)
    }

    private var memoryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RSS: \(rssMB) MB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.themeFg)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.themeComment.opacity(0.2))
                        .frame(height: 6)
                    Capsule()
                        .fill(rssBarColor)
                        .frame(width: geo.size.width * rssFraction, height: 6)
                }
            }
            .frame(height: 6)

            Text("Heap: \(heapUsedMB) MB / \(heapTotalMB) MB")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)
        }
    }

    // MARK: - Info row

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.themeComment)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.themeFg)
        }
    }
}
