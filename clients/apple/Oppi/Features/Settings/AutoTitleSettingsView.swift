import SwiftUI

/// Settings view for configuring automatic session title generation.
///
/// Three provider modes:
/// - **Server**: server generates titles using a selected model
/// - **On-device**: local Foundation model generates titles
/// - **Off**: no automatic titles
struct AutoTitleSettingsView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var provider = AppPreferences.Session.autoTitleProvider
    @State private var selectedModel: String = ""
    @State private var models: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var isLoadingConfig = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Picker("Provider", selection: $provider) {
                    Text("Server Model").tag(AppPreferences.Session.AutoTitleProvider.server)
                    Text("On-device").tag(AppPreferences.Session.AutoTitleProvider.onDevice)
                    Text("Off").tag(AppPreferences.Session.AutoTitleProvider.off)
                }
                .pickerStyle(.menu)

                if provider == .server {
                    if isLoadingModels || isLoadingConfig {
                        HStack {
                            Text("Model")
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else if !models.isEmpty {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(groupedModels) { group in
                                Section(group.provider) {
                                    ForEach(group.models) { model in
                                        Text(model.name).tag(model.fullId)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Title Generation")
            } footer: {
                Text(footerText)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.themeRed)
                }
            }
        }
        .themedListSurface()
        .navigationTitle("Auto-name Sessions")
        .onChange(of: provider) { _, newValue in
            AppPreferences.Session.setAutoTitleProvider(newValue)
            syncServerConfig()
        }
        .onChange(of: selectedModel) { oldValue, newValue in
            guard !newValue.isEmpty, oldValue != newValue else { return }
            syncServerConfig()
        }
        .task {
            await loadInitialState()
        }
    }

    // MARK: - Grouped Models

    /// Providers whose APIs don't support standard chat completions
    /// (system + user messages). These models return empty responses
    /// when called via completeSimple.
    private static let incompatibleProviders: Set<String> = ["openai-codex"]

    private var groupedModels: [ModelGroup] {
        let compatible = models.filter { !Self.incompatibleProviders.contains($0.provider) }
        let byProvider = Dictionary(grouping: compatible, by: \.provider)
        return byProvider
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { provider, items in
                ModelGroup(
                    provider: provider,
                    models: items.map { info in
                        let fullId = info.id.hasPrefix("\(info.provider)/")
                            ? info.id
                            : "\(info.provider)/\(info.id)"
                        return ModelGroup.Entry(
                            id: info.id,
                            fullId: fullId,
                            name: info.name
                        )
                    }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                )
            }
    }

    private var footerText: String {
        switch provider {
        case .server:
            return "The server generates a short title when a session starts. Uses the selected model."
        case .onDevice:
            return "Uses Apple's on-device language model. No network required, but quality may vary."
        case .off:
            return "Sessions will show the first message as their title."
        }
    }

    // MARK: - Data Loading

    private func loadInitialState() async {
        guard let api = apiClient else { return }

        isLoadingConfig = true
        isLoadingModels = true
        errorMessage = nil

        // Fetch server config + models concurrently
        async let configTask: Void = loadServerConfig(api: api)
        async let modelsTask: Void = loadModels(api: api)
        _ = await (configTask, modelsTask)
    }

    private func loadServerConfig(api: APIClient) async {
        defer { isLoadingConfig = false }
        do {
            let config = try await api.getAutoTitleConfig()
            if let model = config.model, !model.isEmpty {
                selectedModel = model
            }
        } catch {
            // Non-fatal: we still show the picker, just no pre-selection
        }
    }

    private func loadModels(api: APIClient) async {
        defer { isLoadingModels = false }
        do {
            models = try await api.listModels()
            // If no model is selected yet, pick the first one
            if selectedModel.isEmpty, let first = models.first {
                selectedModel = first.id.hasPrefix("\(first.provider)/")
                    ? first.id
                    : "\(first.provider)/\(first.id)"
            }
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
        }
    }

    // MARK: - Server Sync

    private func syncServerConfig() {
        guard let api = apiClient else { return }

        let config: APIClient.AutoTitleConfig
        switch provider {
        case .server:
            config = APIClient.AutoTitleConfig(
                enabled: true,
                model: selectedModel.isEmpty ? nil : selectedModel
            )
        case .onDevice, .off:
            config = APIClient.AutoTitleConfig(enabled: false, model: nil)
        }

        Task {
            do {
                try await api.setAutoTitleConfig(config)
            } catch {
                errorMessage = "Failed to save config: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Model Grouping

private struct ModelGroup: Identifiable {
    let provider: String
    let models: [Entry]

    var id: String { provider }

    struct Entry: Identifiable {
        let id: String
        let fullId: String
        let name: String
    }
}
