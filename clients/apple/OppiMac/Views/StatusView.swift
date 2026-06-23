import SwiftUI

struct StatusView: View {

    let processManager: ServerProcessManager
    let healthMonitor: ServerHealthMonitor
    let sessionMonitor: MacSessionMonitor

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
                        Task {
                            await MacServerLifecycle.startOrAttachFromLocalConfig(
                                processManager: processManager,
                                healthMonitor: healthMonitor,
                                sessionMonitor: sessionMonitor,
                                allowKillingExistingServer: true
                            )
                        }
                    }
                case .running:
                    Button(processManager.processOwner == .externalProcess ? "Restart Background Server" : "Restart Server") {
                        Task {
                            await MacServerLifecycle.restartFromLocalConfig(
                                processManager: processManager,
                                healthMonitor: healthMonitor,
                                sessionMonitor: sessionMonitor,
                                allowKillingExistingServer: true
                            )
                        }
                    }
                    Button(processManager.processOwner == .externalProcess ? "Stop Background Server" : "Stop Server") {
                        Task {
                            await MacServerLifecycle.stopFromLocalConfig(
                                processManager: processManager,
                                healthMonitor: healthMonitor,
                                sessionMonitor: sessionMonitor
                            )
                        }
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
        case .running: processManager.processOwner == .externalProcess ? "Running (Background)" : "Running"
        case .stopping: "Stopping..."
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
