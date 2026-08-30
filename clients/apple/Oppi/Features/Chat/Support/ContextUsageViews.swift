import SwiftUI

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
            }

            Text(usage.progress.map { String(Int(($0 * 100).rounded())) } ?? "0")
                .font(.appBadgeCountRounded)
                .foregroundStyle(.themeFg)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel(usage.accessibilityLabel)
    }
}
