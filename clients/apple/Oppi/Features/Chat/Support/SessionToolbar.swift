import SwiftUI

/// Session control pills (model + thinking).
///
/// Body returns flat children (no wrapping container) so they merge
/// into the parent's `HStack` for even distribution with the attach button.
struct SessionToolbar: View {
    let session: Session?
    var modelOverride: String? = nil
    let thinkingLevel: ThinkingLevel
    let onModelTap: () -> Void
    let onThinkingSelect: (ThinkingLevel) -> Void

    @Environment(\.theme) private var theme

    private var effectiveModel: String? {
        modelOverride ?? session?.model
    }

    private var modelDisplay: String {
        guard let model = effectiveModel else { return "no model" }
        return shortModelName(model)
    }

    private var modelProvider: String {
        guard let model = effectiveModel else { return "" }
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
                    .font(.appCaption)
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
                    .font(.appBadgeCount)
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

/// Best-effort context window fallback when older sessions lack the field.
/// Static lookup table for known model context windows.
/// Allocated once, shared across all calls.
private let knownContextWindows: [String: Int] = [
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

func inferContextWindow(from model: String) -> Int? {
    if let value = knownContextWindows[model] {
        return value
    }

    // Fast manual scan for "NNNk" or "NNNk" pattern (2-4 digits followed by k/K at word boundary).
    // Avoids regex compilation and NSString bridging.
    let utf8 = Array(model.utf8)
    let count = utf8.count
    var i = count - 1
    // Scan backwards — the context size suffix is typically at the end
    while i >= 1 {
        let c = utf8[i]
        if c == UInt8(ascii: "k") || c == UInt8(ascii: "K") {
            // Check that next char (if any) is not alphanumeric (word boundary)
            let afterK = i + 1
            if afterK < count {
                let next = utf8[afterK]
                let isAlnum = (next >= UInt8(ascii: "0") && next <= UInt8(ascii: "9"))
                    || (next >= UInt8(ascii: "a") && next <= UInt8(ascii: "z"))
                    || (next >= UInt8(ascii: "A") && next <= UInt8(ascii: "Z"))
                    || next == UInt8(ascii: "_")
                if isAlnum { i -= 1; continue }
            }
            // Collect 2-4 digits before k/K
            var digitEnd = i
            var j = i - 1
            while j >= 0 && utf8[j] >= UInt8(ascii: "0") && utf8[j] <= UInt8(ascii: "9") {
                j -= 1
            }
            let digitStart = j + 1
            let digitCount = digitEnd - digitStart
            if digitCount >= 2 && digitCount <= 4 {
                var value = 0
                for d in digitStart..<digitEnd {
                    value = value * 10 + Int(utf8[d] - UInt8(ascii: "0"))
                }
                return value * 1_000
            }
        }
        i -= 1
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
