import SwiftUI
import UIKit

private enum AgentIconPickerError: LocalizedError {
    case serverOffline

    var errorDescription: String? { "Server is offline" }
}

/// Saved-Agent adapter for the shared icon/avatar picker interaction.
struct AgentIconPickerView: View {
    @Environment(\.apiClient) private var apiClient

    let agent: StoredAgentDefinition
    let onSaved: (StoredAgentDefinition) -> Void
    private let saveOperation: ((IconChoice) async throws -> StoredAgentDefinition)?

    init(
        agent: StoredAgentDefinition,
        saveOperation: ((IconChoice) async throws -> StoredAgentDefinition)? = nil,
        onSaved: @escaping (StoredAgentDefinition) -> Void
    ) {
        self.agent = agent
        self.saveOperation = saveOperation
        self.onSaved = onSaved
    }

    var body: some View {
        UnifiedIconPickerView(
            purpose: .agent,
            savedValue: agent.definition.icon,
            defaultValue: .defaultValue,
            makeEmoji: IconChoice.emoji,
            makeSymbol: IconChoice.symbol,
            symbolName: Self.symbolName,
            customChoice: Self.customChoice,
            preview: { value, size in
                AnyView(AgentIconView(
                    value: value,
                    size: size,
                    frameSize: 44,
                    isDecorative: true
                ))
            },
            genmojiPreview: { data, contentDescription, size in
                AnyView(AssistantAvatarPreview(
                    avatar: .genmoji(data: data, contentDescription: contentDescription),
                    sessionId: "agent-icon-picker-genmoji",
                    size: size
                ))
            },
            prepareGenmoji: { data, contentDescription in
                guard let apiClient else { throw AgentIconPickerError.serverOffline }
                let asset = try await apiClient.uploadIconAsset(
                    data: data,
                    contentType: NSAdaptiveImageGlyph.contentType.preferredMIMEType ?? "image/heic"
                )
                return .genmoji(
                    assetId: asset.assetId,
                    contentDescription: contentDescription
                )
            },
            commit: { icon in
                let updated: StoredAgentDefinition
                if let saveOperation {
                    updated = try await saveOperation(icon)
                } else {
                    guard let apiClient else { throw AgentIconPickerError.serverOffline }
                    updated = try await apiClient.updateAgentIcon(agentId: agent.id, icon: icon)
                }
                onSaved(updated)
            },
            accessibilityPrefix: "agent.iconPicker"
        )
    }

    private static func symbolName(_ value: IconChoice) -> String? {
        guard case .symbol(let name) = value else { return nil }
        return name
    }

    private static func customChoice(_ value: IconChoice) -> IconPickerCustomChoice? {
        switch value {
        case .emoji(let emoji): return .emoji(emoji)
        case .genmoji(_, let contentDescription): return .genmoji(contentDescription)
        case .defaultValue, .symbol: return nil
        }
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
