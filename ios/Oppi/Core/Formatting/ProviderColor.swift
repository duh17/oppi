import SwiftUI

/// Maps model provider names to theme palette colors.
///
/// Uses the provider prefix from model strings like "anthropic/claude-sonnet-4-20250514".
/// Colors are sourced from the active theme palette for consistent contrast.
enum ProviderColor {

    /// Resolve a color for the given model string using the current theme palette.
    static func color(for model: String?, palette: ThemePalette) -> Color {
        guard let provider = provider(from: model) else {
            return palette.purple
        }

        switch provider {
        case "anthropic":
            return palette.orange
        case "openai":
            return palette.green
        case "google":
            return palette.blue
        case "meta", "meta-llama":
            return palette.cyan
        case "mistral", "mistralai":
            return palette.red
        case "deepseek":
            return palette.blue
        case "xai":
            return palette.yellow
        default:
            return palette.purple
        }
    }

    /// Extract provider prefix from a "provider/model-id" string.
    private static func provider(from model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        let parts = model.split(separator: "/", maxSplits: 1)
        guard parts.count >= 2 else { return nil }
        return String(parts[0]).lowercased()
    }
}
