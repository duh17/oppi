import SwiftUI

struct NewSessionView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var model = "anthropic/claude-opus-4-6"
    @State private var isCreating = false
    @State private var error: String?
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = true

    /// Group models by provider for sectioned display.
    private var groupedModels: [(provider: String, models: [ModelInfo])] {
        let grouped = Dictionary(grouping: availableModels) { $0.provider }
        let order = ["anthropic", "openai", "google", "lmstudio"]
        return order.compactMap { provider in
            guard let models = grouped[provider], !models.isEmpty else { return nil }
            return (provider: provider, models: models)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session name (optional)", text: $name)
                }

                Section("Model") {
                    TextField("Model identifier", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if isLoadingModels {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading models…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(groupedModels, id: \.provider) { group in
                        Section(providerDisplayName(group.provider)) {
                            ForEach(group.models) { info in
                                Button {
                                    model = info.id
                                } label: {
                                    HStack {
                                        Text(info.name)
                                        Spacer()
                                        if model == info.id {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createSession() }
                    }
                    .disabled(isCreating)
                }
            }
            .task { await loadModels() }
        }
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "google": return "Google"
        case "lmstudio": return "LM Studio"
        default: return provider.capitalized
        }
    }

    private func loadModels() async {
        guard let api = connection.apiClient else {
            isLoadingModels = false
            return
        }

        do {
            availableModels = try await api.listModels()
        } catch {
            // Silently fall back — user can still type model ID manually
        }

        isLoadingModels = false
    }

    private func createSession() async {
        guard let api = connection.apiClient else { return }
        isCreating = true
        error = nil

        do {
            let session = try await api.createSession(
                name: name.isEmpty ? nil : name,
                model: model.isEmpty ? nil : model
            )
            sessionStore.upsert(session)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isCreating = false
        }
    }
}
