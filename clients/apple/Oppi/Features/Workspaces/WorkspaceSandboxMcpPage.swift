import SwiftUI

/// MCP servers of a sandbox workspace: the global servers, with a toggle for
/// each one this sandbox may load. A toggle saves at once. The server reports
/// which servers cannot run in the VM and why.
struct WorkspaceSandboxMcpPage: View {
    let model: WorkspaceSettingsModel

    /// Picked names no longer in the global list, so they can still be switched off.
    private func missing(from servers: [McpServerSummary]) -> [String] {
        model.sandboxMcpSelection.subtracting(servers.map(\.name)).sorted()
    }

    var body: some View {
        List {
            Section {
                content
                if let error = model.sandboxMcpError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.themeRed)
                        .accessibilityIdentifier("workspace.edit.sandboxMcp.error")
                }
            } footer: {
                Text("Only enabled servers load here. Web servers are called from your server, only to Allowed Hosts, and their sign-in stays there. Command servers run inside the VM, where the agent can read their settings; ones that use host secrets are blocked. A workspace Tools list hides MCP servers.")
            }
        }
        .settingsPage("MCP Servers")
        .task {
            await model.loadSandboxMcpServers()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let servers = model.sandboxMcpServers {
            let missing = missing(from: servers)
            if servers.isEmpty && missing.isEmpty {
                Text("No global MCP servers. Add them from MCP Servers in the sidebar.")
                    .foregroundStyle(.themeComment)
            }
            ForEach(servers) { entry in
                row(
                    name: entry.name,
                    detail: detail(for: entry),
                    blocked: entry.state == "blocked" || entry.state == "disabled",
                    warning: entry.state == "blocked"
                )
            }
            ForEach(missing, id: \.self) { name in
                row(name: name, detail: "Not in the global mcp.json.", blocked: true, warning: true)
            }
        } else if let error = model.sandboxMcpLoadError {
            Text(error).foregroundStyle(.themeRed)
            Button("Retry") { Task { await model.loadSandboxMcpServers() } }
        } else {
            ProgressView("Loading MCP servers\u{2026}")
        }
    }

    private func detail(for entry: McpServerSummary) -> String {
        if let reason = entry.error { return reason }
        if entry.state == "disabled" { return "Disabled in the global mcp.json." }
        if let url = entry.config.url { return url }
        let command = ([entry.config.command ?? ""] + (entry.config.args ?? [])).joined(separator: " ")
        return "Runs in the VM: \(command). The agent can read its settings."
    }

    /// A blocked or disabled server cannot be newly enabled, but a stale pick can be cleared.
    private func row(name: String, detail: String, blocked: Bool, warning: Bool) -> some View {
        let isSelected = model.sandboxMcpSelection.contains(name)
        return Toggle(
            isOn: Binding(
                get: { isSelected },
                set: { enabled in
                    Task { await model.setSandboxMcpServer(name, enabled: enabled) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(blocked ? .themeComment : .themeFg)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(warning ? .themeOrange : .themeComment)
            }
        }
        .disabled(blocked && !isSelected)
        .accessibilityIdentifier("workspace.edit.sandboxMcp.\(name)")
    }
}
