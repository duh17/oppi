import Foundation

/// Thinking levels advertised by GET /models for the current session model.
enum ThinkingLevelMenuSource {
    static func levels(for model: ModelInfo?) -> [ThinkingLevel] {
        guard let advertised = model?.thinkingLevels, !advertised.isEmpty else {
            return ThinkingLevel.allCases
        }
        let allowed = Set(advertised)
        return ThinkingLevel.allCases.filter { allowed.contains($0) }
    }

    static func levels(for modelId: String?, in models: [ModelInfo]) -> [ThinkingLevel] {
        levels(for: model(for: modelId, in: models))
    }

    static func model(for modelId: String?, in models: [ModelInfo]) -> ModelInfo? {
        guard let modelId else { return nil }
        return models.first { matches(modelId, $0) }
    }

    static func matches(_ modelId: String, _ model: ModelInfo) -> Bool {
        let fullId = model.id.hasPrefix("\(model.provider)/")
            ? model.id
            : "\(model.provider)/\(model.id)"
        return modelId == fullId || modelId == model.id
    }
}
