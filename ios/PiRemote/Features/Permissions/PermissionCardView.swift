import SwiftUI

/// The money feature — inline permission card in the chat timeline.
///
/// Shows what the agent wants to do, the risk level, and Allow/Deny buttons.
/// Uses `Text(timeoutAt, style: .timer)` for countdown.
/// Haptic feedback: .light for allow, .heavy for deny.
struct PermissionCardView: View {
    let request: PermissionRequest

    @Environment(ServerConnection.self) private var connection
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: risk badge + tool name
            HStack {
                RiskBadge(risk: request.risk)
                Spacer()
                // Countdown timer
                Text(request.timeoutAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Command display
            Text(request.displaySummary)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Reason
            Text(request.reason)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    resolve(.deny)
                } label: {
                    Text("Deny")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isResolving)

                // Critical risk: bordered (white bg) with red tint.
                // Others: prominent (filled) with blue tint.
                if request.risk == .critical {
                    Button {
                        resolve(.allow)
                    } label: {
                        Text("Allow")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(isResolving)
                } else {
                    Button {
                        resolve(.allow)
                    } label: {
                        Text("Allow")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isResolving)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.riskColor(request.risk).opacity(0.3), lineWidth: 1)
                )
        )
    }

    private func resolve(_ action: PermissionAction) {
        isResolving = true
        let feedback = UIImpactFeedbackGenerator(style: action == .allow ? .light : .heavy)
        feedback.impactOccurred()

        Task {
            try? await connection.respondToPermission(id: request.id, action: action)
        }
    }
}

// MARK: - Risk Badge

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Label(risk.label, systemImage: risk.systemImage)
            .font(.caption.bold())
            .foregroundStyle(Color.riskColor(risk))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.riskColor(risk).opacity(0.12))
            .clipShape(Capsule())
    }
}
