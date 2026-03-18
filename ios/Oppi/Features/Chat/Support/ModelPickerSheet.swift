import SwiftUI

/// Model picker sheet with provider grouping and context window info.
///
/// Uses `chatState.cachedModels` for instant open, with background refresh.
/// Recently-used models appear in a dedicated section at the top.
struct ModelPickerSheet: View {
    let currentModel: String?
    let onSelect: (ModelInfo) -> Void

    @Environment(ServerConnection.self) private var connection
    @Environment(ChatSessionState.self) private var chatState
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    private var recentIds: [String] { RecentModels.load() }

    private var models: [ModelInfo] { chatState.cachedModels }

    /// Full provider/id key for matching (delegates to policy to avoid double-prefix).
    private func fullId(_ model: ModelInfo) -> String {
        ModelSwitchPolicy.fullModelID(for: model)
    }

    /// Models the user picked recently, ordered by recency.
    private var recentModels: [ModelInfo] {
        let ids = recentIds
        let lookup = Dictionary(models.map { (fullId($0), $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { lookup[$0] }
    }

    /// All models grouped by provider, excluding any in the recent section.
    /// When searching, uses FuzzyMatch across name/id/provider and sorts by score.
    private var groupedModels: [(provider: String, models: [ModelInfo])] {
        let recentSet = Set(recentIds)
        let filtered: [ModelInfo]
        if searchText.isEmpty {
            filtered = models.filter { !recentSet.contains(fullId($0)) }
        } else {
            // Fuzzy search across name, id, and provider — take best score
            let query = searchText
            var scored: [(model: ModelInfo, score: Int)] = []
            for model in models {
                let candidates = [model.name, model.id, model.provider]
                let bestScore = candidates.compactMap { FuzzyMatch.match(query: query, candidate: $0)?.score }.max()
                if let score = bestScore {
                    scored.append((model, score))
                }
            }
            scored.sort { $0.score > $1.score }
            filtered = scored.map(\.model)
        }

        let grouped = Dictionary(grouping: filtered) { $0.provider }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (provider: $0.key, models: $0.value) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if models.isEmpty && !chatState.modelsCacheReady {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .background(Color.themeBg)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                // Background refresh — UI already shows cached data
                await connection.refreshModelCache()
            }
        }
    }

    private var modelList: some View {
        List {
            // Recent section (only when not searching)
            if searchText.isEmpty, !recentModels.isEmpty {
                Section {
                    ForEach(recentModels) { model in
                        modelRow(model)
                    }
                } header: {
                    Text("Recent")
                        .font(.caption.bold())
                        .foregroundStyle(.themeFgDim)
                }
            }

            ForEach(groupedModels, id: \.provider) { group in
                Section {
                    ForEach(group.models) { model in
                        modelRow(model)
                    }
                } header: {
                    Text(providerDisplayName(group.provider))
                        .font(.caption.bold())
                        .foregroundStyle(.themeFgDim)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        let isCurrent = isCurrentModel(model)
        ModelRow(model: model, isCurrent: isCurrent)
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelect(model)
                dismiss()
            }
            .listRowBackground(
                isCurrent ? Color.themeBlue.opacity(0.12) : Color.themeBg
            )
    }

    private func isCurrentModel(_ model: ModelInfo) -> Bool {
        guard let current = currentModel else { return false }
        let fid = fullId(model)
        return current == fid || current == model.id
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
}

// MARK: - Model Row

private struct ModelRow: View {
    let model: ModelInfo
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Left: name + provider/id
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline.weight(isCurrent ? .bold : .regular))
                        .foregroundStyle(isCurrent ? .themeBlue : .themeFg)
                        .lineLimit(1)

                    if isCurrent {
                        Text("current")
                            .font(.caption2.bold())
                            .foregroundStyle(.themeBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.themeBlue.opacity(0.2), in: Capsule())
                    }
                }

                Text(ModelSwitchPolicy.fullModelID(for: model))
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Right: context window + checkmark, fixed trailing column
            HStack(spacing: 8) {
                if model.contextWindow > 0 {
                    Text(formatTokenCount(model.contextWindow))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.themeFgDim)
                }

                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.themeBlue)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
