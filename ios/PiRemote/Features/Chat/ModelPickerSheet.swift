import SwiftUI

/// Model picker sheet with provider grouping and context window info.
///
/// Fetches available models from the REST API. Groups by provider (Anthropic,
/// OpenAI, Google, etc). Current model highlighted. Tap to switch.
struct ModelPickerSheet: View {
    let currentModel: String?
    let onSelect: (ModelInfo) -> Void

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var models: [ModelInfo] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var searchText = ""

    /// Group models by provider, sorted alphabetically.
    private var groupedModels: [(provider: String, models: [ModelInfo])] {
        let filtered: [ModelInfo]
        if searchText.isEmpty {
            filtered = models
        } else {
            filtered = models.filter { model in
                model.name.localizedCaseInsensitiveContains(searchText)
                    || model.id.localizedCaseInsensitiveContains(searchText)
                    || model.provider.localizedCaseInsensitiveContains(searchText)
            }
        }

        let grouped = Dictionary(grouping: filtered) { $0.provider }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (provider: $0.key, models: $0.value) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView(
                        "Failed to Load Models",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if models.isEmpty {
                    ContentUnavailableView(
                        "No Models Available",
                        systemImage: "cpu",
                        description: Text("Server returned no models.")
                    )
                } else {
                    modelList
                }
            }
            .background(Color.tokyoBg)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadModels() }
        }
    }

    private var modelList: some View {
        List {
            ForEach(groupedModels, id: \.provider) { group in
                Section {
                    ForEach(group.models) { model in
                        ModelRow(model: model, isCurrent: isCurrentModel(model))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                onSelect(model)
                                dismiss()
                            }
                            .listRowBackground(
                                isCurrentModel(model)
                                    ? Color.tokyoBlue.opacity(0.12)
                                    : Color.tokyoBg
                            )
                    }
                } header: {
                    Text(providerDisplayName(group.provider))
                        .font(.caption.bold())
                        .foregroundStyle(.tokyoFgDim)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func isCurrentModel(_ model: ModelInfo) -> Bool {
        guard let current = currentModel else { return false }
        let fullId = "\(model.provider)/\(model.id)"
        return current == fullId || current == model.id
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "anthropic": return "Anthropic"
        case "openai-codex": return "OpenAI Codex"
        case "openai": return "OpenAI"
        case "google": return "Google"
        case "lmstudio": return "LM Studio"
        default: return provider.capitalized
        }
    }

    private func loadModels() async {
        guard let api = connection.apiClient else {
            error = "Not connected to server"
            isLoading = false
            return
        }

        do {
            models = try await api.listModels()
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Model Row

private struct ModelRow: View {
    let model: ModelInfo
    let isCurrent: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline.weight(isCurrent ? .bold : .regular))
                        .foregroundStyle(isCurrent ? .tokyoBlue : .tokyoFg)

                    if isCurrent {
                        Text("current")
                            .font(.caption2.bold())
                            .foregroundStyle(.tokyoBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tokyoBlue.opacity(0.2), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(model.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoComment)

                    if model.contextWindow > 0 {
                        Label(formatTokenCount(model.contextWindow), systemImage: "text.rectangle")
                            .font(.caption2)
                            .foregroundStyle(.tokyoFgDim)
                    }
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tokyoBlue)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }
}
