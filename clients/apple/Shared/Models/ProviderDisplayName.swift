import Foundation

// MARK: - Provider names

/// The human name of a Pi provider key ("anthropic" → "Anthropic"): the usage
/// charts, the model pill, and the AI sharing consent (which the Share
/// extension also compiles, so this file is Foundation only).
func providerDisplayLabel(_ provider: String?) -> String {
    guard let provider = normalizedProviderKey(provider), !provider.isEmpty else {
        return "Unknown"
    }

    if let label = knownProviderDisplayNames[provider] {
        return label
    }

    let canonical = canonicalProviderBrandKey(provider)
    if let label = knownProviderDisplayNames[canonical] {
        return label
    }

    return humanizedProviderName(provider)
}

func normalizedProviderKey(_ provider: String?) -> String? {
    guard let provider else { return nil }
    let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
}

/// The brand a provider variant belongs to ("openai-codex" → "openai").
func canonicalProviderBrandKey(_ provider: String) -> String {
    providerAliases[provider] ?? provider
}

private func humanizedProviderName(_ provider: String) -> String {
    let tokens = provider.split(whereSeparator: { $0 == "-" || $0 == "_" })
    return tokens
        .map { token in
            let value = String(token)
            if acronymProviderTokens.contains(value) {
                return value.uppercased()
            }
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        .joined(separator: " ")
}

private let providerAliases: [String: String] = [
    "openai-codex": "openai",
    "google-gemini-cli": "google",
    "google-antigravity": "google",
    "google-vertex": "google",
    "minimax-cn": "minimax",
    "opencode-go": "opencode",
    "qwen-token-plan": "qwen",
    "qwen-token-plan-cn": "qwen",
]

private let knownProviderDisplayNames: [String: String] = [
    "amazon-bedrock": "Amazon Bedrock",
    "anthropic": "Anthropic",
    "azure": "Azure OpenAI",
    "cerebras": "Cerebras",
    "cursor": "Cursor",
    "deepseek": "DeepSeek",
    "ds4": "DS4 Dwarf Star",
    "github-copilot": "GitHub Copilot",
    "google": "Google",
    "google-antigravity": "Google Antigravity",
    "google-gemini-cli": "Gemini CLI",
    "google-vertex": "Google Vertex AI",
    "groq": "Groq",
    "huggingface": "Hugging Face",
    "kimi-coding": "Kimi Coding",
    "lmstudio": "LM Studio",
    "mlx-serve": "MLX Serve",
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
    "qwen": "Qwen",
    "qwen-token-plan": "Qwen Token Plan",
    "qwen-token-plan-cn": "Qwen Token Plan CN",
    "vercel-ai-gateway": "Vercel AI Gateway",
    "xai": "xAI",
    "zai": "Z.AI",
]

private let acronymProviderTokens: Set<String> = ["ai", "api", "cli", "cn", "llm", "ml", "mlx"]
