import UIKit

/// The workspace adapter of the shared icon picker: the picker over a
/// workspace's icon, which Save hands to the form that opened it (New
/// Workspace's model, or a workspace's Details draft); the form's own Save sends
/// it to the server.
enum WorkspaceIconPicker {
    /// The picker over `icon`. `upload` stores a Genmoji and returns the icon
    /// that names it; without one the Genmoji goes to `apiClient`'s server.
    @MainActor
    static func viewController(
        icon: IconChoice,
        apiClient: APIClient?,
        assetCache: IconAssetCache?,
        upload: ((Data, String) async throws -> IconChoice)? = nil,
        commit: @escaping (IconChoice) -> Void
    ) -> IconPickerViewController {
        IconPickerViewController(source: .init(
            purpose: .workspace,
            savedValue: icon,
            accessibilityPrefix: "workspace.iconPicker",
            assetCache: assetCache,
            prepareGenmoji: upload ?? IconPickerViewController.uploadGenmoji(using: apiClient),
            commit: { commit($0) }
        ))
    }

    /// The picker as the router's root screen over New Workspace's form: a
    /// pick lands in the model, and a Genmoji uploads to the model's server.
    @MainActor
    static func screen(editing model: WorkspaceCreateModel) -> RouterScreen {
        .controller {
            viewController(
                icon: model.icon,
                apiClient: nil,
                assetCache: model.oppiConnection?.iconAssetCache,
                upload: { data, description in
                    try await model.uploadGenmoji(data: data, contentDescription: description)
                },
                commit: { model.icon = $0 }
            )
        }
    }

    static func description(_ value: IconChoice) -> String {
        switch AgentIconContent.resolve(value) {
        case .text(let emoji): return "Emoji \(emoji)"
        case .symbol(let name): return IconSymbolCatalog.label(for: name) ?? "SF Symbol"
        case .genmoji(_, let contentDescription): return contentDescription
        case .fallback: return "Default workspace icon"
        }
    }
}
