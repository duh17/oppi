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
            }

            HStack(spacing: 12) {
                TextField(
                    isBusy ? "Agent is working…" : "Message…",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .disabled(isBusy)

                if isBusy {
                    Button(action: onStop) {
                        if isStopping {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(isStopping)
                    .frame(width: 36, height: 36)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
