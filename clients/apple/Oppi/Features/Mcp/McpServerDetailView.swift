import SwiftUI

struct McpServerDetailView: View {
    @State var scope: McpScopeSnapshot
    let client: APIClient
    let serverId: String
    let serverName: String
    @Environment(\.dismiss) private var dismiss
    @State var entry: McpServerSummary
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingRemove = false
    @State private var confirmingLogout = false
    let signIn: McpSignInOwner
    private var attempt: ProviderAuthFlowAttempt? {
        guard signIn.scopeId == scope.id, signIn.attempt?.serverId == serverId,
              signIn.attempt?.providerName == entry.name else { return nil }
        return signIn.attempt
    }

    /// `untrusted`: Pi's host MCP commands (status, sign-in, sign-out) skip this project file
    /// until a trust decision is remembered, even when sessions load it.
    private var needsRememberedTrust: Bool { entry.state == "untrusted" }

    private var trustNote: String? {
        if scope.projectTrust == .distrusted { return scope.projectTrust?.explanation }
        guard needsRememberedTrust else { return nil }
        return "Status and sign-in need a remembered trust for this folder. Choose Trust (remember) when a session here asks, or trust the project in Pi on the host."
    }

    init(scope: McpScopeSnapshot, entry: McpServerSummary, client: APIClient, serverId: String, serverName: String, signIn: McpSignInOwner) {
        self.scope = scope
        self.entry = entry
        self.client = client
        self.serverId = serverId
        self.serverName = serverName
        self.signIn = signIn
    }

    var body: some View {
        List {
            Section("\(scope.title) · \(serverName)") {
                LabeledContent("Status", value: entry.stateLabel)
                LabeledContent("Transport", value: entry.transport == "http" ? "URL" : "Command")
                if let url = entry.config.url { Text(url).textSelection(.enabled) }
                if let command = entry.config.command {
                    Text(([command] + (entry.config.args ?? [])).joined(separator: " "))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if let cwd = entry.config.cwd { LabeledContent("Working directory", value: cwd) }
                if let trustNote { Text(trustNote).foregroundStyle(.themeOrange) }
            }
            Section {
                Toggle("Enabled", isOn: Binding(get: { entry.enabled }, set: { value in
                    perform { try await client.patchMcpServer(scopeId: scope.id, name: entry.name, patch: McpPatchServerRequest(enabled: value)) }
                }))
                .disabled(busy || signIn.hasActive)
                .accessibilityIdentifier("mcp.enabled")
                Picker("Exposure", selection: Binding(get: { entry.exposure }, set: { value in
                    perform { try await client.patchMcpServer(scopeId: scope.id, name: entry.name, patch: McpPatchServerRequest(exposure: value)) }
                })) {
                    ForEach(McpExposure.allCases, id: \.self) { option in
                        VStack(alignment: .leading) {
                            Text(option.rawValue)
                            Text(option.explanation).font(.caption).foregroundStyle(.themeComment)
                        }.tag(option)
                    }
                }.pickerStyle(.navigationLink)
                .disabled(busy || signIn.hasActive)
                .accessibilityIdentifier("mcp.exposure")
            } footer: {
                Text("Saved in this scope's mcp.json. New sessions or /reload pick up configuration changes.")
            }
            if entry.supportsOAuth {
                Section("OAuth") {
                    if let attempt, !attempt.isSettled {
                        Button("Continue Sign-in") { signIn.resume() }
                    } else {
                        Button(entry.state == "needs-auth" ? "Sign In" : "Sign In Again") { startLogin() }
                            .disabled(busy || needsRememberedTrust || signIn.hasActive)
                            .accessibilityIdentifier("mcp.login")
                        Button("Sign Out", role: .destructive) { confirmingLogout = true }
                            .disabled(busy || needsRememberedTrust || signIn.hasActive)
                    }
                }
            }
            if let config = entry.config.headers, !config.isEmpty { referencesSection("Headers", values: config) }
            if let config = entry.config.env, !config.isEmpty { referencesSection("Environment", values: config) }
            if let failure = entry.error { Section("Connection Error") { Text(failure).foregroundStyle(.themeRed).textSelection(.enabled) } }
            ForEach(scope.errors, id: \.self) { Text($0).foregroundStyle(.themeRed) }
            Section("Tools (\(entry.tools.count))") {
                if entry.tools.isEmpty { Text("No tools available").foregroundStyle(.themeComment) }
                ForEach(entry.tools, id: \.self) { tool in
                    VStack(alignment: .leading) {
                        Text(tool).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        if let exposure = entry.toolExposure?[tool] {
                            Text(exposure.rawValue).font(.caption).foregroundStyle(.themeComment)
                        }
                    }
                }
            }
            if busy { Section { ProgressView("Updating…") } }
            if let error { Section { Text(error).foregroundStyle(.themeRed) } }
            Section {
                Button("Remove Server", role: .destructive) { confirmingRemove = true }
                    .disabled(busy || signIn.hasActive)
                    .accessibilityIdentifier("mcp.remove")
            }
        }
        .themedListSurface()
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .confirmationDialog("Remove \(entry.name) from \(scope.title)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Server", role: .destructive) {
                busy = true
                Task {
                    do { try await client.removeMcpServer(scopeId: scope.id, name: entry.name); dismiss() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        } message: { Text("The configuration entry will be removed. Stored OAuth credentials are not deleted; sign out first if needed.") }
        .confirmationDialog("Sign out of \(entry.name)?", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                perform { try await client.logoutMcpServer(scopeId: scope.id, name: entry.name) }
            }
        } message: { Text("This removes stored OAuth credentials on the host. You will need to sign in again to use this server.") }
        .onChange(of: attempt?.flow.status) { _, status in
            if status == .completed { Task { await refresh() } }
        }
    }

    private func referencesSection(_ title: String, values: [String: String]) -> some View {
        Section(title) {
            ForEach(values.keys.sorted(), id: \.self) { key in
                LabeledContent(key, value: values[key] ?? "[redacted]")
                    .font(.system(.subheadline, design: .monospaced))
            }
        }
    }
    private func refresh() async {
        guard attempt?.isSettled != false else { return }
        do {
            let currentScope = try await client.listMcpServers(scopeId: scope.id).scope
            scope = currentScope
            if let current = currentScope.servers.first(where: { $0.name == entry.name }) { entry = current }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await action(); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func startLogin() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let flow = try await client.startMcpAuthFlow(scopeId: scope.id, name: entry.name)
                let attempt = ProviderAuthFlowAttempt(
                    flow: flow.providerPresentation, client: McpFlowClient(client: client),
                    serverId: serverId, serverName: serverName, providerName: entry.name
                )
                signIn.adopt(attempt, scopeId: scope.id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
