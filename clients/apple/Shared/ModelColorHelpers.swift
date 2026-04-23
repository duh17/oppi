import SwiftUI

// MARK: - Shared model-color helpers (used by DailyCostChart + ModelBreakdownView + ActivityHeatmap + ModelDonutChart)

/// Shared model colors.
///
/// These helpers are compiled into app extensions too, so keep them independent
/// of app-only theme runtime types. The provider families still match the main
/// app's color semantics.
func modelColor(_ model: String) -> Color {
    let lower = model.lowercased()

    if let provider = providerPrefix(from: lower) {
        switch canonicalProvider(provider) {
        case "anthropic":
            return .orange
        case "openai", "azure-openai-responses", "github-copilot":
            return .green
        case "google", "google-vertex", "google-antigravity", "google-gemini-cli", "deepseek":
            return .blue
        case "meta", "meta-llama", "openrouter", "vercel-ai-gateway", "opencode":
            return .cyan
        case "amazon-bedrock", "xai":
            return .yellow
        case "mistral", "mistralai":
            return .red
        default:
            return .purple
        }
    }

    if lower.contains("claude") || lower.contains("opus") || lower.contains("sonnet") || lower.contains("haiku") {
        return .orange
    }
    if lower.contains("gpt") || lower.contains("codex") {
        return .green
    }
    if lower.contains("gemini") {
        return .blue
    }
    if lower.contains("grok") {
        return .yellow
    }
    if lower.contains("mistral") {
        return .red
    }
    if lower.contains("mlx") || lower.contains("ollama") || lower.contains("lmstudio") {
        return .secondary
    }

    let accents: [Color] = [
        .blue,
        .cyan,
        .green,
        .orange,
        .purple,
        .red,
        .yellow,
    ]
    return accents[abs(model.hashValue) % accents.count]
}

/// Shorten model names for display.
/// `anthropic/claude-sonnet-4-6-20250514` → `sonnet-4-6`
func displayModelName(_ model: String) -> String {
    // Strip provider prefix (e.g. `anthropic/`)
    let last = String(model.split(separator: "/").last ?? Substring(model))
    var cleaned = last.replacingOccurrences(of: "claude-", with: "")
    // Drop trailing 8-digit date segment
    let parts = cleaned.split(separator: "-")
    if let tail = parts.last, tail.count >= 8, tail.allSatisfy(\.isNumber) {
        cleaned = parts.dropLast().joined(separator: "-")
    }
    return cleaned
}

private func providerPrefix(from model: String) -> String? {
    let parts = model.split(separator: "/", maxSplits: 1)
    guard parts.count >= 2 else { return nil }
    return String(parts[0])
}

private func canonicalProvider(_ provider: String) -> String {
    providerAliases[provider] ?? provider
}

private let providerAliases: [String: String] = [
    "openai-codex": "openai",
    "minimax-cn": "minimax",
    "opencode-go": "opencode",
]
