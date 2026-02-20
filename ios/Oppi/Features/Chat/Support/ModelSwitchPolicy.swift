import Foundation

/// Decision for handling a model selection in chat.
enum ModelSwitchDecision: Equatable {
    /// Selected model is already active.
    case unchanged

    /// Safe to switch immediately (empty/new session).
    case applyImmediately

    /// Mid-session switch should show a warning and require confirmation.
    case requireConfirmation
}

struct ModelSwitchPolicy {
    static func decision(
        currentModel: String?,
        selectedModel: ModelInfo,
        messageCount: Int
    ) -> ModelSwitchDecision {
        if isCurrentSelection(currentModel: currentModel, selectedModel: selectedModel) {
            return .unchanged
        }

        return messageCount > 0 ? .requireConfirmation : .applyImmediately
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
