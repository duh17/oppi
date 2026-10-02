import SwiftUI

/// Native overview of the host's Herdr session: workspaces and their agents
/// with live lifecycle state. Selecting a row asks Herdr to focus it; the
/// attached Herdr client in the terminal follows.
struct HerdrAgentsView: View {
    let monitor: HerdrMonitor
    let channel: SSHTerminalChannel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let failure = monitor.failure {
                    Text(failure).font(.footnote).foregroundStyle(.themeRed)
                        .accessibilityIdentifier("sshTerminal.herdr.failure")
                }
                if let snapshot = monitor.snapshot {
                    if snapshot.workspaces.isEmpty {
                        Text("No Herdr workspaces.").foregroundStyle(.themeComment)
                    }
                    ForEach(snapshot.workspaces) { workspace in
                        Section {
                            Button { focus(.workspace(workspace.workspaceID)) } label: {
                                Label(workspace.label, systemImage: workspace.focused ? "checkmark.circle.fill" : "square.stack")
                                    .foregroundStyle(.themeFg)
                            }
                            .accessibilityValue(workspace.focused ? "Focused" : "")
                            ForEach(snapshot.agents(in: workspace)) { agent in
                                Button { focus(.agent(agent.paneID)) } label: {
                                    AgentRow(agent: agent, tab: snapshot.tabLabel(agent.tabID))
                                }
                                .accessibilityIdentifier("sshTerminal.herdr.agent")
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Herdr").navigationBarTitleDisplayMode(.inline)
            .refreshable { await monitor.refresh(on: channel) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func focus(_ target: HerdrRemote.FocusTarget) {
        Task {
            await monitor.focus(target, on: channel)
            if monitor.failure == nil { dismiss() }
        }
    }
}

private struct AgentRow: View {
    let agent: HerdrSnapshot.Agent
    let tab: String?

    var body: some View {
        HStack(spacing: 10) {
            status
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).foregroundStyle(.themeFg).lineLimit(1)
                if let subtitle = agent.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.themeComment).lineLimit(1)
                }
            }
            Spacer()
            if let tab { Text("tab \(tab)").font(.caption).foregroundStyle(.themeComment) }
            if agent.focused { Image(systemName: "eye").font(.caption).foregroundStyle(.themeComment) }
        }
        .padding(.leading, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue(label)
    }

    private var label: String {
        switch agent.status {
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Unknown state"
        }
    }

    @ViewBuilder private var status: some View {
        switch agent.status {
        case .working: ProgressView().controlSize(.small)
        case .blocked: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.themeOrange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.themeGreen)
        case .idle: Image(systemName: "circle").foregroundStyle(.themeComment)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.themeComment)
        }
    }
}
