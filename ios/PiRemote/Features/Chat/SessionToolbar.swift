import SwiftUI

/// Quick actions dock for session controls.
///
/// Lives above the composer so model + thinking controls are thumb-reachable.
/// This replaces the old top-of-chat control row to recover vertical space.
struct SessionToolbar: View {
    let session: Session?
    let thinkingLevel: ThinkingLevel
    let onModelTap: () -> Void
    let onThinkingSelect: (ThinkingLevel) -> Void
    let onCompact: () -> Void
    let onRename: () -> Void
    var onNewSession: (() -> Void)?

    private var modelDisplay: String {
        guard let model = session?.model else { return "no model" }
        return shortModelName(model)
    }

    private var contextDisplay: String? {
        guard let window = resolvedContextWindow, window > 0 else { return nil }
        let used = effectiveContextTokens
        let percent = (Double(used) / Double(window)) * 100
        return String(format: "%.0f%%/%@", percent, formatTokenCount(window))
    }

    private var contextPercent: Double {
        guard let window = resolvedContextWindow, window > 0 else { return 0 }
        return min(max(Double(effectiveContextTokens) / Double(window), 0), 1)
    }

    private var contextTint: Color {
        if contextPercent > 0.9 { return .tokyoRed }
        if contextPercent > 0.7 { return .tokyoOrange }
        return .tokyoGreen
    }

    private var effectiveContextTokens: Int {
        let tokens = session?.contextTokens
            ?? ((session?.tokens.input ?? 0) + (session?.tokens.output ?? 0))
        return max(0, tokens)
    }

    private var resolvedContextWindow: Int? {
        if let window = session?.contextWindow, window > 0 {
            return window
        }
        guard let model = session?.model else {
            return nil
        }
        return inferContextWindow(from: model)
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
        HStack(spacing: 8) {
            Button(action: onModelTap) {
                QuickActionChipLabel(
                    icon: "cpu",
                    text: modelDisplay,
                    tint: .tokyoCyan,
                    showChevron: true,
                    maxTextWidth: 132
                )
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
                QuickActionChipLabel(
                    icon: "brain",
                    text: thinkingLabel,
                    tint: .tokyoPurple,
                    showChevron: true,
                    maxTextWidth: nil
                )
            }

            Menu {
                Button("Compact Context", systemImage: "arrow.down.doc") {
                    onCompact()
                }
                Button("Rename Session", systemImage: "pencil") {
                    onRename()
                }
                if let onNewSession {
                    Divider()
                    Button("New Session", systemImage: "plus") {
                        onNewSession()
                    }
                }
            } label: {
                QuickActionChipLabel(
                    icon: "ellipsis.circle",
                    text: "More",
                    tint: .tokyoComment,
                    showChevron: false,
                    maxTextWidth: nil
                )
            }

            Spacer(minLength: 4)

            if let contextDisplay {
                Text(contextDisplay)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(contextTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.tokyoBgHighlight.opacity(0.65), in: Capsule())
            }

            if let cost = session?.cost, cost > 0 {
                Text(String(format: "$%.3f", cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tokyoComment)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.tokyoComment.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

private struct QuickActionChipLabel: View {
    let icon: String
    let text: String
    let tint: Color
    let showChevron: Bool
    let maxTextWidth: CGFloat?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))

            if let maxTextWidth {
                Text(text)
                    .font(.caption.monospaced().bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: maxTextWidth, alignment: .leading)
            } else {
                Text(text)
                    .font(.caption.monospaced().bold())
                    .lineLimit(1)
            }

            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(Color.tokyoBgHighlight.opacity(0.7), in: Capsule())
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

/// Extract short display name from full "provider/model-id" string.
func shortModelName(_ model: String) -> String {
    let name = model.split(separator: "/").last.map(String.init) ?? model
    return name
        .replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "gemini-", with: "")
}
