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

    private var heapUsedMB: Int { Int(memory.heapUsed / (1024 * 1024)) }
    private var heapTotalMB: Int { Int(memory.heapTotal / (1024 * 1024)) }
    private var rssMB: Int { Int(memory.rss / (1024 * 1024)) }

    private var heapFraction: Double {
        guard memory.heapTotal > 0 else { return 0 }
        return min(memory.heapUsed / memory.heapTotal, 1.0)
    }

    private var barColor: Color {
        if heapFraction >= 0.9 { return .themeRed }
        if heapFraction >= 0.7 { return .themeOrange }
        return .themeGreen
    }

    private var memoryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heap: \(heapUsedMB) MB / \(heapTotalMB) MB")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.themeFg)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.themeComment.opacity(0.2))
                        .frame(height: 6)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * heapFraction, height: 6)
                }
            }
            .frame(height: 6)

            Text("RSS: \(rssMB) MB")
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
