import SwiftUI

/// Detail view for a paired oppi server.
///
/// Shows server metadata, stats, security info, and management actions.
/// Data is fetched on-demand from `GET /server/info`.
enum ServerDetailPresentation {
    case details
    case modelProviders
}

struct ServerDetailView: View {
    let server: PairedServer
    var presentation: ServerDetailPresentation = .details

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss

    @State private var info: ServerInfo?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showRemoveConfirmation = false

    @State private var providerStatuses: [ProviderAuthProviderStatus] = []
    @State private var providerSetupState: ProviderSetupState = .unknown
    @State private var providerQuotas: ProviderQuotasInfo?
    @State private var isLoadingProviders = false
    @State private var providerError: String?
    @State private var providerActionInFlightId: String?

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
            if presentation == .modelProviders {
                providerManagementSections
            } else {
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

                    workspaceManagementSection

                    Section("Runtime") {
                        LabeledContent("Agent", value: info.agentVersionLabel)
                        LabeledContent("Server", value: info.version)
                    }
                }

                Section("Configuration") {
                    Button {
                        navigation.openModelProviders(ModelProvidersNavTarget(serverId: pairedServer.id))
                    } label: {
                        HStack {
                            Label("Model Providers", systemImage: "cpu")
                            Spacer()
                            Text(providerConfigurationSummary)
                                .font(.caption)
                                .foregroundStyle(providerConfigurationSummaryStyle)
                        }
                    }
                    .accessibilityIdentifier("server.modelProviders.open")
                }

                Section {
                    HStack {
                        Text("Preview")
                        Spacer()
                        RuntimeBadge(
                            compact: false,
                            icon: pairedServer.resolvedBadgeIcon,
                            tint: badgePreviewConnectionState.tintColor
                        )
                    }

                    BadgeIconGrid(selection: badgeIconSelection, tint: .themeBlue)
                } header: {
                    Text("Badge")
                } footer: {
                    Text("Badge color reflects connection status: green connected, blue connecting, red disconnected.")
                }

                Section {
                    LabeledContent("Transport", value: "HTTPS/WSS")
                    LabeledContent("Paired", value: pairedServer.addedAt.formatted(date: .abbreviated, time: .shortened))
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Uses HTTPS/WSS, normally through Tailscale or a directly reachable TLS endpoint.")
                }

