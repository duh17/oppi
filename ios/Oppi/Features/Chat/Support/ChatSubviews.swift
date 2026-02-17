import SwiftUI

// MARK: - Empty State

struct ChatEmptyState: View {
    var body: some View {
        Text("π")
            .font(.system(size: 48, design: .monospaced).weight(.bold))
            .foregroundStyle(.tokyoPurple.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Jump to Bottom

struct JumpToBottomHintButton: View {
    let isStreaming: Bool
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: onTap) {
            Circle()
                .fill(Color.tokyoBgHighlight.opacity(0.95))
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .stroke((isStreaming ? Color.tokyoBlue : Color.tokyoComment).opacity(0.34), lineWidth: 1)
                )
                .overlay {
                    Image(systemName: "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isStreaming ? .tokyoBlue : .tokyoFg)
                }
                .overlay(alignment: .topTrailing) {
                    if isStreaming {
                        Circle()
                            .fill(Color.tokyoBlue)
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulse ? 1.0 : 0.72)
                            .opacity(pulse ? 1.0 : 0.55)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityLabel(isStreaming ? "Jump to latest streaming message" : "Jump to latest message")
        .onAppear {
            guard isStreaming else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
    }
}

// MARK: - Session Ended Footer

struct SessionEndedFooter: View {
    let session: Session?
    var isResuming: Bool = false
    var onResume: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            Divider()
                .overlay(Color.tokyoComment.opacity(0.3))

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.tokyoComment)

                Text("Session ended")
                    .font(.subheadline)
                    .foregroundStyle(.tokyoComment)

                if let session {
                    Spacer()

                    let totalTokens = session.tokens.input + session.tokens.output
                    if totalTokens > 0 {
                        Text(formatTokenCount(totalTokens) + " tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoComment)
                    }

                    if session.cost > 0 {
                        Text(String(format: "$%.3f", session.cost))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tokyoComment)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let onResume {
                Button {
                    onResume()
                } label: {
                    HStack(spacing: 6) {
                        if isResuming {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.tokyoBg)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.subheadline)
                        }
                        Text(isResuming ? "Resuming…" : "Resume Session")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.tokyoGreen)
                    .foregroundStyle(Color.tokyoBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isResuming)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }
}
