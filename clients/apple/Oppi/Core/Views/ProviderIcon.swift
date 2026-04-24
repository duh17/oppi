import SwiftUI

/// Compact provider mark for model/provider UIs.
///
/// Prefers a bundled provider logo asset when available. Falls back to a
/// monogram mark when we don't have a vetted local asset yet.
struct ProviderIcon: View {
    let provider: String
    var size: CGFloat = Self.defaultIconSize

    private static let defaultIconSize: CGFloat = 11

    var body: some View {
        Group {
            if let assetName = Self.logoAssetName(for: provider) {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Self.brandColor(for: provider))
            } else {
                Text(Self.mark(for: provider))
                    .font(.system(size: max(8, size * 0.8), weight: .heavy, design: .rounded))
                    .foregroundStyle(Self.brandColor(for: provider))
            }
        }
        .frame(width: size, height: size, alignment: .center)
    }

    /// Human-friendly label for provider IDs used by pi/SDK.
    static func displayName(for provider: String) -> String {
        let normalized = normalize(provider)
        if let label = knownDisplayNames[normalized] {
            return label
        }

        let canonical = canonicalProviderKey(for: normalized)
        if let label = knownDisplayNames[canonical] {
            return label
        }

        return humanizedProviderName(normalized)
    }

    /// Asset catalog image name for a provider logo, if we have one.
    static func logoAssetName(for provider: String) -> String? {
        let key = canonicalProviderKey(for: provider)
        guard providersWithLogoAsset.contains(key) else {
            return nil
        }
        return "provider-\(key)"
    }

    /// Provider color mapped onto the active theme palette.
    static func brandColor(for provider: String) -> Color {
        let canonical = canonicalProviderKey(for: provider)
        if knownDisplayNames[canonical] == nil {
            return .themeComment
        }
        return ProviderColor.color(
            forProvider: canonical,
            palette: ThemeRuntimeState.currentPalette()
        )
    }

    /// Single-character monogram mark for compact rendering.
    static func mark(for provider: String) -> String {
        switch canonicalProviderKey(for: provider) {
        case "anthropic": return "A"
        case "openai", "azure-openai-responses": return "O"
        case "google", "google-vertex": return "G"
        case "deepseek": return "D"
        case "openrouter": return "R"
        case "amazon-bedrock": return "B"
        case "mistral", "minimax": return "M"
        case "xai": return "X"
        case "zai": return "Z"
        case "github-copilot", "cerebras": return "C"
        case "groq": return "Q"
        case "huggingface": return "H"
        case "kimi-coding": return "K"
        case "vercel-ai-gateway": return "V"
        case "lmstudio": return "L"
        case "omlx", "ollama", "opencode": return "O"
        default:
            return provider.first.map { String($0).uppercased() } ?? "?"
        }
    }

    private static let providerAliases: [String: String] = [
        "openai-codex": "openai",
        "google-gemini-cli": "google",
        "google-antigravity": "google",
        "minimax-cn": "minimax",
        "opencode-go": "opencode",
    ]

    /// Providers with local official-source logo assets enabled for in-app display.
    private static let providersWithLogoAsset: Set<String> = [
        "anthropic",
        "cerebras",
        "deepseek",
        "fireworks",
        "github-copilot",
        "huggingface",
        "kimi-coding",
        "minimax",
        "mistral",
        "openai",
        "openrouter",
        "vercel-ai-gateway",
        "xai",
        "zai",
    ]

    private static let knownDisplayNames: [String: String] = [
        "amazon-bedrock": "Amazon Bedrock",
        "anthropic": "Anthropic",
        "azure-openai-responses": "Azure OpenAI",
        "cerebras": "Cerebras",
        "deepseek": "DeepSeek",
        "github-copilot": "GitHub Copilot",
        "google": "Google",
        "google-antigravity": "Google Antigravity",
        "google-gemini-cli": "Gemini CLI",
        "google-vertex": "Google Vertex AI",
        "groq": "Groq",
        "huggingface": "Hugging Face",
        "kimi-coding": "Kimi Coding",
        "lmstudio": "LM Studio",
        "minimax": "MiniMax",
        "minimax-cn": "MiniMax CN",
        "ollama": "Ollama",
        "omlx": "OMLX",
        "mistral": "Mistral",
        "openai": "OpenAI",
        "openai-codex": "OpenAI Codex",
        "opencode": "OpenCode",
        "opencode-go": "OpenCode Go",
        "openrouter": "OpenRouter",
        "vercel-ai-gateway": "Vercel AI Gateway",
        "xai": "xAI",
        "zai": "Z.AI",
    ]

    private static let acronymTokens: Set<String> = ["ai", "api", "cli", "cn", "llm", "ml"]

    private static func normalize(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func canonicalProviderKey(for provider: String) -> String {
        let key = normalize(provider)
        return providerAliases[key] ?? key
    }

    private static func humanizedProviderName(_ provider: String) -> String {
        guard !provider.isEmpty else { return "Unknown" }
        let tokens = provider.split(whereSeparator: { $0 == "-" || $0 == "_" })
        return tokens
            .map { token in
                let value = String(token)
                if acronymTokens.contains(value) {
                    return value.uppercased()
                }
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }
}
