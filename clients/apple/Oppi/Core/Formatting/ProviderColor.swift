import SwiftUI

/// Maps provider names to theme palette colors.
///
/// Uses the provider prefix from model strings like
/// `anthropic/claude-sonnet-4-20250514` and keeps provider marks consistent
/// across charts, rows, and picker surfaces.
enum ProviderColor {

    /// Resolve a color for the given model string using the current theme palette.
    static func color(for model: String?, palette: ThemePalette) -> Color {
        color(forProvider: provider(from: model), palette: palette)
    }

    /// Resolve a color for a raw provider id using the current theme palette.
    static func color(forProvider provider: String?, palette: ThemePalette) -> Color {
        guard let provider else {
            return palette.purple
        }

        switch canonicalProvider(provider) {
        case "anthropic":
            return palette.orange
        case "openai", "azure-openai-responses", "github-copilot":
            return palette.green
        case "google", "google-vertex", "google-antigravity", "google-gemini-cli", "deepseek":
            return palette.blue
        case "meta", "meta-llama", "openrouter", "vercel-ai-gateway", "opencode":
            return palette.cyan
        case "amazon-bedrock", "xai":
            return palette.yellow
        case "mistral", "mistralai":
            return palette.red
        default:
            return palette.purple
        }
    }

    /// Extract provider prefix from a `provider/model-id` string.
    static func provider(from model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        let parts = model.split(separator: "/", maxSplits: 1)
        guard parts.count >= 2 else { return nil }
        return String(parts[0]).lowercased()
    }

    private static func canonicalProvider(_ provider: String) -> String {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return providerAliases[normalized] ?? normalized
    }

    private static let providerAliases: [String: String] = [
        "openai-codex": "openai",
        "google-gemini-cli": "google-gemini-cli",
        "google-antigravity": "google-antigravity",
        "google-vertex": "google-vertex",
        "minimax-cn": "minimax",
        "opencode-go": "opencode",
    ]
}
