import UIKit

extension QuickSessionModel {
    /// The model picker for Quick Session's launch, given the selected
    /// server's API client and model catalog. Its star saves Pi's or the
    /// selected Agent's default; its current model follows the model while it
    /// is up.
    func modelPickerScreen() -> RouterScreen {
        let current = displayedModelId
        let chatState = selectedChatState
        let apiClient = selectedServerConnection()?.apiClient
        let agentId = selectedAgentId
        return .liveController({ [weak self] in
            ModelPickerViewController(
                currentModel: current,
                chatState: chatState,
                apiClient: apiClient,
                defaultAgentId: agentId,
                onSelect: { self?.selectModel($0) },
                onSetDefault: { model in try await self?.saveModelAsDefault(model) }
            )
        }, update: { $0.currentModel = current })
    }
}
