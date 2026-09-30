import SwiftUI

/// One MCP scope on the active host. The sidebar shows the global scope; each host
/// workspace shows its own `.pi/mcp.json` from Workspace settings, like Pi extensions.
struct McpServersView: View {
    /// `McpScopeSnapshot.globalId`, or a host workspace id.
    let scopeId: String

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(ServerStore.self) private var serverStore
    @State private var model = McpServersModel()
    @State private var addContext: McpAddContext?
    @Environment(\.scenePhase) private var scenePhase

    private var server: PairedServer? {
        serverStore.servers.first { $0.id == coordinator.activeServerId }
    }
    private var client: APIClient? {
        coordinator.activeServerId.flatMap { coordinator.connection(for: $0)?.apiClient }
    }

    private var signIn: McpSignInOwner { model.signIn }
    private var snapshot: McpServersResponse? { model.snapshot }
    private var error: String? { model.error }
    private var loading: Bool { model.loading }
    private var isGlobal: Bool { scopeId == McpScopeSnapshot.globalId }

    var body: some View {
        List {
            // A workspace belongs to one host; only the global list can switch hosts.
            if isGlobal, let server {
                Section {
                    ServerCatalogServerRow(selectedServer: server) { _ in }
                }
            }
            if let attempt = signIn.attempt, signIn.hasActive {
                Section("Sign-in on \(attempt.serverName)") {
                    Text(attempt.providerName)
                    Button("Continue Sign-in") { signIn.resume() }
                        .accessibilityIdentifier("mcp.auth.continue")
                    Button("Cancel Sign-in", role: .destructive) { Task { await signIn.cancel() } }
                        .disabled(attempt.isCancelling)
                        .accessibilityIdentifier("mcp.auth.cancel")
                    if let error = attempt.actionError { Text(error).foregroundStyle(.themeRed) }
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.themeRed)
                    Button("Retry") { Task { await refresh() } }
                }
            }
            if loading {
                Section { ProgressView("Probing MCP servers…") }
            }
            if let scope = snapshot?.scope, let client, let server {
                // Project trust is shown once, in Edit Workspace above this list.
                Section {
                    ForEach(scope.errors, id: \.self) { Text($0).foregroundStyle(.themeRed) }
                    if scope.servers.isEmpty {
                        Text("No MCP servers configured").foregroundStyle(.themeComment)
                    }
                    ForEach(scope.servers) { entry in
                        NavigationLink {
                            McpServerDetailView(
                                scope: scope, entry: entry, client: client,
                                serverId: server.id, serverName: server.name, signIn: signIn
                            )
                        } label: {
                            serverRow(entry)
                        }
                        .accessibilityIdentifier("mcp.server.\(scope.id).\(entry.name)")
                    }
                } header: {
                    if !isGlobal { Text("This Workspace") }
                } footer: {
                    Text(isGlobal
                        ? "Global servers from ~/.pi/agent/mcp.json load in every host workspace. Each workspace\u{2019}s own servers are in its Workspace settings."
                        : "Servers from this workspace\u{2019}s .pi/mcp.json. A server here replaces a global server with the same name.")
                }
                if let inherited = scope.inherited, !inherited.isEmpty {
                    Section {
                        ForEach(inherited) { entry in
                            serverRow(entry)
                                .accessibilityIdentifier("mcp.inherited.\(scope.id).\(entry.name)")
                        }
                    } header: {
                        Text("From Global")
                    } footer: {
                        Text("Global servers that also load in this workspace. Change them from MCP Servers in the sidebar.")
                    }
                }
            } else if !loading, error == nil {
                ContentUnavailableView("MCP Servers Unavailable", systemImage: "server.rack", description: Text("Connect to a paired server to manage MCP."))
            }
            Section {
                Text("Refresh probes Pi's configured servers, not running sessions. Configuration changes apply to new sessions or /reload.")
                    .font(.footnote).foregroundStyle(.themeComment)
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add MCP Server", systemImage: "plus") {
                    if let client, let snapshot, let server {
                        addContext = McpAddContext(client: client, scope: snapshot.scope, serverName: server.name)
                    }
                }
                .disabled(snapshot == nil || loading || signIn.hasActive)
                .accessibilityIdentifier("mcp.add")
            }
        }
        .refreshable { await refresh() }
        .task(id: coordinator.activeServerId) { await refresh() }
        .sheet(isPresented: Binding(get: { model.signIn.showingSheet }, set: { model.signIn.showingSheet = $0 }), onDismiss: { signIn.sheetDismissed() }) {
            if let attempt = signIn.attempt { McpSignInSheet(attempt: attempt, owner: signIn) }
        }
        .onChange(of: signIn.attempt?.flow.status) { _, status in
            if status?.isTerminal == true { Task { await refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { signIn.attempt?.startPolling() } else { signIn.attempt?.stopPolling() }
        }
        .sheet(item: $addContext) { context in
            McpAddServerView(client: context.client, scope: context.scope, serverName: context.serverName) {
                Task { await refresh() }
            }
        }
    }

    private func serverRow(_ entry: McpServerSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.headline)
            Text("\(entry.transport == "http" ? "URL" : "Command") · \(entry.tools.count) tools · \(entry.exposure.rawValue)")
                .font(.subheadline).foregroundStyle(.themeComment)
            Label(entry.stateLabel, systemImage: entry.state == "connected" ? "checkmark.circle" : "circle")
                .font(.caption).foregroundStyle(statusStyle(entry.state))
        }
    }

    private func statusStyle(_ state: String) -> AnyShapeStyle {
        switch state {
        case "connected": AnyShapeStyle(.themeGreen)
        case "disabled", "replaced": AnyShapeStyle(.secondary)
        case "failed", "disconnected": AnyShapeStyle(.themeRed)
        case "needs-auth", "untrusted": AnyShapeStyle(.themeOrange)
        default: AnyShapeStyle(.themeComment)
        }
    }

    private func refresh() async {
        guard let server, let client else { return }
        await model.refresh(
            hostId: server.id, hostName: server.name,
            flowClient: McpFlowClient(client: client)
        ) { try await client.listMcpServers(scopeId: scopeId) }
    }
}
private struct McpAddContext: Identifiable {
    let id = UUID()
    let client: APIClient
    let scope: McpScopeSnapshot
    let serverName: String
}

