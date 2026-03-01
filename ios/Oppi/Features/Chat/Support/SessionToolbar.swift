import SwiftUI

/// Session control pills (model + thinking).
///
/// Body returns flat children (no wrapping container) so they merge
/// into the parent's `HStack` for even distribution with the attach button.
struct SessionToolbar: View {
    let session: Session?
    let thinkingLevel: ThinkingLevel
    let onModelTap: () -> Void
    let onThinkingSelect: (ThinkingLevel) -> Void

    @Environment(\.theme) private var theme

    private var modelDisplay: String {
        guard let model = session?.model else { return "no model" }
        return shortModelName(model)
    }

    private var modelProvider: String {
        guard let model = session?.model else { return "" }
        return providerFromModel(model) ?? ""
    }

    private var thinkingTint: Color {
        theme.thinking.color(for: thinkingLevel)
    }

    private static let thinkingOptions: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]

    private var thinkingLabel: String {
        Self.thinkingLabel(for: thinkingLevel)
    }

    private static func thinkingLabel(for level: ThinkingLevel) -> String {
        switch level {
        case .off: return "off"
        case .minimal: return "min"
        case .low: return "low"
        case .medium: return "med"
        case .high: return "high"
        case .xhigh: return "max"
        }
    }

    private static func thinkingMenuTitle(for level: ThinkingLevel) -> String {
        switch level {
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Max"
        }
    }

    var body: some View {
        Spacer(minLength: 0)

        Button(action: onModelTap) {
            PillLabel(text: modelDisplay, showChevron: true) {
                ProviderIcon(provider: modelProvider)
            }
        }
        .buttonStyle(.plain)

        Menu {
            ForEach(Self.thinkingOptions, id: \.rawValue) { level in
                Button {
                    guard level != thinkingLevel else { return }
                    onThinkingSelect(level)
                } label: {
                    if level == thinkingLevel {
                        Label(Self.thinkingMenuTitle(for: level), systemImage: "checkmark")
                    } else {
                        Text(Self.thinkingMenuTitle(for: level))
                    }
                }
            }
        } label: {
            PillLabel(text: thinkingLabel, tint: thinkingTint, showChevron: true) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}

private struct PillLabel<LeadingIcon: View>: View {
    private let iconSlotSize: CGFloat = 11
    private let chevronSlotWidth: CGFloat = 9
    private let minPillHeight: CGFloat = 17

    let text: String
    var tint: Color
    let showChevron: Bool
    let showsLeadingIcon: Bool
    let leadingIcon: LeadingIcon

    init(
        text: String,
        tint: Color = .themeFg,
        showChevron: Bool,
        showsLeadingIcon: Bool = true,
        @ViewBuilder leadingIcon: () -> LeadingIcon
    ) {
        self.text = text
        self.tint = tint
        self.showChevron = showChevron
        self.showsLeadingIcon = showsLeadingIcon
        self.leadingIcon = leadingIcon()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            if showsLeadingIcon {
                leadingIcon
                    .frame(
                        width: iconSlotSize,
                        height: iconSlotSize,
                        alignment: .center
                    )
            }

            Text(text)
                .font(.caption2.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .frame(
                        width: chevronSlotWidth,
                        height: iconSlotSize,
                        alignment: .center
                    )
            }
        }
        .frame(minHeight: minPillHeight)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Token Formatting (shared)

/// Format token count as compact string: 200000 -> "200k", 1000000 -> "1M".
func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        let m = Double(count) / 1_000_000
        if m == m.rounded() {
            return String(format: "%.0fM", m)
        }
        return String(format: "%.1fM", m)
    }
    if count >= 1_000 {
        let k = Double(count) / 1_000
        if k == k.rounded() {
            return String(format: "%.0fk", k)
        }
        return String(format: "%.1fk", k)
    }
    return "\(count)"
}

/// Best-effort context window fallback when older sessions lack the field.
func inferContextWindow(from model: String) -> Int? {
    let known: [String: Int] = [
        "anthropic/claude-opus-4-6": 200_000,
        "anthropic/claude-sonnet-4-0": 200_000,
        "anthropic/claude-haiku-3-5": 200_000,
        "openai/o3": 200_000,
        "openai/o4-mini": 200_000,
        "openai/gpt-4.1": 1_000_000,
        "openai-codex/gpt-5.1": 272_000,
        "openai-codex/gpt-5.2": 272_000,
        "openai-codex/gpt-5.2-codex": 272_000,
        "openai-codex/gpt-5.3-codex": 272_000,
        "google/gemini-2.5-pro": 1_000_000,
        "google/gemini-2.5-flash": 1_000_000,
        "lmstudio/glm-4.7": 128_000,
        "lmstudio/glm-4.7-flash-mlx": 128_000,
        "lmstudio/magistral-small-2509-mlx": 32_000,
        "lmstudio/minimax-m2.1": 196_608,
        "lmstudio/qwen3-coder-next": 128_000,
        "lmstudio/qwen3-32b": 32_768,
        "lmstudio/deepseek-r1-0528-qwen3-8b": 32_768,
    ]
    if let value = known[model] {
        return value
    }

    // Generic "...-272k" / "..._128k" model naming convention fallback.
    if let match = model.range(of: #"(?i)(\d{2,4})k\b"#, options: .regularExpression) {
        let raw = model[match].dropLast() // remove trailing k/K
        if let thousands = Int(raw) {
            return thousands * 1_000
        }
    }

    return nil
}

/// Extract provider prefix from "provider/model-id" string.
func providerFromModel(_ model: String) -> String? {
    guard let slashIndex = model.firstIndex(of: "/") else { return nil }
    let provider = String(model[model.startIndex..<slashIndex])
    return provider.isEmpty ? nil : provider
}

/// Extract short display name from full "provider/model-id" string.
func shortModelName(_ model: String) -> String {
    let name = model.split(separator: "/").last.map(String.init) ?? model
    return name
        .replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "gemini-", with: "")
}
