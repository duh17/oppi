import UIKit

/// UIKit pieces every transient notice shares with `NoticeDismissTimer`: the
/// Dismiss control and the touch-hold that pauses the timer.
enum NoticeChrome {
    /// The most height a notice's message takes before it scrolls: a share of
    /// the window, never under `minimumMessageHeight`. At the largest Dynamic
    /// Type sizes a long message would otherwise grow past the screen and push
    /// Dismiss and Retry out of reach, so the message scrolls and the buttons
    /// stay outside the scroll area.
    static let messageWindowShare: CGFloat = 0.35
    static let minimumMessageHeight: CGFloat = 160

    static func messageMaxHeight(windowHeight: CGFloat) -> CGFloat {
        max(minimumMessageHeight, windowHeight * messageWindowShare)
    }

    /// `message` in a viewport capped by `messageMaxHeight(windowHeight:)`.
    @MainActor
    static func cappedMessage(_ message: UIView) -> NoticeMessageView {
        NoticeMessageView(message: message)
    }

    /// A 44 pt close button labelled "Dismiss". The caller sets the scoped
    /// accessibility identifier and the tint.
    @MainActor
    static func dismissButton(identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        )
        configuration.contentInsets = .zero
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = "Dismiss"
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return button
    }
}

/// Reports touch down and up on a notice without taking the touch from its
/// buttons, so the owner can pause the auto-dismiss timer while it is held.
@MainActor
final class NoticeTouchHold: NSObject, UIGestureRecognizerDelegate {
    private let onChange: (Bool) -> Void

    init(view: UIView, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(changed(_:)))
        hold.minimumPressDuration = 0
        hold.cancelsTouchesInView = false
        hold.delegate = self
        view.addGestureRecognizer(hold)
    }

    @objc private func changed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: onChange(true)
        case .ended, .cancelled, .failed: onChange(false)
        default: break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// A notice's message in a viewport that follows the window height
/// (`NoticeChrome.messageMaxHeight`) and flashes its scroll indicators when the
/// notice appears with more text than fits.
@MainActor
final class NoticeMessageView: UIView {
    private let viewport: CappedScrollView
    private var needsFlash = true

    init(message: UIView) {
        viewport = CappedScrollView(content: message, maxHeight: NoticeChrome.minimumMessageHeight)
        super.init(frame: .zero)
        viewport.translatesAutoresizingMaskIntoConstraints = false
        addSubview(viewport)
        NSLayoutConstraint.activate([
            viewport.topAnchor.constraint(equalTo: topAnchor),
            viewport.bottomAnchor.constraint(equalTo: bottomAnchor),
            viewport.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The notice appeared or its text changed: flash the indicators once it is
    /// laid out, if the text overflows.
    func flashWhenOverflowing() {
        needsFlash = true
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { flashWhenOverflowing() }
    }

    override func layoutSubviews() {
        if let height = window?.bounds.height {
            viewport.maxHeight = NoticeChrome.messageMaxHeight(windowHeight: height)
        }
        super.layoutSubviews()
        guard needsFlash, window != nil else { return }
        viewport.layoutIfNeeded()
        needsFlash = false
        if viewport.overflows { viewport.scrollView.flashScrollIndicators() }
    }
}
