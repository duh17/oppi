import SwiftUI

extension QuickSessionModel {
    /// The model picker for Quick Session's launch: the shared SwiftUI
    /// `ModelPickerSheet`, hosted by the router with the selected server's API
    /// client and model catalog. Its star saves Pi's or the selected Agent's
    /// default.
    func modelPickerScreen() -> RouterScreen {
        .hosted { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                ModelPickerSheet(
                    currentModel: self.displayedModelId,
                    onSelect: { [weak self] in self?.selectModel($0) },
                    onSetDefault: { [weak self] model in
                        try await self?.saveModelAsDefault(model)
                    },
                    defaultAgentId: self.selectedAgentId
                )
                .environment(\.apiClient, self.selectedServerConnection()?.apiClient)
                .environment(self.selectedChatState)
            )
        }
    }
}
