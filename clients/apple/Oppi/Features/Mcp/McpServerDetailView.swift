import SwiftUI

struct McpServerDetailView: View {
    @State var scope: McpScopeSnapshot
    let client: APIClient
    let serverId: String
    let serverName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var entry: McpServerSummary
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingRemove = false
    @State private var attempt: ProviderAuthFlowAttempt?
    @State private var showingAuth = false

    init(scope: McpScopeSnapshot, entry: McpServerSummary, client: APIClient, serverId: String, serverName: String) {
        self.scope = scope
        self.entry = entry
        self.client = client
        self.serverId = serverId
        self.serverName = serverName
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
                if let note = scope.note { Text(note).foregroundStyle(.themeOrange) }
            }
            Section {
                Toggle("Enabled", isOn: Binding(get: { entry.enabled }, set: { value in
                    perform { try await client.patchMcpServer(scopeId: scope.id, name: entry.name, patch: McpPatchServerRequest(enabled: value)) }
                }))
                .disabled(busy || attempt?.isSettled == false)
                .accessibilityIdentifier("mcp.enabled")
                Picker("Exposure", selection: Binding(get: { entry.exposure }, set: { value in
                    perform { try await client.patchMcpServer(scopeId: scope.id, name: entry.name, patch: McpPatchServerRequest(exposure: value)) }
                })) {
                    ForEach(McpExposure.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(busy || attempt?.isSettled == false)
                .accessibilityIdentifier("mcp.exposure")
            } footer: {
                Text("Saved in this scope's mcp.json. New sessions or /reload pick up configuration changes.")
            }
            if entry.supportsOAuth {
                Section("OAuth") {
                    if let attempt, !attempt.isSettled {
                        Button("Continue Sign-in") { showingAuth = true; attempt.startPolling() }
                    } else {
                        Button(entry.state == "needs-auth" ? "Sign In" : "Sign In Again") { startLogin() }
                            .disabled(busy || !scope.trusted)
                            .accessibilityIdentifier("mcp.login")
                        Button("Sign Out", role: .destructive) {
                            perform { try await client.logoutMcpServer(scopeId: scope.id, name: entry.name) }
                        }.disabled(busy || !scope.trusted)
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
                    .disabled(busy || attempt?.isSettled == false)
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
        .sheet(isPresented: $showingAuth, onDismiss: {
            if let attempt, !attempt.sheetDismissed() { self.attempt = nil }
        }) {
            if let attempt { McpSignInSheet(attempt: attempt) { showingAuth = false } }
        }
        .onChange(of: attempt?.flow.status) { _, status in
            if status == .completed { Task { await refresh() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { attempt?.startPolling() } else { attempt?.stopPolling() }
        }
        .onDisappear { attempt?.stopPolling() }
        .onAppear { attempt?.startPolling() }
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
            let snapshot = try await client.listMcpServers()
            if let currentScope = snapshot.scopes.first(where: { $0.id == scope.id }) {
                scope = currentScope
                if let current = currentScope.servers.first(where: { $0.name == entry.name }) { entry = current }
            }
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
                self.attempt = attempt; showingAuth = true; attempt.startPolling()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Reuse the provider flow's host-bound poll/retry/cancel owner. MCP's external-wait
/// state also accepts a pasted callback, so present it as manual input to that owner.
private extension McpAuthFlowSnapshot {
    var providerPresentation: ProviderAuthFlowSnapshot {
        ProviderAuthFlowSnapshot(
            flowId: flowId, providerId: serverName, flowType: .oauthCallback,
            launchMode: launchMode, status: status == .awaitingExternal ? .awaitingManualCode : status,
            auth: auth, prompt: nil, lastProgress: nil, error: error,
            createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt
        )
    }
}
private struct McpFlowClient: ProviderAuthFlowClient {
    let client: APIClient
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        try await client.getMcpAuthFlow(flowId: flowId).providerPresentation
    }
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot {
        try await client.submitMcpCallback(flowId: flowId, input: input).providerPresentation
    }
    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot {
        try await client.cancelMcpAuthFlow(flowId: flowId).providerPresentation
    }
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot {
        throw APIError.server(status: 400, message: "MCP sign-in accepts a callback URL, not a prompt response")
    }
}
private struct McpSignInSheet: View {
    @Bindable var attempt: ProviderAuthFlowAttempt
    let close: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section(attempt.providerName) {
                    LabeledContent("Host", value: attempt.serverName)
                    LabeledContent("Status", value: ProviderAuthFlowPresentation.statusText(attempt.flow.status))
                }
                if !attempt.isSettled, let auth = attempt.flow.auth {
                    Section("Sign In") {
                        if let url = ProviderAuthFlowPresentation.signInURL(auth.url) {
                            Link("Open Sign-in Page in Safari", destination: url)
                                .accessibilityIdentifier("mcp.auth.open")
                        }
                        Text("After approval, Safari may fail to load 127.0.0.1. Copy its full callback URL and paste it below. You can also complete sign-in using a browser on the host.")
                            .font(.footnote).foregroundStyle(.themeComment)
                        TextField("Paste full callback URL", text: $attempt.input, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("mcp.auth.callback")
                        Button("Submit Callback") { Task { await attempt.submitManualCode() } }
                            .disabled(attempt.isSubmitting || attempt.isCancelling || attempt.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("mcp.auth.submit")
                    }
                } else if !attempt.isSettled { ProgressView("Preparing sign-in…") }
                if let error = attempt.flow.error { Text(error).foregroundStyle(.themeRed) }
                if let error = attempt.actionError { Text(error).foregroundStyle(.themeRed) }
                if let error = attempt.refreshError { Text(error).foregroundStyle(.themeOrange) }
                if attempt.isGone { Text("The host no longer has this flow. Start a new sign-in.") }
                Section {
                    if attempt.isSettled { Button("Done", action: close) }
                    else {
                        Button("Cancel Sign-in", role: .destructive) {
                            Task { if await attempt.cancel(reason: "Cancelled from MCP Servers") { close() } }
                        }.disabled(attempt.isCancelling)
                    }
                }
            }
            .themedListSurface()
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close) } }
        }
        .interactiveDismissDisabled(attempt.isCancelling)
    }
}
