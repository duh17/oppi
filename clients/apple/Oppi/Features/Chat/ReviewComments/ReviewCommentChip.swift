import SwiftUI

struct ReviewCommentChip: View {
    let stagedCount: Int
    let onTap: () -> Void

    private let cornerRadius: CGFloat = 14
    private let baseFillOpacity = 0.86
    private let accentFillOpacity = 0.18
    private let strokeOpacity = 0.42

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themePurple)
                Text("\(stagedCount) review comment\(stagedCount == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("Review before send")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }
            .foregroundStyle(.themeFg)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.themeBg.opacity(baseFillOpacity))
            }
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.themePurple.opacity(accentFillOpacity))
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.themePurple.opacity(strokeOpacity), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stagedCount) staged review comments")
    }
}