                Section {
                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Label("Remove Server", systemImage: "trash")
                    }
                } header: {
                    Text("Remove Server")
                } footer: {
                    Text("This only removes pairing from this iPhone. It does not delete the server or its data.")
                }
            }
        }
        .iPadReadableContent(maxWidth: IPadReadableContentWidth.detail)
        .themedListSurface()
        .accessibilityIdentifier(
            presentation == .modelProviders ? "server.modelProviders.list" : "server.details.list"
        )
        .navigationTitle(presentation == .modelProviders ? "Model Providers" : pairedServer.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if presentation == .modelProviders {
                await loadProviderConfiguration()
            } else {
                await load()
            }
        }
        .task {
            if presentation == .modelProviders {
                await loadProviderConfiguration()
            } else {
                await load()
            }
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
        .sheet(isPresented: $isFlowSheetPresented, onDismiss: handleFlowSheetDismissed) {
            providerFlowSheet
        }
        .sheet(item: $apiKeyEditorProvider) { provider in
            apiKeyEditorSheet(provider: provider)
        }
    }

    @ViewBuilder
    private var providerManagementSections: some View {
        if providerPresentation.showsLoading {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Loading providers…")
                    Spacer()
                }
            }
        } else if providerPresentation.showsProviderSections {
            Section("Connected") {
                if connectedProviders.isEmpty {
                    providerOnboardingCard
                } else {
                    ForEach(connectedProviders) { provider in
                        providerManagerRow(provider, quota: providerQuota(for: provider))
                    }
                }
            }

            Section("Available") {
                if availableProviders.isEmpty {
                    Text("All providers are currently connected")
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(availableProviders) { provider in
                        providerManagerRow(provider, quota: nil)
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

    private var providerPresentation: ProviderConfigurationPresentation {
        ProviderConfigurationPresentation(state: providerSetupState)
    }

    private var providerConfigurationSummary: String {
        providerPresentation.summary(connectedCount: connectedProviders.count)
    }

    private var providerConfigurationSummaryStyle: ThemeShapeStyle {
        providerSetupState == .needsConfiguration ? .themeOrange : .themeComment
    }

    private func providerQuota(for provider: ProviderAuthProviderStatus) -> ProviderQuota? {
        guard let quota = providerQuotas?.quota(forProviderId: provider.id),
              quota.hasAnyUsageWindow || quota.error != nil || quota.planLabel != nil
        else { return nil }
        return quota
    }

    private var workspaceManagementSection: some View {
        Section("Workspaces") {
            NavigationLink {
                WorkspaceListView(server: pairedServer)
            } label: {
                Label("Manage Workspaces", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("server.manageWorkspaces")
        }
    }

    private var badgeIconSelection: Binding<ServerBadgeIcon> {
        Binding(
            get: { pairedServer.resolvedBadgeIcon },
            set: { serverStore.setBadgeIcon(id: pairedServer.id, to: $0) }
        )
    }

    private var badgePreviewConnectionState: ServerBadgeConnectionState {
        if info != nil || !providerStatuses.isEmpty || providerQuotas != nil {
            return .connected
        }
        if isLoading || isLoadingProviders {
            return .connecting
        }
        return .disconnected
    }

    private var removingLastServer: Bool {
        serverStore.servers.count == 1 && serverStore.servers.first?.id == pairedServer.id
    }

    private var removeDialogTitle: String {
        if removingLastServer {
            return "Remove only paired server?"
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
    private var providerOnboardingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect a model provider", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text("Finish setup by signing in or adding an API key. This unlocks model selection for sessions on this server.")
                .font(.footnote)
                .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerManagerRow(
        _ provider: ProviderAuthProviderStatus,
        quota: ProviderQuota?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                } else if provider.authenticated {
                    providerManageMenu(provider)
                } else {
                    providerConnectButtons(provider)
                }
            }

            if let quota {
                ProviderQuotaDetails(quota: quota, providerName: provider.name)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerConnectButtons(
        _ provider: ProviderAuthProviderStatus
    ) -> some View {
        if let oauth = provider.oauth, provider.supportsApiKey {
            Menu {
                Button(provider.authenticated ? "Reauthenticate" : "Sign In") {
                    startProviderOAuthAction(provider: provider, oauth: oauth)
                }

                Button(apiKeyButtonTitle(provider)) {
                    startProviderAPIKeyAction(provider: provider)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Connect")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline)
            .disabled(providerActionInFlightId != nil)
        } else if let oauth = provider.oauth {
            Button(provider.authenticated ? "Reauthenticate" : "Sign In") {
                startProviderOAuthAction(provider: provider, oauth: oauth)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline)
            .disabled(providerActionInFlightId != nil)
        } else if provider.supportsApiKey {
            Button(apiKeyButtonTitle(provider)) {
                startProviderAPIKeyAction(provider: provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline)
            .disabled(providerActionInFlightId != nil)
        }
    }

    private func startProviderOAuthAction(
        provider: ProviderAuthProviderStatus,
        oauth: ProviderAuthOAuthCapabilities
    ) {
        DispatchQueue.main.async {
            startProviderFlow(provider: provider, oauth: oauth)
        }
    }

    private func startProviderAPIKeyAction(
        provider: ProviderAuthProviderStatus
    ) {
        DispatchQueue.main.async {
            beginApiKeyEntry(for: provider)
        }
    }

    @ViewBuilder
    private func providerManageMenu(_ provider: ProviderAuthProviderStatus) -> some View {
        Menu {
            if let oauth = provider.oauth {
                Button("Reauthenticate") {
                    DispatchQueue.main.async {
                        startProviderFlow(provider: provider, oauth: oauth)
                    }
                }
            }

            if provider.supportsApiKey {
                Button(apiKeyButtonTitle(provider)) {
                    DispatchQueue.main.async {
                        beginApiKeyEntry(for: provider)
                    }
                }
            }

            Button("Disconnect", role: .destructive) {
                disconnectProvider(provider)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.themeComment)
        }
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
                            if let options = prompt.options, !options.isEmpty {
                                ForEach(options) { option in
                                    Button(option.label) {
                                        flowInput = option.id
                                        submitPromptResponse()
                                    }
                                    .disabled(isCancellingFlow)
                                }
                            } else {
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
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
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
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
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
        Task { @MainActor in
            await coordinator.removeServer(id: pairedServer.id)

            if serverStore.servers.isEmpty {
                navigation.showOnboarding = true
                return
            }

            dismiss()
        }
    }

    private func load() async {
        guard let api = await prepareAPIClient() else {
            error = "Unable to prepare server transport"
            isLoading = false
            return
        }

        do {
            info = try await api.serverInfo()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }

        await loadProviderConfiguration(api: api)
        isLoading = false
    }

    private func prepareAPIClient() async -> APIClient? {
        await coordinator.apiClientReady(for: pairedServer.id)
    }

    private func makeAPIClient() -> APIClient? {
        coordinator.apiClient(for: pairedServer.id)
    }

    private func loadProviderConfiguration(api: APIClient? = nil) async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }

        let client: APIClient
        if let api {
            client = api
        } else if let prepared = await prepareAPIClient() {
            client = prepared
        } else {
            providerSetupState = .unavailable
            providerError = "Unable to prepare server transport"
            return
        }

        async let quotas = loadProviderQuotas(api: client)

        do {
            providerStatuses = try await client.listProviderAuthStatus()
            providerSetupState = ProviderSetupState(providerStatuses: providerStatuses)
            providerError = nil
        } catch {
            providerStatuses = []
            providerSetupState = .unavailable
            providerError = "Failed to load provider status: \(error.localizedDescription)"
        }

        providerQuotas = await quotas
    }

    private func loadProviderQuotas(api: APIClient) async -> ProviderQuotasInfo? {
        do {
            return try await api.fetchProviderQuotas()
        } catch {
            return nil
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
                await loadProviderConfiguration(api: api)
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
                await loadProviderConfiguration(api: api)
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

        let launchMode: ProviderAuthFlowSnapshot.LaunchMode = if oauth.flowType == .deviceCode, oauth.supportsPhoneBrowserLaunch {
            // Device-code flows are naturally cross-device. Prefer phone browser.
            .phoneBrowser
        } else if oauth.supportsServerBrowserLaunch {
            // Callback-server providers work best when auth runs on server machine browser.
            .serverBrowser
        } else if oauth.supportsPhoneBrowserLaunch {
            .phoneBrowser
        } else {
            .none
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
                        await loadProviderConfiguration(api: api)
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

fileprivate struct ProviderQuotaDetails: View {
    let quota: ProviderQuota
    let providerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = quota.planLabel {
                Text(plan)
                    .font(.caption.bold())
                    .foregroundStyle(.themeBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.themeBlue.opacity(0.14), in: Capsule())
                    .accessibilityLabel("\(providerName) plan \(plan)")
                    .accessibilityIdentifier("provider.quota.\(quota.providerId).plan")
            }

            ForEach(quota.detailWindows) { window in
                usageRow(window: window)
            }

            if let error = quota.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(providerName) quota error: \(error)")
            }
        }
    }

    @ViewBuilder
    private func usageRow(window: ProviderQuota.Window) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(remainingStyle(window.remainingPercent))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.themeComment.opacity(0.18))
                        .frame(height: 6)

                    Capsule()
                        .fill(remainingStyle(window.remainingPercent))
                        .frame(
                            width: geo.size.width * max(0, min(1, window.remainingPercent / 100)),
                            height: 6
                        )
                }
            }
            .frame(height: 6)

            if let resetDate = window.resetDate {
                Text(resetLabel(for: resetDate, window: window))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.themeComment)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(providerName) \(window.title) quota")
        .accessibilityValue(accessibilityValue(for: window))
        .accessibilityIdentifier("provider.quota.\(quota.providerId).\(window.key)")
    }

    private func accessibilityValue(for window: ProviderQuota.Window) -> String {
        let remaining = "\(Int(window.remainingPercent.rounded()))% left"
        guard let resetDate = window.resetDate else { return remaining }
        return "\(remaining), \(resetLabel(for: resetDate, window: window))"
    }

    private func remainingStyle(_ remainingPercent: Double) -> ThemeShapeStyle {
        switch ProviderQuota.badgeTone(for: remainingPercent) {
        case .green:
            .themeGreen
        case .orange:
            .themeOrange
        case .red:
            .themeRed
        }
    }

    private func resetLabel(for date: Date, window: ProviderQuota.Window) -> String {
        let secondsUntilReset = date.timeIntervalSinceNow
        let formatted: String = if secondsUntilReset <= 36 * 60 * 60, !window.includeWeekdayInReset {
            // Short windows (e.g. Codex 5h): time-of-day is enough.
            date.formatted(.dateTime.hour().minute())
        } else if secondsUntilReset <= 8 * 24 * 60 * 60 {
            // Within about a week: weekday + time.
            date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        } else {
            // Farther out (monthly): calendar day + time.
            date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return "resets \(formatted)"
    }
}

#if DEBUG
struct ModelProvidersQuotaPreview: View {
    private static let sampleNow = Date()

    private static let codexQuota = ProviderQuota(
        providerId: "openai-codex",
        displayName: "Codex",
        authenticated: true,
        planType: "prolite",
        windows: [
            ProviderQuota.Window(
                key: "five_hour",
                shortLabel: "5h",
                title: "5-hour",
                usedPercent: 28,
                remainingPercent: 72,
                limitWindowSeconds: 18_000,
                resetAt: Int(sampleNow.addingTimeInterval(2 * 60 * 60).timeIntervalSince1970),
                includeWeekdayInReset: false
            ),
            ProviderQuota.Window(
                key: "weekly",
                shortLabel: "7d",
                title: "Weekly",
                usedPercent: 44,
                remainingPercent: 56,
                limitWindowSeconds: 604_800,
                resetAt: Int(sampleNow.addingTimeInterval(5 * 24 * 60 * 60).timeIntervalSince1970),
                includeWeekdayInReset: true
            ),
        ],
        credits: nil,
        prepaidBalanceCents: nil,
        fetchedAt: Int(sampleNow.timeIntervalSince1970),
        error: nil
    )

    private static let xaiQuota = ProviderQuota(
        providerId: "xai",
        displayName: "xAI",
        authenticated: true,
        planType: "supergrok",
        windows: [
            ProviderQuota.Window(
                key: "monthly",
                shortLabel: "30d",
                title: "Monthly",
                usedPercent: 61,
                remainingPercent: 39,
                limitWindowSeconds: 2_592_000,
                resetAt: Int(sampleNow.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970),
                includeWeekdayInReset: false
            ),
        ],
        credits: nil,
        prepaidBalanceCents: nil,
        fetchedAt: Int(sampleNow.timeIntervalSince1970),
        error: nil
    )

    var body: some View {
        NavigationStack {
            List {
                Section("Connected") {
                    connectedProviderRow(
                        providerID: "openai-codex",
                        name: "OpenAI Codex",
                        status: "OAuth connected",
                        quota: Self.codexQuota
                    )
                    connectedProviderRow(
                        providerID: "xai",
                        name: "xAI",
                        status: "OAuth connected",
                        quota: Self.xaiQuota
                    )
                    connectedProviderRow(
                        providerID: "deepseek",
                        name: "DeepSeek",
                        status: "API key connected"
                    )
                }

                Section("Available") {
                    HStack(alignment: .top, spacing: 12) {
                        ProviderIcon(provider: "anthropic", size: 16)
                            .padding(.top, 3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anthropic")
                            Text("Not connected")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Connect")
                            .font(.subheadline)
                            .foregroundStyle(.themeBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.themeBlue.opacity(0.14), in: Capsule())
                    }
                }
            }
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.detail)
            .themedListSurface()
            .navigationTitle("Model Providers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.light)
        .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private func connectedProviderRow(
        providerID: String,
        name: String,
        status: String,
        quota: ProviderQuota? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIcon(provider: providerID, size: 16)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.themeGreen)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.themeComment)
            }

            if let quota {
                ProviderQuotaDetails(quota: quota, providerName: name)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
