import SwiftUI

// MARK: - Empty State

struct ChatEmptyState: View {
    var body: some View {
        Text("π")
            .font(.appHeroMono)
            .foregroundStyle(.themePurple.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Jump to Bottom

struct JumpToBottomHintButton: View {
    let isBusy: Bool
    let modelId: String?
    let onTap: () -> Void

    @State private var pulse = false

    private var providerColor: Color {
        ProviderColor.color(for: modelId, palette: ThemeRuntimeState.currentPalette())
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isBusy {
                    busyContent
                } else {
                    idleContent
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isBusy)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(isBusy ? "Agent working, jump to bottom" : "Jump to latest message")
        .accessibilityIdentifier("chat.jumpToBottom")
        .onAppear {
            if isBusy { startPulse() }
        }
        .onChange(of: isBusy) { _, busy in
            if busy {
                startPulse()
            } else {
                pulse = false
            }
        }
    }

    // MARK: - Busy State (spinner + arrow badge)

    private var busyContent: some View {
        WorkingSpinnerView(tintColor: providerColor)
            .frame(width: 20, height: 20)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(providerColor.opacity(pulse ? 0.45 : 0.15), lineWidth: 1.5)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.themeBg)
                    .frame(width: 14, height: 14)
                    .background(providerColor, in: Circle())
                    .offset(x: 2, y: 2)
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    // MARK: - Idle State (plain arrow)

    private var idleContent: some View {
        Image(systemName: "arrow.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(.themeFg)
            .frame(width: 34, height: 34)
            .background(.ultraThinMaterial, in: Circle())
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
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
