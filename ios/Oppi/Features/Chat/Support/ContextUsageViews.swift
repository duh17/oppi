import SwiftUI

struct ContextUsageSnapshot: Sendable, Equatable {
    let tokens: Int?
    let window: Int?

    var progress: Double? {
        guard let tokens, let window, window > 0 else { return nil }
        return min(max(Double(tokens) / Double(window), 0), 1)
    }

    var percentText: String {
        guard let progress else { return "Unknown" }
        return String(format: "%.1f%%", progress * 100)
    }

    var usageText: String {
        guard let window, window > 0 else { return "Unknown" }
        guard let tokens else { return "— / \(formatTokenCount(window))" }
        return "\(formatTokenCount(tokens)) / \(formatTokenCount(window))"
    }

    var accessibilityLabel: String {
        guard let window, window > 0 else {
            return "Context usage unavailable"
        }
        guard let tokens else {
            return "Context usage unknown out of \(window) tokens"
        }
        let percent = Int(((Double(tokens) / Double(window)) * 100).rounded())
        return "Context usage \(percent) percent, \(tokens) of \(window) tokens"
    }
}

struct ContextUsageRingBadge: View {
    let usage: ContextUsageSnapshot

    private var strokeColor: Color {
        guard let progress = usage.progress else { return .themeComment }
        if progress > 0.9 { return .themeRed }
        if progress > 0.7 { return .themeOrange }
        return .themeGreen
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.themeComment.opacity(0.35), lineWidth: 2)

            if let progress = usage.progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        strokeColor,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(
                        .themeComment,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 2])
                    )
                    .rotationEffect(.degrees(-90))
            }

            Text(usage.progress.map { String(Int(($0 * 100).rounded())) } ?? "?")
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(.themeFg)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel(usage.accessibilityLabel)
    }
}
