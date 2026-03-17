import SwiftUI

struct StatusPlaceholderView: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Status") {
                    Text(stateLabel)
                }
                if let info = healthMonitor.serverInfo {
                    LabeledContent("URL") {
                        Text(info.serverURL)
                    }
                    LabeledContent("Version") {
                        Text(info.version)
                    }
                    if let uptime = info.uptime {
                        LabeledContent("Uptime") {
                            Text(uptime)
                        }
                    }
                }
                if let piVersion = healthMonitor.piCLIVersion {
                    LabeledContent("Pi CLI") {
                        Text(piVersion)
                    }
                }
            }

            Section("Actions") {
                switch processManager.state {
                case .stopped, .failed:
                    Button("Start Server") {
                        processManager.startWithDefaults()
                    }
                case .running:
                    Button("Restart Server") {
                        Task { await processManager.restart() }
                    }
                    Button("Stop Server") {
                        Task { await processManager.stop() }
                    }
                case .starting, .stopping:
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Status")
    }

    private var stateLabel: String {
        switch processManager.state {
        case .stopped: "Stopped"
        case .starting: "Starting..."
        case .running: "Running"
        case .stopping: "Stopping..."
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