/// Rows for Edit Workspace → MCP Servers in a sandbox: the global servers, ticked when
/// this sandbox may load them. The server reports which ones cannot run there and why.
struct SandboxMcpServerPicker: View {
    let workspaceId: String
    /// Allowed Hosts has unsaved edits, so the server's eligibility may be out of date.
    let hostsEdited: Bool
    @Binding var selection: Set<String>
    @Environment(\.apiClient) private var apiClient
    @State private var servers: [McpServerSummary]?
    @State private var error: String?

    /// Picked names no longer in the global list, so they can still be unticked.
    private var missing: [String] {
        let known = Set(servers?.map(\.name) ?? [])
        return selection.subtracting(known).sorted()
    }

    var body: some View {
        Group {
            if let servers {
                if servers.isEmpty && missing.isEmpty {
                    Text("No global MCP servers. Add them from MCP Servers in the sidebar.")
                        .foregroundStyle(.themeComment)
                }
                if hostsEdited {
                    Text("Save to recheck servers against the new Allowed Hosts.")
                        .font(.caption)
                        .foregroundStyle(.themeOrange)
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
            } else if let error {
                Text(error).foregroundStyle(.themeRed)
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading MCP servers\u{2026}")
            }
        }
        .task(id: workspaceId) { await load() }
    }

    private func detail(for entry: McpServerSummary) -> String {
        if let reason = entry.error { return reason }
        if entry.state == "disabled" { return "Disabled in the global mcp.json." }
        if let url = entry.config.url { return url }
        let command = ([entry.config.command ?? ""] + (entry.config.args ?? [])).joined(separator: " ")
        return "Runs in the VM: \(command). The agent can read its settings."
    }

    /// A blocked or disabled server cannot be newly ticked, but a stale tick can be cleared.
    private func row(name: String, detail: String, blocked: Bool, warning: Bool) -> some View {
        let isSelected = selection.contains(name)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(blocked ? .themeComment : .themeFg)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(warning ? .themeOrange : .themeComment)
            }
            Spacer(minLength: 12)
            WorkspaceSelectionButton(
                isSelected: isSelected,
                accessibilityLabel: isSelected ? "Stop \(name) in this sandbox" : "Allow \(name) in this sandbox"
            ) {
                if isSelected { selection.remove(name) } else { selection.insert(name) }
            }
            .disabled(blocked && !isSelected)
        }
        .accessibilityIdentifier("workspace.edit.sandboxMcp.\(name)")
    }

    private func load() async {
        guard let apiClient else { error = "Server is offline"; return }
        error = nil
        do {
            servers = try await apiClient.listMcpServers(scopeId: workspaceId).scope.servers
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
