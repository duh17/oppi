import Foundation

/// Small Mac-side model-selection helpers for the shared `ModelInfo` DTO.
///
/// Server model IDs may arrive as either bare model IDs or already-prefixed
/// `provider/model` strings. Keep normalization local to the Mac adapter so UI
/// code sends the command shape the server expects without duplicating string
/// handling in views.
enum MacModelSelection {
    static func fullModelID(for model: ModelInfo) -> String {
        model.id.hasPrefix("\(model.provider)/")
            ? model.id
            : "\(model.provider)/\(model.id)"
    }

    static func commandModelID(for model: ModelInfo) -> String {
        let prefix = "\(model.provider)/"
        if model.id.hasPrefix(prefix) {
            return String(model.id.dropFirst(prefix.count))
        }
        return model.id
    }

    static func isCurrent(model: ModelInfo, currentModel: String?) -> Bool {
        guard let currentModel else { return false }
        return currentModel == fullModelID(for: model) || currentModel == model.id
    }

    /// Keep exactly one starred global default after a persist:true write.
    static func markingDefault(_ models: [ModelInfo], as model: ModelInfo) -> [ModelInfo] {
        let defaultID = fullModelID(for: model)
        return models.map { existing in
            let isDefault = fullModelID(for: existing) == defaultID || existing.id == model.id
            guard existing.isDefault != isDefault else { return existing }
            return ModelInfo(
                id: existing.id,
                name: existing.name,
                provider: existing.provider,
                contextWindow: existing.contextWindow,
                thinkingLevels: existing.thinkingLevels,
                isDefault: isDefault
            )
        }
    }

    static func shortDisplayName(for modelID: String?) -> String? {
        guard let modelID else { return nil }
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
