import Foundation

/// Filters and normalizes the models offered for server auto-titles.
enum AutoTitleModelCatalog {
    /// Providers whose APIs don't support standard chat completions
    /// (system + user messages). These models return empty responses
    /// when called via completeSimple.
    static let incompatibleProviders: Set<String> = ["openai-codex"]

    static func fullModelID(for info: ModelInfo) -> String {
        info.id.hasPrefix("\(info.provider)/")
            ? info.id
            : "\(info.provider)/\(info.id)"
    }

    static func compatibleModelGroups(from models: [ModelInfo]) -> [ModelGroup] {
        let compatible = models.filter { !incompatibleProviders.contains($0.provider) }
        let byProvider = Dictionary(grouping: compatible, by: \.provider)
        return byProvider
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { provider, items in
                ModelGroup(
                    provider: provider,
                    models: items.map { info in
                        ModelGroup.Entry(
                            id: info.id,
                            fullId: fullModelID(for: info),
                            name: info.name
                        )
                    }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                )
            }
    }
}

struct ModelGroup: Identifiable {
    let provider: String
    let models: [Entry]

    var id: String { provider }

    struct Entry: Identifiable {
        let id: String
        let fullId: String
        let name: String
    }
}
