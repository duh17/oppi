import SwiftUI

/// Waiting chrome while another paired device approves this enrollment.
struct WaitingForPairingApprovalView: View {
    let expiresAt: Int64
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Waiting for approval on your other device")
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pairing.waiting.message")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.countdown(until: expiresAt, now: context.date))
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                    .accessibilityIdentifier("pairing.waiting.countdown")
            }
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("pairing.waiting.cancel")
            }
        }
        .padding()
        .accessibilityIdentifier("pairing.waiting")
    }

    static func countdown(until expiresAt: Int64, now: Date) -> String {
        let remaining = max(0, TimeInterval(expiresAt) / 1_000 - now.timeIntervalSince1970)
        let seconds = Int(remaining.rounded(.down))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return "Expires in \(minutes):\(String(format: "%02d", remainder))"
        }
        return "Expires in \(remainder)s"
    }
}
