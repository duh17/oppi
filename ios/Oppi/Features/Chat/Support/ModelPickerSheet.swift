import SwiftUI

/// Model picker sheet with provider grouping and context window info.
///
/// Uses `connection.cachedModels` for instant open, with background refresh.
/// Recently-used models appear in a dedicated section at the top.
struct ModelPickerSheet: View {
    let currentModel: String?
    let onSelect: (ModelInfo) -> Void

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var isRefreshing = false

    private var recentIds: [String] { RecentModels.load() }

    private var models: [ModelInfo] { connection.cachedModels }

    /// Full provider/id key for matching.
    private func fullId(_ model: ModelInfo) -> String {
        "\(model.provider)/\(model.id)"
    }

    /// Models the user picked recently, ordered by recency.
    private var recentModels: [ModelInfo] {
        let ids = recentIds
        let lookup = Dictionary(models.map { (fullId($0), $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { lookup[$0] }
    }

    /// All models grouped by provider, excluding any in the recent section.
    private var groupedModels: [(provider: String, models: [ModelInfo])] {
        let recentSet = Set(recentIds)
        let filtered: [ModelInfo]
        if searchText.isEmpty {
            filtered = models.filter { !recentSet.contains(fullId($0)) }
        } else {
            // When searching, search everything (including recents)
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
                if models.isEmpty && !connection.modelsCacheReady {
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
                RecentModels.record(fullId(model))
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

                Text("\(model.provider)/\(model.id)")
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
