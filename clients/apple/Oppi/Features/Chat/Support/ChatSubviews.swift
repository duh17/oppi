import SwiftUI

// MARK: - Empty State

struct ChatEmptyState: View {
    var sessionId: String = ""
    var agentId: String?
    var agentIcon: String?
    @State private var visible = false
    @State private var avatar = AssistantAvatar.current
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeID) private var themeID

    var body: some View {
        Group {
            switch AssistantIdentityPresentation.resolve(
                agentId: agentId,
                agentIcon: agentIcon
            ) {
            case .agent:
                AgentIconView(value: agentIcon, size: 64, frameSize: 112, isDecorative: false)
            case .globalAvatar:
                switch avatar {
                case .officialPi:
                    Image(
                        uiImage: AssistantAvatarRenderer.render(
                            avatar: avatar,
                            sessionId: sessionId,
                            size: 112,
                            themeID: themeID
                        )
                    )
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                case .golGrid:
                    SessionGridView(sessionId: sessionId)
                case .piText:
                    Text("π")
                        .font(.appHeroMono)
                        .foregroundStyle(.themePurple.opacity(0.5))
                case .emoji(let char):
                    Text(char)
                        .font(.system(size: 48))
                case .genmoji:
                    // Genmoji in empty state — fall back to grid
                    SessionGridView(sessionId: sessionId)
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .assistantAvatarDidChange)) { _ in
            avatar = AssistantAvatar.current
        }
        .task {
            // Delay appearance to avoid flash on existing sessions
            // that briefly have empty items while loading.
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(ThemeMotion.easeIn(duration: 0.3, reduceMotion: reduceMotion)) {
                visible = true
            }
        }
    }
}

// MARK: - Jump to Bottom

struct JumpToBottomHintButton: View {
    let isBusy: Bool
    let modelId: String?
    let onTap: () -> Void

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .animation(ThemeMotion.easeInOut(duration: 0.25, reduceMotion: reduceMotion), value: isBusy)
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
            .glassEffect(.regular, in: Circle())
            .overlay {
                Circle()
                    .stroke(providerColor.opacity(pulse ? 0.45 : 0.15), lineWidth: 1.5)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(ThemeColorContrast.foreground(for: providerColor))
                    .frame(width: 14, height: 14)
                    .background(providerColor, in: Circle())
                    .offset(x: 2, y: 2)
            }
            .transition(ThemeMotion.scaleFade(scale: 0.8, reduceMotion: reduceMotion))
    }

    // MARK: - Idle State (plain arrow)

    private var idleContent: some View {
        Image(systemName: "arrow.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(.themeFg)
            .frame(width: 34, height: 34)
            .glassEffect(.regular, in: Circle())
            .transition(ThemeMotion.scaleFade(scale: 0.8, reduceMotion: reduceMotion))
    }

    private func startPulse() {
        guard !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(ThemeMotion.pulse(reduceMotion: reduceMotion)) {
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
                        Text(SessionFormatting.tokenCount(totalTokens) + " tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.themeComment)
                    }

                    if session.cost > 0 {
                        Text(SessionFormatting.costString(session.cost))
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
                                .tint(.themeOnGreen)
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
                    .foregroundStyle(.themeOnGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isResuming)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }
}
