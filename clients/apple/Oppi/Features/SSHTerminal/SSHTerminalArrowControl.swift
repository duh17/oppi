import GhosttyVt
import SwiftUI
import UIKit

/// The held arrow is the default inside a 12pt dead zone. Outside it, the
/// dominant drag axis chooses direction and distance increases repeat speed.
/// This rule is independent of UIKit's recognizer and the terminal encoder.
struct SSHTerminalArrowRepeat: Equatable {
    let key: GhosttyKey
    let interval: TimeInterval

    static func plan(heldKey: GhosttyKey, translation: CGSize) -> Self {
        let distance = max(abs(translation.width), abs(translation.height))
        guard distance > 12 else { return .init(key: heldKey, interval: 0.12) }
        let key: GhosttyKey
        if abs(translation.width) >= abs(translation.height) {
            key = translation.width < 0 ? GHOSTTY_KEY_ARROW_LEFT : GHOSTTY_KEY_ARROW_RIGHT
        } else {
            key = translation.height < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN
        }
        return .init(key: key, interval: max(0.035, 0.12 / (1 + Double(distance - 12) / 48)))
    }

    static func isArrow(_ key: GhosttyKey) -> Bool {
        [GHOSTTY_KEY_ARROW_LEFT, GHOSTTY_KEY_ARROW_RIGHT, GHOSTTY_KEY_ARROW_UP, GHOSTTY_KEY_ARROW_DOWN].contains(key)
    }
}

/// Shared by the composer strip and UIKeyInput accessory. A normal tap sends
/// one key; recognition of a hold cancels that tap, then owns the drag until
/// release/cancellation. Horizontal scrolling remains available before a hold.
final class SSHTerminalArrowButton: UIButton {
    private let heldKey: GhosttyKey
    var sendArrow: (GhosttyKey) -> Bool
    private var origin = CGPoint.zero
    private var translation = CGSize.zero
    private var repeatTask: Task<Void, Never>?

    init(label: String, key: GhosttyKey, id: String, send: @escaping (GhosttyKey) -> Bool) {
        heldKey = key
        sendArrow = send
        super.init(frame: .zero)
        setTitle(label, for: .normal)
        setTitleColor(tintColor, for: .normal)
        titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        accessibilityIdentifier = id
        accessibilityLabel = "Move cursor \(label)"
        accessibilityHint = "Hold to repeat. Drag while held to change direction and speed."
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            _ = self.sendArrow(self.heldKey)
        }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
        NotificationCenter.default.addObserver(self, selector: #selector(stopRepeating),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        repeatTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func accessibilityActivate() -> Bool { sendArrow(heldKey) }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        // UIButton subclasses are custom buttons; unlike system buttons,
        // they do not automatically use the inherited terminal-bar tint.
        setTitleColor(tintColor, for: .normal)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeating() }
    }

    @objc func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    /// Avoid retaining the button across the sleep; detaching a bar stops it.
    private func repeatOnce() -> TimeInterval? {
        let plan = SSHTerminalArrowRepeat.plan(heldKey: heldKey, translation: translation)
        return sendArrow(plan.key) ? plan.interval : nil
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopRepeating()
            origin = gesture.location(in: window)
            translation = .zero
            repeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let interval = self?.repeatOnce() else { return }
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        case .changed:
            let point = gesture.location(in: window)
            translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        case .ended, .cancelled, .failed:
            stopRepeating()
        default: break
        }
    }
}

struct SSHTerminalArrowControl: UIViewRepresentable {
    let label: String
    let key: GhosttyKey
    let id: String
    let send: (GhosttyKey) -> Bool
    @Environment(\.theme) private var theme

    func makeUIView(context: Context) -> SSHTerminalArrowButton {
        SSHTerminalArrowButton(label: label, key: key, id: id, send: send)
    }

    func updateUIView(_ view: SSHTerminalArrowButton, context: Context) {
        view.sendArrow = send
        view.tintColor = UIColor(theme.text.primary)
    }

    static func dismantleUIView(_ view: SSHTerminalArrowButton, coordinator: ()) {
        view.stopRepeating()
    }
}
