import Foundation
import SwiftUI

// MARK: - Shared model presentation helpers

/// Shared model presentation helpers used by iOS and macOS stats surfaces.
///
/// Colors are derived from the stable model id, not the provider, so the same
/// model keeps the same color even when served through different providers.
struct ModelDisplayIdentity: Equatable {
    let provider: String?
    let providerDisplayName: String?
    let displayName: String
    let normalizedModelID: String

    /// Provider stays part of the grouping key so the UI can show provider and
    /// model separately without collapsing different providers together.
    var aggregationKey: String {
        let providerKey = provider ?? "unknown"
        return "\(providerKey)/\(normalizedModelID)"
    }
}

func modelDisplayIdentity(_ model: String?) -> ModelDisplayIdentity {
    let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let provider = normalizedProviderKey(from: raw)
    let displayName = cleanedModelDisplayName(from: raw)

    return ModelDisplayIdentity(
        provider: provider,
        providerDisplayName: provider.map(providerDisplayLabel),
        displayName: displayName,
        normalizedModelID: normalizedStableModelID(from: raw)
    )
}

/// Shared model colors.
///
/// The base hue comes from the stable model family. Version numbers increase
/// saturation/brightness so newer stable versions read a bit louder without any
/// manual per-release updates. Provider does not affect the color.
func modelColor(_ model: String) -> Color {
    let identity = modelDisplayIdentity(model)
    let normalized = identity.normalizedModelID

    guard !normalized.isEmpty, normalized != "unknown", normalized != "other" else {
        return .secondary
    }

    let familyKey = modelFamilyKey(from: normalized)
    let baseHue = baseHue(for: familyKey, normalizedModelID: normalized)
    let salience = versionSalience(for: normalized)
    let adjustment = variantAdjustment(for: normalized)
    let versionHueOffset = versionColorHueOffset(for: normalized)
    let variantSeedOffset = variantSeedHueOffset(for: normalized, familyKey: familyKey)

    let hue = wrappedHue(baseHue + versionHueOffset + variantSeedOffset + adjustment.hue)
    let saturation = clamp(0.58 + (salience * 1.15) + adjustment.saturation, lower: 0.44, upper: 0.96)
    let brightness = clamp(0.68 + (salience * 1.05) + adjustment.brightness, lower: 0.54, upper: 0.98)

    return Color(hue: hue, saturation: saturation, brightness: brightness)
}

/// Shorten model names for display.
/// `anthropic/claude-sonnet-4-6-20250514` → `sonnet-4-6`
func displayModelName(_ model: String) -> String {
    modelDisplayIdentity(model).displayName
}

func modelProviderKey(_ model: String?) -> String? {
    modelDisplayIdentity(model).provider
}

func modelProviderLabel(_ model: String?) -> String? {
    modelDisplayIdentity(model).providerDisplayName
}

func modelAggregationKey(_ model: String?) -> String {
    modelDisplayIdentity(model).aggregationKey
}

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

func providerLogoAssetName(_ provider: String?) -> String? {
    guard let provider = normalizedProviderKey(provider), !provider.isEmpty else {
        return nil
    }

    let canonical = canonicalProviderBrandKey(provider)
    guard providersWithLogoAsset.contains(canonical) else {
        return nil
    }
    return "provider-\(canonical)"
}

