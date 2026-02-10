import SwiftUI

/// Compact interactive toolbar showing session state and controls.
///
/// Sits below the navigation bar in ChatView. Interactive sections:
/// - Model name: tap to open model picker sheet
/// - Thinking level: tap to cycle (off -> low -> medium -> high -> off)
/// - Context usage: informational progress bar + percentage
/// - Overflow menu: compact, rename session
struct SessionToolbar: View {
    let session: Session?
    let thinkingLevel: ThinkingLevel
    let onModelTap: () -> Void
    let onThinkingCycle: () -> Void
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
        let percent = Double(used) / Double(window) * 100
        return String(format: "%.0f%%/%@", percent, formatTokenCount(window))
    }

    private var contextPercent: Double {
        guard let window = resolvedContextWindow, window > 0 else { return 0 }
        return Double(effectiveContextTokens) / Double(window)
    }

    private var effectiveContextTokens: Int {
        let tokens = session?.contextTokens
            ?? ((session?.tokens.input ?? 0) + (session?.tokens.output ?? 0))
        return max(0, tokens)
    }

    private var resolvedContextWindow: Int? {
        if let window = session?.contextWindow, window > 0 { return window }
        guard let model = session?.model else { return nil }
        return inferContextWindow(from: model)
    }

    private var thinkingLabel: String {
        switch thinkingLevel {
        case .off: return "off"
        case .minimal: return "min"
        case .low: return "low"
        case .medium: return "med"
        case .high: return "high"
        case .xhigh: return "max"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Model picker — 44pt min touch target
            Button(action: onModelTap) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text(modelDisplay)
                        .font(.caption.monospaced().bold())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.tokyoCyan)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            toolbarSeparator

            // Thinking level cycle — 44pt min touch target
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onThinkingCycle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text(thinkingLabel)
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.tokyoPurple)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Context usage
            if let display = contextDisplay {
                ContextIndicator(display: display, percent: contextPercent)
            }

            // Cost
            if let cost = session?.cost, cost > 0 {
                Text(String(format: "$%.3f", cost))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tokyoComment)
                    .padding(.leading, 8)
            }

            // Overflow menu — 44pt touch target
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
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.tokyoComment)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 4)
        .background(Color.tokyoBgHighlight)
    }

    private var toolbarSeparator: some View {
        Rectangle()
            .fill(Color.tokyoComment.opacity(0.3))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 10)
    }
}

// MARK: - Context Indicator

private struct ContextIndicator: View {
    let display: String
    let percent: Double

    private var barColor: Color {
        if percent > 0.9 { return .tokyoRed }
        if percent > 0.7 { return .tokyoOrange }
        return .tokyoGreen
    }

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.tokyoComment.opacity(0.3))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * min(percent, 1.0))
                }
            }
            .frame(width: 24, height: 4)

            Text(display)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tokyoFgDim)
        }
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
