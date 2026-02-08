import SwiftUI

/// Chat input bar — rounded rectangle, NOT capsule (balloons on multi-line).
///
/// **Idle**: Send button routes through `onSend` (prompt).
/// **Busy**: TextField stays enabled for steering messages. Purple send
/// button appears when text is entered, routed through `onSend` (caller
/// decides prompt vs steer). Stop button always visible.
/// After 5s of stopping, shows Force Stop option.
///
/// Bash mode: when input starts with "$ ", the bar shows a green shell
/// prompt and routes the command through `onBash` instead of `onSend`.
/// Bash is disabled while busy — agent owns the workspace.
struct ChatInputBar: View {
    @Binding var text: String
    let isBusy: Bool
    let isStopping: Bool
    let showForceStop: Bool
    let isForceStopInFlight: Bool
    let onSend: () -> Void
    let onBash: (String) -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void

    /// Whether the current input is a bash command (starts with "$ ").
    private var isBashMode: Bool {
        text.hasPrefix("$ ")
    }

    /// The command text without the "$ " prefix.
    private var bashCommand: String {
        String(text.dropFirst(2))
    }

    private var canSend: Bool {
        if isBashMode {
            // Bash not allowed while busy — agent owns the workspace.
            if isBusy { return false }
            return !bashCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var accentColor: Color {
        isBashMode ? .tokyoGreen : .tokyoBlue
    }

    private var borderColor: Color {
        if isBashMode { return .tokyoGreen.opacity(0.5) }
        if isBusy { return .tokyoPurple.opacity(0.5) }
        return .tokyoComment.opacity(0.35)
    }

    /// Text binding for the input field.
    ///
    /// In bash mode, the raw backing text keeps the "$ " prefix so
    /// command routing still works, but the text field shows only the
    /// command body (without a duplicated prompt character).
    private var textFieldBinding: Binding<String> {
        Binding(
            get: {
                if text.hasPrefix("$ ") {
                    return String(text.dropFirst(2))
                }
                return text
            },
            set: { newValue in
                if text.hasPrefix("$ ") {
                    // Empty command exits bash mode so users can return
                    // to normal message input with backspace.
                    text = newValue.isEmpty ? "" : "$ " + newValue
                } else {
                    text = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            if showForceStop {
                Button(role: .destructive) {
                    onForceStop()
                } label: {
                    if isForceStopInFlight {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.tokyoRed)
                            Text("Stopping…")
                        }
                    } else {
                        Text("Force Stop Session")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tokyoRed)
                .disabled(isForceStopInFlight)
            }

            HStack(spacing: 12) {
                // Bash mode indicator
                if isBashMode {
                    Text("$")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundStyle(.tokyoGreen)
                }

                TextField(
                    isBusy ? "Steer agent…" : (isBashMode ? "command…" : "Message…"),
                    text: textFieldBinding,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tokyoFg)
                .tint(isBusy ? .tokyoPurple : accentColor)

                if isBusy {
                    // When busy: optional steer send + always-visible stop
                    if canSend {
                        Button(action: handleSend) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.tokyoPurple)
                        }
                    }

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
                    Button(action: handleSend) {
                        Image(systemName: isBashMode ? "terminal.fill" : "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? accentColor : .tokyoComment)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.tokyoBgHighlight, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func handleSend() {
        if isBashMode {
            let cmd = bashCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return }
            onBash(cmd)
        } else {
            onSend()
        }
    }
}
