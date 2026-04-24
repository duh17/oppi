import SwiftUI

/// Detail view for a paired oppi server.
///
/// Shows server metadata, stats, security info, and management actions.
/// Data is fetched on-demand from `GET /server/info`.
struct ServerDetailView: View {
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: ServerInfo?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showRemoveConfirmation = false

    @State private var providerStatuses: [ProviderAuthProviderStatus] = []
    @State private var isLoadingProviders = false
    @State private var providerError: String?
    @State private var providerActionInFlightId: String?
    @State private var isProviderManagerPresented = false

    @State private var activeFlow: ProviderAuthFlowSnapshot?
    @State private var isFlowSheetPresented = false
    @State private var flowInput = ""
    @State private var flowError: String?
    @State private var flowPollTask: Task<Void, Never>?
    @State private var isCancellingFlow = false

    @State private var apiKeyEditorProvider: ProviderAuthProviderStatus?
    @State private var apiKeyDraft = ""

    private var pairedServer: PairedServer {
        serverStore.server(for: server.id) ?? server
    }

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading server info…")
                        Spacer()
                    }
                }
            } else if let error {
                Section {
                    VStack(spacing: 8) {
                        Label("Unable to reach server", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.themeOrange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }
            }

            if let info {
                Section("Server") {
                    LabeledContent("Host", value: "\(pairedServer.host):\(pairedServer.port)")
                    LabeledContent("Uptime", value: info.uptimeLabel)
                    LabeledContent("Platform", value: info.platformLabel)
                }

                Section("Stats") {
                    LabeledContent("Workspaces", value: String(info.stats.workspaceCount))
                    LabeledContent("Active Sessions", value: String(info.stats.activeSessionCount))
                    LabeledContent("Skills", value: String(info.stats.skillCount))
                }

                Section("Runtime") {
                    LabeledContent("Agent", value: info.runtimeUpdate?.currentVersion ?? "n/a")
                    LabeledContent("Server", value: info.version)
                }
            }

            Section {
                if isLoadingProviders && providerStatuses.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading providers…")
                        Spacer()
                    }
                } else {
                    LabeledContent("Connected", value: String(connectedProviders.count))

                    if connectedProviders.isEmpty {
                        Text("No providers connected yet.")
                            .font(.footnote)
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(connectedProviders) { provider in
                            HStack(alignment: .top, spacing: 12) {
                                ProviderIcon(provider: provider.id, size: 16)
                                    .padding(.top, 3)

                                Text(provider.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(providerStatusText(provider))
                                    .font(.caption)
                                    .foregroundStyle(providerStatusColor(provider))
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }

                    Button {
                        isProviderManagerPresented = true
                    } label: {
                        HStack {
                            Label("Configure Providers", systemImage: "plus.circle")
                            Spacer()
                            Text("\(providerStatuses.count) available")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                    }
                    .disabled(providerActionInFlightId != nil)
                }
            } header: {
                Text("Model Providers")
            } footer: {
                if let providerError {
                    Text(providerError)
                        .foregroundStyle(.themeRed)
                } else {
                    Text("Connected providers are shown here. Use Configure Providers to add or manage all providers.")
                }
            }

            Section {
                HStack {
                    Text("Preview")
                    Spacer()
                    RuntimeBadge(
                        compact: false,
                        icon: pairedServer.resolvedBadgeIcon,
                        badgeColor: pairedServer.resolvedBadgeColor
                    )
                }

                BadgeIconGrid(selection: badgeIconSelection, tint: pairedServer.resolvedBadgeColor.themeColor)

                BadgeColorGrid(selection: badgeColorSelection)
            } header: {
                Text("Badge")
            }

            Section("Workspaces") {
                NavigationLink {
                    WorkspaceListView(server: pairedServer)
                } label: {
                    Label("Manage Workspaces", systemImage: "square.grid.2x2")
                }
            }

            Section("Connection") {
                LabeledContent("Paired", value: pairedServer.addedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove Paired Server", systemImage: "trash")
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("This only removes pairing from this iPhone. It does not delete the server or its data.")
            }
        }
        .themedListSurface()
        .navigationTitle(pairedServer.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
        }
        .task {
            await load()
        }
        .onDisappear {
            flowPollTask?.cancel()
            flowPollTask = nil
        }
        .confirmationDialog(
            removeDialogTitle,
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(removeDialogButtonTitle, role: .destructive) {
                removeServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeDialogMessage)
        }
        .sheet(isPresented: $isProviderManagerPresented) {
            providerManagerSheet
        }
        .sheet(isPresented: $isFlowSheetPresented, onDismiss: handleFlowSheetDismissed) {
            providerFlowSheet
        }
        .sheet(item: $apiKeyEditorProvider) { provider in
            apiKeyEditorSheet(provider: provider)
        }
    }

    private var badgeIconSelection: Binding<ServerBadgeIcon> {
        Binding(
            get: { pairedServer.resolvedBadgeIcon },
            set: { serverStore.setBadgeIcon(id: pairedServer.id, to: $0) }
        )
    }

    private var badgeColorSelection: Binding<ServerBadgeColor> {
        Binding(
            get: { pairedServer.resolvedBadgeColor },
            set: { serverStore.setBadgeColor(id: pairedServer.id, to: $0) }
        )
    }

    private var removingLastServer: Bool {
        serverStore.servers.count == 1 && serverStore.servers.first?.id == pairedServer.id
    }

    private var removeDialogTitle: String {
        if removingLastServer {
            return "Remove your only paired server?"
        }
        return "Remove \(pairedServer.name)?"
    }

    private var removeDialogButtonTitle: String {
        removingLastServer ? "Remove Last Server" : "Remove Server"
    }

    private var removeDialogMessage: String {
        if removingLastServer {
            return "This is the only paired server on this device. Removing it will disconnect Oppi and return you to onboarding. You'll need to pair again before using the app."
        }
        return "This removes the server from this iPhone only. It does not delete anything on the server, and you can pair it again later."
    }

    private var connectedProviders: [ProviderAuthProviderStatus] {
        providerStatuses
            .filter(\.authenticated)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableProviders: [ProviderAuthProviderStatus] {
        providerStatuses
            .filter { !$0.authenticated }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var providerManagerSheet: some View {
        NavigationStack {
            List {
                if isLoadingProviders && providerStatuses.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading providers…")
                            Spacer()
                        }
                    }
                } else {
                    Section("Connected") {
                        if connectedProviders.isEmpty {
                            Text("No connected providers")
                                .foregroundStyle(.themeComment)
                        } else {
                            ForEach(connectedProviders) { provider in
                                providerManagerRow(provider)
                            }
                        }
                    }

                    Section("Available") {
                        if availableProviders.isEmpty {
                            Text("All providers are currently connected")
                                .foregroundStyle(.themeComment)
                        } else {
                            ForEach(availableProviders) { provider in
                                providerManagerRow(provider)
                            }
                        }
                    }
                }

                if let providerError {
                    Section {
                        Text(providerError)
                            .foregroundStyle(.themeRed)
                    }
                }
            }
            .themedListSurface()
            .navigationTitle("Model Providers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isProviderManagerPresented = false
                    }
                }
            }
            .refreshable {
                await loadProviderStatus()
            }
            .task {
                await loadProviderStatus()
            }
        }
    }

    @ViewBuilder
    private func providerManagerRow(_ provider: ProviderAuthProviderStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderIcon(provider: provider.id, size: 16)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(providerStatusText(provider))
                    .font(.caption)
                    .foregroundStyle(providerStatusColor(provider))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if providerActionInFlightId == provider.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Menu {
                    if let oauth = provider.oauth {
                        Button(provider.authenticated ? "Reauthenticate" : "Sign In") {
                            isProviderManagerPresented = false
                            DispatchQueue.main.async {
                                startProviderFlow(provider: provider, oauth: oauth)
                            }
                        }
                    }

                    if provider.supportsApiKey {
                        Button(apiKeyButtonTitle(provider)) {
                            isProviderManagerPresented = false
                            DispatchQueue.main.async {
                                beginApiKeyEntry(for: provider)
                            }
                        }
                    }

                    if provider.authenticated {
                        Button("Disconnect", role: .destructive) {
                            disconnectProvider(provider)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.themeComment)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var providerFlowSheet: some View {
        NavigationStack {
            List {
                if let flow = activeFlow {
                    Section("Provider") {
                        LabeledContent("ID", value: flow.providerId)
                        LabeledContent("Status", value: flow.status.rawValue)
                    }

                    if let auth = flow.auth {
                        Section("Sign In") {
                            if let url = URL(string: auth.url) {
                                Link(destination: url) {
                                    Label("Open sign-in page on iPhone", systemImage: "safari")
                                }
                            } else {
                                Text(auth.url)
                                    .font(.footnote)
                            }

                            if let instructions = auth.instructions, !instructions.isEmpty {
                                Text(instructions)
                                    .font(.footnote)
                            }
                        }
                    }

                    if flow.status == .awaitingPrompt, let prompt = flow.prompt {
                        Section(prompt.message) {
                            TextField(prompt.placeholder ?? "Enter response", text: $flowInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(isCancellingFlow)

                            Button("Submit") {
                                submitPromptResponse()
                            }
                            .disabled(isCancellingFlow || (flowInput.isEmpty && prompt.allowEmpty != true))
                        }
                    }

                    if flow.status == .awaitingManualCode {
                        Section("Manual Code Input") {
                            TextField("Paste authorization code or redirect URL", text: $flowInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(isCancellingFlow)

                            Button("Submit") {
                                submitManualCode()
                            }
                            .disabled(
                                isCancellingFlow ||
                                    flowInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }

                    if let progress = flow.lastProgress, !progress.isEmpty {
                        Section("Progress") {
                            Text(progress)
                                .font(.footnote)
                        }
                    }

                    if let error = flow.error, !error.isEmpty {
                        Section {
                            Text(error)
                                .foregroundStyle(.themeRed)
                        } header: {
                            Text("Error")
                        }
                    }

                    if let flowError, !flowError.isEmpty {
                        Section {
                            Text(flowError)
                                .foregroundStyle(.themeRed)
                        }
                    }

                    Section {
                        if flow.status.isTerminal {
                            Button("Done") {
                                closeFlowSheet()
                            }
                        } else {
                            Button(role: .destructive) {
                                cancelActiveFlow(reason: "Cancelled by user")
                            } label: {
                                if isCancellingFlow {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Cancelling…")
                                    }
                                } else {
                                    Text("Cancel Login")
                                }
                            }
                            .disabled(isCancellingFlow)
                        }
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading flow…")
                            Spacer()
                        }
                    }
                }
            }
            .themedListSurface()
            .navigationTitle("Provider Sign In")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(isCancellingFlow)
    }

    @ViewBuilder
    private func apiKeyEditorSheet(provider: ProviderAuthProviderStatus) -> some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    HStack(spacing: 12) {
                        ProviderIcon(provider: provider.id, size: 16)
                        Text(provider.name)
                    }
                }

                Section("API Key") {
                    SecureField("Paste API key", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("The key is sent directly to your server over the existing Oppi connection and saved there.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
            }
            .navigationTitle("Set API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        apiKeyEditorProvider = nil
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAPIKey(provider: provider)
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func removeServer() {
        coordinator.removeServer(id: pairedServer.id)

        if serverStore.servers.isEmpty {
            navigation.showOnboarding = true
            return
        }

        dismiss()
    }

    private func load() async {
        guard let api = makeAPIClient() else {
            error = "Invalid server address"
            isLoading = false
            return
        }

        do {
            info = try await api.serverInfo()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }

        await loadProviderStatus(api: api)
        isLoading = false
    }

    private func makeAPIClient() -> APIClient? {
        guard let baseURL = pairedServer.baseURL else { return nil }
        return APIClient(
            baseURL: baseURL,
            token: pairedServer.token,
            tlsCertFingerprint: pairedServer.tlsCertFingerprint
        )
    }

    private func loadProviderStatus(api: APIClient? = nil) async {
        guard let client = api ?? makeAPIClient() else { return }

        isLoadingProviders = true
        defer { isLoadingProviders = false }

        do {
            providerStatuses = try await client.listProviderAuthStatus()
            providerError = nil
        } catch {
            providerError = "Failed to load provider status: \(error.localizedDescription)"
        }
    }

    private func providerStatusText(_ provider: ProviderAuthProviderStatus) -> String {
        guard provider.authenticated else { return "Not connected" }

        switch provider.credentialType {
        case .apiKey:
            if let masked = provider.maskedKey {
                return "API key · \(masked)"
            }
            return "API key connected"
        case .oauth:
            if let expiry = provider.expiresAtDate {
                return "OAuth · expires \(expiry.formatted(date: .abbreviated, time: .shortened))"
            }
            return "OAuth connected"
        case .none:
            return "Connected"
        }
    }

    private func providerStatusColor(_ provider: ProviderAuthProviderStatus) -> Color {
        provider.authenticated ? .themeGreen : .themeComment
    }

    private func apiKeyButtonTitle(_ provider: ProviderAuthProviderStatus) -> String {
        if provider.credentialType == .apiKey {
            return "Replace API Key"
        }
        return "Set API Key"
    }

    private func beginApiKeyEntry(for provider: ProviderAuthProviderStatus) {
        apiKeyDraft = ""
        apiKeyEditorProvider = provider
    }

    private func saveAPIKey(provider: ProviderAuthProviderStatus) {
        guard let api = makeAPIClient() else {
            providerError = "Invalid server address"
            return
        }

        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            providerError = "API key cannot be empty"
            return
        }

        providerActionInFlightId = provider.id
        Task {
            do {
                try await api.setProviderAPIKey(providerId: provider.id, key: key)
                providerError = nil
                apiKeyEditorProvider = nil
                apiKeyDraft = ""
                await loadProviderStatus(api: api)
            } catch {
                providerError = "Failed to save API key: \(error.localizedDescription)"
            }
            providerActionInFlightId = nil
        }
    }

    private func disconnectProvider(_ provider: ProviderAuthProviderStatus) {
        guard let api = makeAPIClient() else {
            providerError = "Invalid server address"
            return
        }

        providerActionInFlightId = provider.id
        Task {
            do {
                try await api.removeProviderCredential(providerId: provider.id)
                providerError = nil
                await loadProviderStatus(api: api)
            } catch {
                providerError = "Failed to remove credential: \(error.localizedDescription)"
            }
            providerActionInFlightId = nil
        }
    }

    private func startProviderFlow(
        provider: ProviderAuthProviderStatus,
        oauth: ProviderAuthOAuthCapabilities
    ) {
        guard let api = makeAPIClient() else {
            providerError = "Invalid server address"
            return
        }

        let launchMode: ProviderAuthFlowSnapshot.LaunchMode
        if oauth.flowType == .deviceCode, oauth.supportsPhoneBrowserLaunch {
            // Device-code flows are naturally cross-device. Prefer phone browser.
            launchMode = .phoneBrowser
        } else if oauth.supportsServerBrowserLaunch {
            // Callback-server providers work best when auth runs on server machine browser.
            launchMode = .serverBrowser
        } else if oauth.supportsPhoneBrowserLaunch {
            launchMode = .phoneBrowser
        } else {
            launchMode = .none
        }

        providerActionInFlightId = provider.id
        Task {
            do {
                let flow = try await api.startProviderAuthFlow(
                    providerId: provider.id,
                    launchMode: launchMode
                )
                activeFlow = flow
                flowInput = ""
                flowError = nil
                isCancellingFlow = false
                providerError = nil
                isFlowSheetPresented = true
                startFlowPolling(flowId: flow.flowId, api: api)
            } catch {
                providerError = "Failed to start login: \(error.localizedDescription)"
            }
            providerActionInFlightId = nil
        }
    }

    private func startFlowPolling(flowId: String, api: APIClient) {
        flowPollTask?.cancel()

        flowPollTask = Task {
            while !Task.isCancelled {
                do {
                    let flow = try await api.getProviderAuthFlow(flowId: flowId)
                    activeFlow = flow

                    if flow.status.isTerminal {
                        await loadProviderStatus(api: api)
                        break
                    }
                } catch {
                    flowError = "Failed to refresh flow: \(error.localizedDescription)"
                    break
                }

                try? await Task.sleep(for: .seconds(1.2))
            }

            flowPollTask = nil
        }
    }

    private func submitPromptResponse() {
        guard let flow = activeFlow, flow.status == .awaitingPrompt else { return }
        guard let api = makeAPIClient() else {
            flowError = "Invalid server address"
            return
        }

        let value = flowInput
        Task {
            do {
                activeFlow = try await api.submitProviderAuthPromptResponse(flowId: flow.flowId, value: value)
                flowInput = ""
                flowError = nil
            } catch {
                flowError = "Failed to submit response: \(error.localizedDescription)"
            }
        }
    }

    private func submitManualCode() {
        guard let flow = activeFlow, flow.status == .awaitingManualCode else { return }
        guard let api = makeAPIClient() else {
            flowError = "Invalid server address"
            return
        }

        let input = flowInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            flowError = "Code input cannot be empty"
            return
        }

        Task {
            do {
                activeFlow = try await api.submitProviderAuthManualCode(flowId: flow.flowId, input: input)
                flowInput = ""
                flowError = nil
            } catch {
                flowError = "Failed to submit code: \(error.localizedDescription)"
            }
        }
    }

    private func cancelActiveFlow(reason: String) {
        guard let flow = activeFlow else {
            closeFlowSheet()
            return
        }
        guard let api = makeAPIClient() else {
            flowError = "Failed to cancel login: Invalid server address"
            return
        }

        isCancellingFlow = true
        flowError = nil

        Task {
            do {
                _ = try await api.cancelProviderAuthFlow(flowId: flow.flowId, reason: reason)
                await MainActor.run {
                    closeFlowSheet()
                }
            } catch {
                await MainActor.run {
                    isCancellingFlow = false
                    flowError = "Failed to cancel login: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resetFlowState() {
        flowPollTask?.cancel()
        flowPollTask = nil
        activeFlow = nil
        flowInput = ""
        flowError = nil
        isCancellingFlow = false
    }

    private func closeFlowSheet() {
        resetFlowState()
        isFlowSheetPresented = false
    }

    private func handleFlowSheetDismissed() {
        flowPollTask?.cancel()
        flowPollTask = nil

        guard let flow = activeFlow else { return }

        guard !flow.status.isTerminal else {
            resetFlowState()
            return
        }

        guard let api = makeAPIClient() else {
            flowError = "Failed to cancel login: Invalid server address"
            isFlowSheetPresented = true
            return
        }

        isCancellingFlow = true
        flowError = nil

        Task {
            do {
                _ = try await api.cancelProviderAuthFlow(
                    flowId: flow.flowId,
                    reason: "Dismissed from iPhone"
                )
                await MainActor.run {
                    resetFlowState()
                }
            } catch {
                await MainActor.run {
                    isCancellingFlow = false
                    flowError = "Failed to cancel login: \(error.localizedDescription)"
                    isFlowSheetPresented = true
                    startFlowPolling(flowId: flow.flowId, api: api)
                }
            }
        }
    }
}
