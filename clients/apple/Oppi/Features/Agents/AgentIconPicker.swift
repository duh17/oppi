import UIKit

/// The saved-Agent adapter of the shared icon picker: the picker over the
/// Agent's icon, which Save sends to the server.
enum AgentIconPicker {
    /// The picker for `agent`, to present with `ModalPresentation.iconPicker`.
    /// `onSaved` receives the Agent the server returns.
    @MainActor
    static func viewController(
        agent: StoredAgentDefinition,
        connection: ServerConnection,
        onSaved: @escaping (StoredAgentDefinition) -> Void
    ) -> IconPickerViewController {
        let apiClient = connection.apiClient
        return IconPickerViewController(source: .init(
            purpose: .agent,
            savedValue: agent.definition.icon,
            accessibilityPrefix: "agent.iconPicker",
            assetCache: connection.iconAssetCache,
            prepareGenmoji: IconPickerViewController.uploadGenmoji(using: apiClient),
            commit: { icon in
                guard let apiClient else { throw IconPickerViewController.offlineError }
                onSaved(try await apiClient.updateAgentIcon(agentId: agent.id, icon: icon))
            }
        ))
    }

    static func description(_ value: IconChoice) -> String {
        switch AgentIconContent.resolve(value) {
        case .text(let emoji): return "Emoji \(emoji)"
        case .symbol(let name): return IconSymbolCatalog.label(for: name) ?? "SF Symbol"
        case .genmoji(_, let contentDescription): return contentDescription
        case .fallback: return "Default"
        }
    }
}
