import SwiftUI

struct ReviewCommentChip: View {
    let commentCount: Int
    let stagedCount: Int
    let onTap: () -> Void

    private let cornerRadius: CGFloat = 14
    private let baseFillOpacity = 0.86
    private let accentFillOpacity = 0.16
    private let strokeOpacity = 0.38

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themePurple)

                Text("Review Comments")
                    .font(.caption.weight(.semibold))

                Text("\(commentCount)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.themePurple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.themePurple.opacity(0.16), in: Capsule())

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }
            .foregroundStyle(.themeFg)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the review comments sheet.")
    }

    private var statusText: String {
        if stagedCount > 0 {
            return "\(stagedCount) staged"
        }
        return "Open list"
    }

    private var accessibilityLabel: String {
        let commentLabel = commentCount == 1 ? "comment" : "comments"
        if stagedCount > 0 {
            return "\(commentCount) review \(commentLabel), \(stagedCount) staged"
        }
        return "\(commentCount) review \(commentLabel)"
    }
}
