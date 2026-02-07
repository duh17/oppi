import SwiftUI

/// Chat input bar — rounded rectangle, NOT capsule (balloons on multi-line).
///
/// When agent is busy, shows Stop button instead of Send.
/// After 5s of stopping, shows Force Stop option.
struct ChatInputBar: View {
    @Binding var text: String
    let isBusy: Bool
    let isStopping: Bool
    let showForceStop: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if showForceStop {
                Button("Force Stop Session", role: .destructive) {
                    onForceStop()
                }
                .font(.caption)
                .foregroundStyle(.tokyoRed)
            }

            HStack(spacing: 12) {
                TextField(
                    isBusy ? "Agent is working…" : "Message…",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tokyoFg)
                .tint(.tokyoBlue)
                .disabled(isBusy)

                if isBusy {
                    Button(action: onStop) {
                        if isStopping {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.tokyoOrange)
                        } else {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.tokyoRed)
                        }
                    }
                    .disabled(isStopping)
                    .frame(width: 36, height: 36)
                } else {
                    let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? .tokyoBlue : .tokyoComment)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.tokyoBgHighlight, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.tokyoComment.opacity(0.35), lineWidth: 1)
            )
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
