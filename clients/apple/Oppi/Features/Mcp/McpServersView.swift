import SwiftUI

struct McpServersView: View {
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

    var body: some View {
        List {
            if let server {
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
            if let snapshot, let client, let server {
                ForEach(snapshot.scopes.filter { $0.kind == "global" || $0.hasConfig }) { scope in
                    Section(scope.title) {
                        if let note = scope.note {
                            Label(note, systemImage: "lock.shield")
                                .font(.subheadline).foregroundStyle(.themeOrange)
                        }
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).font(.headline)
                                    Text("\(entry.transport == "http" ? "URL" : "Command") · \(entry.tools.count) tools · \(entry.exposure.rawValue)")
                                        .font(.subheadline).foregroundStyle(.themeComment)
                                    Label(entry.stateLabel, systemImage: entry.state == "connected" ? "checkmark.circle" : "circle")
                                        .font(.caption).foregroundStyle(statusStyle(entry.state))
                                }
                            }
                            .accessibilityIdentifier("mcp.server.\(scope.id).\(entry.name)")
                        }
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
                        addContext = McpAddContext(client: client, scopes: snapshot.scopes, serverName: server.name)
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
            McpAddServerView(client: context.client, scopes: context.scopes, serverName: context.serverName) {
                Task { await refresh() }
            }
        }
    }

    private func statusStyle(_ state: String) -> AnyShapeStyle {
        switch state {
        case "connected": AnyShapeStyle(.themeGreen)
        case "disabled": AnyShapeStyle(.secondary)
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
        ) { try await client.listMcpServers() }
    }
}
private struct McpAddContext: Identifiable {
    let id = UUID()
    let client: APIClient
    let scopes: [McpScopeSnapshot]
    let serverName: String
}
