import Foundation

/// Decision for handling a model selection in chat.
enum ModelSwitchDecision: Equatable {
    /// Selected model is already active.
    case unchanged

    /// Switch to the selected model immediately.
    case applyImmediately
}

struct ModelSwitchPolicy {
    static func decision(
        currentModel: String?,
        selectedModel: ModelInfo,
        messageCount _: Int
    ) -> ModelSwitchDecision {
        if isCurrentSelection(currentModel: currentModel, selectedModel: selectedModel) {
            return .unchanged
        }

        return .applyImmediately
    }

    static func isCurrentSelection(
        currentModel: String?,
        selectedModel: ModelInfo
    ) -> Bool {
        guard let currentModel else { return false }
        let fullID = fullModelID(for: selectedModel)
        return currentModel == fullID || currentModel == selectedModel.id
    }

    static func fullModelID(for model: ModelInfo) -> String {
        model.id.hasPrefix("\(model.provider)/")
            ? model.id
            : "\(model.provider)/\(model.id)"
    }
}
