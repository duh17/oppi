import SwiftUI
import UIKit

/// Waiting chrome while another paired device approves this enrollment.
/// `PairingApprovalWaitingView` draws the same chrome, with the same
/// identifiers, on UIKit screens.
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

/// UIKit waiting chrome while another paired device approves this enrollment:
/// a spinner, the message, a countdown, and Cancel when `onCancel` is set.
/// The countdown ticks from `show(expiresAt:)` while the view is visible in a
/// window.
@MainActor
final class PairingApprovalWaitingView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let countdownLabel = UILabel()
    private let cancelButton = UIButton(configuration: .plain())
    private var expiresAt: Int64 = 0
    private var timer: Timer?

    var onCancel: (() -> Void)? {
        didSet { cancelButton.isHidden = onCancel == nil }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "pairing.waiting"

        spinner.startAnimating()

        messageLabel.text = String(localized: "Waiting for approval on your other device")
        messageLabel.font = .scaled(.headline, .semibold)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.accessibilityIdentifier = "pairing.waiting.message"

        countdownLabel.font = .scaled(.subheadline, monospacedDigits: true)
        countdownLabel.adjustsFontForContentSizeCategory = true
        countdownLabel.textAlignment = .center
        countdownLabel.accessibilityIdentifier = "pairing.waiting.countdown"

        cancelButton.configuration?.title = String(localized: "Cancel")
        cancelButton.accessibilityIdentifier = "pairing.waiting.cancel"
        cancelButton.isHidden = true
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, countdownLabel, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The approval's expiry, in epoch milliseconds.
    func show(expiresAt: Int64) {
        self.expiresAt = expiresAt
        tick()
        updateTimer()
    }

    override var isHidden: Bool {
        didSet { updateTimer() }
    }

    func apply(colors: ComposerThemeColors) {
        spinner.color = colors.comment
        messageLabel.textColor = colors.fg
        countdownLabel.textColor = colors.comment
        cancelButton.configuration?.baseForegroundColor = colors.blue
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTimer()
    }

    /// Ticks only between `show(expiresAt:)` and being hidden or removed.
    private func updateTimer() {
        let ticks = expiresAt > 0 && !isHidden && window != nil
        guard ticks != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard ticks else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        countdownLabel.text = WaitingForPairingApprovalView.countdown(until: expiresAt, now: Date())
    }
}
