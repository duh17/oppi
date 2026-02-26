import SwiftUI

// MARK: - Empty State

struct ChatEmptyState: View {
    var body: some View {
        Text("π")
            .font(.system(size: 48, design: .monospaced).weight(.bold))
            .foregroundStyle(.themePurple.opacity(0.5))
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
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(isStreaming ? .themeBlue : .themeFg)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if isStreaming {
                        Circle()
                            .fill(Color.themeBlue)
                            .frame(width: 6, height: 6)
                            .scaleEffect(pulse ? 1.0 : 0.72)
                            .opacity(pulse ? 1.0 : 0.55)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(isStreaming ? "Jump to latest streaming message" : "Jump to latest message")
        .accessibilityIdentifier("chat.jumpToBottom")
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
                .overlay(Color.themeComment.opacity(0.3))

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)

                Text("Session ended")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)

                if let session {
                    Spacer()

                    let totalTokens = session.tokens.input + session.tokens.output
                    if totalTokens > 0 {
                        Text(formatTokenCount(totalTokens) + " tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.themeComment)
                    }

                    if session.cost > 0 {
                        Text(String(format: "$%.3f", session.cost))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.themeComment)
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
                                .tint(.themeBg)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.subheadline)
                        }
                        Text(isResuming ? "Resuming…" : "Resume Session")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.themeGreen)
                    .foregroundStyle(Color.themeBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isResuming)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }
}
