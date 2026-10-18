import GhosttyVt
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
        accessibilityIdentifier = id
        accessibilityLabel = "Move cursor \(label)"
        accessibilityHint = "Hold to repeat. Drag while held to change direction and speed."
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
        applyChrome(title: label, color: .label)
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            _ = self.sendArrow(self.heldKey)
        }, for: .touchUpInside)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
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

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(
            dx: min(0, (bounds.width - 44) / 2),
            dy: min(0, (bounds.height - 44) / 2)
        ).contains(point)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyChrome(title: configuration?.title, color: tintColor ?? .label)
    }

    func applyChrome(title: String?, color: UIColor) {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.baseForegroundColor = color
        config.background.backgroundColor = .clear
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            return outgoing
        }
        config.title = title
        configuration = config
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

