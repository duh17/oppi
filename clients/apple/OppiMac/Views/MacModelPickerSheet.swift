import SwiftUI

struct MacModelPickerSheet: View {
    let models: [ModelInfo]
    let currentModel: String?
    let isLoading: Bool
    let error: String?
    let refresh: () async -> Void
    let selectModel: (ModelInfo) -> Void
    var setDefaultModel: ((ModelInfo) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredModels: [ModelInfo] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter { model in
            model.name.localizedCaseInsensitiveContains(trimmed)
                || model.id.localizedCaseInsensitiveContains(trimmed)
                || model.provider.localizedCaseInsensitiveContains(trimmed)
                || MacModelSelection.fullModelID(for: model).localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var providerGroups: [(provider: String, models: [ModelInfo])] {
        Dictionary(grouping: filteredModels, by: \.provider)
            .map { provider, models in
                (
                    provider: provider,
                    models: models.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted {
                $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose Model")
                .searchable(text: $searchText, prompt: "Search models")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Refresh Models", systemImage: "arrow.clockwise")
                        }
                        .disabled(isLoading)
                    }
                }
        }
        .frame(minWidth: 520, minHeight: 520)
        .task {
            // Match iOS: reload on every open so the current global default stays starred.
            await refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && models.isEmpty {
            ProgressView("Loading models...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if models.isEmpty {
            ContentUnavailableView(
                error == nil ? "No Models Available" : "Could Not Load Models",
                systemImage: "cpu",
                description: Text(error ?? "The local server did not return any model choices.")
            )
        } else if filteredModels.isEmpty {
            ContentUnavailableView(
                "No Matching Models",
                systemImage: "magnifyingglass",
                description: Text("Try a different provider, model name, or model ID.")
            )
        } else {
            List {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                ForEach(providerGroups, id: \.provider) { group in
                    Section(group.provider) {
                        ForEach(group.models) { model in
                            modelRow(model)
                        }
                    }
                }
            }
        }
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        let isCurrent = MacModelSelection.isCurrent(model: model, currentModel: currentModel)
        return HStack(spacing: 8) {
            Button {
                selectModel(model)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.name)
                                .fontWeight(isCurrent ? .semibold : .regular)
                            if isCurrent {
                                Text("Current")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(MacModelSelection.fullModelID(for: model))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if model.contextWindow > 0 {
                        Text(SessionFormatting.tokenCount(model.contextWindow))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let setDefaultModel {
                Button {
                    setDefaultModel(model)
                    dismiss()
                } label: {
                    Image(systemName: model.isDefault ? "star.fill" : "star")
                        .foregroundStyle(model.isDefault ? .orange : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isDefault ? "Default model" : "Set as default")
            }
        }
    }
}