func providerMonogram(_ provider: String?) -> String {
    guard let provider = normalizedProviderKey(provider), !provider.isEmpty else {
        return "?"
    }

    switch canonicalProviderBrandKey(provider) {
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

struct ProviderGlyph: View {
    let provider: String?
    var size: CGFloat = 11
    var color: Color = .secondary

    var body: some View {
        Group {
            if let provider = normalizedProviderKey(provider) {
                if let assetName = providerLogoAssetName(provider) {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(color)
                } else {
                    Text(providerMonogram(provider))
                        .font(.system(size: max(8, size * 0.8), weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size, alignment: .center)
    }
}

private struct ModelColorAdjustment {
    var hue: Double = 0
    var saturation: Double = 0
    var brightness: Double = 0
}

private func cleanedModelDisplayName(from model: String) -> String {
    let raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "unknown" }

    let last = String(raw.split(separator: "/").last ?? Substring(raw))
    let withoutClaudePrefix = last.replacingOccurrences(of: "claude-", with: "")
    let parts = withoutClaudePrefix.split(separator: "-")

    if let tail = parts.last, isTimestampToken(String(tail)) {
        let cleaned = parts.dropLast().joined(separator: "-")
        return cleaned.isEmpty ? withoutClaudePrefix : cleaned
    }

    return withoutClaudePrefix
}

private func normalizedStableModelID(from model: String) -> String {
    cleanedModelDisplayName(from: model)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func normalizedProviderKey(_ provider: String?) -> String? {
    guard let provider else { return nil }
    let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
}

private func normalizedProviderKey(from model: String) -> String? {
    let parts = model.split(separator: "/", maxSplits: 1)
    guard parts.count >= 2 else { return nil }
    return normalizedProviderKey(String(parts[0]))
}

private func canonicalProviderBrandKey(_ provider: String) -> String {
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

private func modelFamilyKey(from normalizedModelID: String) -> String {
    let tokens = normalizedModelID.split(separator: "-").map(String.init)
    guard !tokens.isEmpty else { return normalizedModelID }

    var family: [String] = []
    for token in tokens {
        if isVersionToken(token) || isTimestampToken(token) {
            break
        }
        if !family.isEmpty, variantTokens.contains(token) {
            break
        }
        family.append(token)
    }

    if family.isEmpty {
        return tokens[0]
    }

    return family.joined(separator: "-")
}

private func baseHue(for familyKey: String, normalizedModelID: String) -> Double {
    if normalizedModelID.hasPrefix("gpt") || normalizedModelID.hasPrefix("o1") || normalizedModelID.hasPrefix("o3") || normalizedModelID.hasPrefix("o4") || normalizedModelID.contains("codex") {
        return 0.36
    }
    if normalizedModelID.contains("sonnet") || normalizedModelID.contains("opus") || normalizedModelID.contains("haiku") || normalizedModelID.contains("claude") {
        return 0.08
    }
    if normalizedModelID.contains("deepseek") {
        return 0.58
    }
    if normalizedModelID.contains("gemini") {
        return 0.55
    }
    if normalizedModelID.contains("glm") {
        return 0.52
    }
    if normalizedModelID.contains("grok") {
        return 0.14
    }
    if normalizedModelID.contains("mistral") || normalizedModelID.contains("magistral") {
        return 0.0
    }
    if normalizedModelID.contains("llama") {
        return 0.74
    }

    let anchors: [Double] = [0.0, 0.08, 0.14, 0.22, 0.32, 0.40, 0.52, 0.60, 0.72, 0.82]
    let index = Int(stableHash(familyKey) % UInt64(anchors.count))
    return anchors[index]
}

private func versionSalience(for normalizedModelID: String) -> Double {
    let components = modelVersionComponents(from: normalizedModelID)
    let weights: [Double] = [0.008, 0.028, 0.010]

    var salience = 0.0
    for (index, component) in components.enumerated() where index < weights.count {
        salience += Double(min(component, 9)) * weights[index]
    }
    return min(0.24, salience)
}

private func versionColorHueOffset(for normalizedModelID: String) -> Double {
    let components = modelVersionComponents(from: normalizedModelID)
    guard !components.isEmpty else { return 0 }

    var offset = 0.0
    if components.indices.contains(0) {
        offset += Double((components[0] % 5) - 2) * 0.012
    }
    if components.indices.contains(1) {
        offset += Double((components[1] % 7) - 3) * 0.030
    }
    if components.indices.contains(2) {
        offset += Double((components[2] % 5) - 2) * 0.012
    }

    return clamp(offset, lower: -0.10, upper: 0.10)
}

private func variantSeedHueOffset(for normalizedModelID: String, familyKey: String) -> Double {
    let suffix = normalizedModelID
        .replacingOccurrences(of: familyKey, with: "", options: [.anchored])
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    guard !suffix.isEmpty else { return 0 }
    let bucket = Double(Int(stableHash(suffix) % 5) - 2)
    return bucket * 0.009
}

private func modelVersionComponents(from normalizedModelID: String) -> [Int] {
    let tokens = normalizedModelID.split(separator: "-").map(String.init)
    var components: [Int] = []

    for token in tokens {
        let tokenComponents = versionComponents(in: token)
        if !tokenComponents.isEmpty {
            components.append(contentsOf: tokenComponents)
        }
    }

    return components
}

private func variantAdjustment(for normalizedModelID: String) -> ModelColorAdjustment {
    let tokens = Set(normalizedModelID.split(separator: "-").map(String.init))
    var adjustment = ModelColorAdjustment()

    if !tokens.isDisjoint(with: ["mini", "nano", "lite", "flash", "small"]) {
        adjustment.saturation -= 0.14
        adjustment.brightness += 0.04
    }

    if !tokens.isDisjoint(with: ["codex", "coder"]) {
        adjustment.hue += 0.045
        adjustment.saturation += 0.08
        adjustment.brightness -= 0.03
    }

    if !tokens.isDisjoint(with: ["pro", "max", "ultra", "opus"]) {
        adjustment.saturation += 0.04
        adjustment.brightness -= 0.01
    }

    if !tokens.isDisjoint(with: ["preview", "experimental", "beta"] ) {
        adjustment.saturation += 0.03
        adjustment.brightness += 0.02
    }

    return adjustment
}

private func versionComponents(in token: String) -> [Int] {
    var candidate = token
    if token.count > 1, token.first == "v" {
        let remainder = String(token.dropFirst())
        if isVersionToken(remainder) {
            candidate = remainder
        }
    }

    guard isVersionToken(candidate) else {
        return []
    }

    return candidate
        .split(separator: ".")
        .compactMap { Int($0) }
}

private func isVersionToken(_ token: String) -> Bool {
    guard !token.isEmpty, !isTimestampToken(token) else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789.")
    return token.unicodeScalars.allSatisfy { allowed.contains($0) }
}

private func isTimestampToken(_ token: String) -> Bool {
    token.count >= 8 && token.allSatisfy(\.isNumber)
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func wrappedHue(_ hue: Double) -> Double {
    let wrapped = hue.truncatingRemainder(dividingBy: 1)
    return wrapped >= 0 ? wrapped : wrapped + 1
}

private func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

private let variantTokens: Set<String> = [
    "beta",
    "codex",
    "coder",
    "experimental",
    "flash",
    "lite",
    "max",
    "mini",
    "nano",
    "preview",
    "pro",
    "small",
    "ultra",
]

private let providerAliases: [String: String] = [
    "openai-codex": "openai",
    "google-gemini-cli": "google",
    "google-antigravity": "google",
    "minimax-cn": "minimax",
    "opencode-go": "opencode",
]

private let providersWithLogoAsset: Set<String> = [
    "anthropic",
    "cerebras",
    "deepseek",
    "fireworks",
    "github-copilot",
    "huggingface",
    "kimi-coding",
    "minimax",
    "mistral",
    "omlx",
    "openai",
    "openrouter",
    "vercel-ai-gateway",
    "xai",
    "zai",
]

private let knownProviderDisplayNames: [String: String] = [
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

private let acronymProviderTokens: Set<String> = ["ai", "api", "cli", "cn", "llm", "ml"]
