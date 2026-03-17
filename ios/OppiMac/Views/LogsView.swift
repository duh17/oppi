import SwiftUI

struct LogsView: View {

    let processManager: ServerProcessManager

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(processManager.logBuffer) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(line.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.stream == .stderr ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .id(line.id)
                        }
                    }
                }
                .onChange(of: processManager.logBuffer.count) {
                    if autoScroll, let last = processManager.logBuffer.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Spacer()
                Text("\(processManager.logBuffer.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    processManager.clearLogs()
                }
                .controlSize(.small)
            }
            .padding(8)
        }
        .navigationTitle("Logs")
    }
}
