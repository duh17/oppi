import UIKit

@MainActor
enum FullScreenReviewCommentStashControl {
    static let accessibilityIdentifier = "fullscreen-code.review-comments.stash"
    static let accessibilityLabel = "Staged Comments"
    static let systemImage = "text.bubble.fill"
    static let appearanceDuration: TimeInterval = 0.2

    static func accessibilityValue(for count: Int) -> String {
        count == 1 ? "1 staged comment" : "\(count) staged comments"
    }

    static func bottomPadding(leadingAccessoryCount: Int = 0) -> CGFloat {
        FullScreenFloatingControlChrome.bottomPadding
            + CGFloat(max(0, leadingAccessoryCount)) * (
                FullScreenFloatingControlChrome.controlSize
                    + FullScreenFloatingControlChrome.stackSpacing
            )
    }

    #if DEBUG
    static var reduceMotionOverrideForTesting: Bool?
    #endif

    static var prefersReducedMotion: Bool {
        #if DEBUG
        if let override = reduceMotionOverrideForTesting {
            return override
        }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }
}

/// The one staged-comment button, for the reader and for content without it
/// (images, media, review diffs): bottom leading, shown while the stash holds
/// comments. It pops when it appears or its count grows (not under Reduce
/// Motion), and it and the reader's side-rail item open one comments sheet.
@MainActor
final class ReviewCommentStashFloatingButton {
    private(set) var button: UIButton?
    private let badge = UILabel()
    private var bottom: NSLayoutConstraint?
    private(set) var count = 0
    private weak var stash: (any ReviewCommentStashHandling)?
    private weak var presenter: UIViewController?
    private weak var sheet: UIViewController?

    /// The reader hides the floating button while its control sits on the side rail.
    var isHidden = false {
        didSet {
            button?.isHidden = isHidden
            badge.isHidden = isHidden
        }
    }

    init() {
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.accessibilityElementsHidden = true
        badge.isUserInteractionEnabled = false
    }

    /// Shows the button on `host` while `stash` holds comments, above
    /// `leadingAccessoryCount` bottom-leading controls. Reads the stash's
    /// `@Observable` count: call from `updateProperties()`.
    func update(
        on host: UIView,
        presenter: UIViewController,
        stash: (any ReviewCommentStashHandling)?,
        leadingAccessoryCount: Int,
        palette: ThemePalette
    ) {
        let count = stash?.stagedCount ?? 0
        guard let stash, count > 0 else {
            badge.removeFromSuperview()
            button?.removeFromSuperview()
            button = nil
            bottom = nil
            self.count = 0
            return
        }
        self.stash = stash
        self.presenter = presenter
        let isNew = button == nil
        let grew = !isNew && count > self.count
        let button: UIButton
        if let existing = self.button {
            button = existing
            FullScreenFloatingControlChrome.updateStandaloneButton(button, palette: palette)
        } else {
            button = install(on: host, palette: palette)
        }
        bottom?.constant = -FullScreenReviewCommentStashControl.bottomPadding(
            leadingAccessoryCount: leadingAccessoryCount
        )
        button.accessibilityValue = FullScreenReviewCommentStashControl.accessibilityValue(for: count)
        badge.text = count > 99 ? "99+" : "\(count)"
        badge.textColor = palette.ui.bgDark
        badge.backgroundColor = palette.ui.cyan
        bringToFront()
        if isNew || grew {
            pop(button, isNew: isNew)
        }
        self.count = count
    }

    func bringToFront() {
        guard let button, let host = button.superview else { return }
        host.bringSubviewToFront(button)
        host.bringSubviewToFront(badge)
    }

    /// The button and its badge in `view`'s coordinates while shown.
    func frame(in view: UIView) -> CGRect? {
        guard let button, !isHidden else { return nil }
        return button.convert(button.bounds, to: view).union(badge.convert(badge.bounds, to: view))
    }

    /// Replaces an open comments sheet with a fresh one; the sheet reads the
    /// stash itself, so edits and removals show while it is up.
    func openSheet() {
        guard let stash, let presenter else { return }
        // The router presents from the window's front-most controller, which is
        // not the presenter when it is embedded, so the sheet is tracked by its
        // own presentation rather than by `presentedViewController`.
        openedSheet?.dismiss(animated: false)
        let sheet = ReviewCommentStashViewController(stash: stash, onClose: { [weak self] in
            self?.closeSheet()
        })
        // A form sheet, like the composer's and Guided Control's stash sheets.
        Router.present(sheet, presentation: .sheet.inNavigation(), from: presenter)
        self.sheet = sheet
    }

    private var openedSheet: UIViewController? {
        guard let sheet, sheet.presentingViewController != nil else { return nil }
        return sheet
    }

    private func closeSheet() {
        if let openedSheet {
            Router.finish(openedSheet)
        }
        sheet = nil
    }

    private func install(on host: UIView, palette: ThemePalette) -> UIButton {
        let button = FullScreenFloatingControlChrome.makeStandaloneButton(
            systemImage: FullScreenReviewCommentStashControl.systemImage,
            accessibilityLabel: FullScreenReviewCommentStashControl.accessibilityLabel,
            accessibilityIdentifier: FullScreenReviewCommentStashControl.accessibilityIdentifier,
            palette: palette
        )
        button.clipsToBounds = false
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.isHidden = isHidden
        badge.isHidden = isHidden
        button.addAction(UIAction { [weak self] _ in self?.openSheet() }, for: .touchUpInside)
        host.addSubview(button)
        host.addSubview(badge)
        button.translatesAutoresizingMaskIntoConstraints = false
        let bottom = button.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(
                equalTo: host.safeAreaLayoutGuide.leadingAnchor,
                constant: FullScreenFloatingControlChrome.leadingPadding
            ),
            bottom,
            button.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            button.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -2),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        self.button = button
        self.bottom = bottom
        return button
    }

    private func pop(_ button: UIButton, isNew: Bool) {
        button.layer.removeAllAnimations()
        guard !FullScreenReviewCommentStashControl.prefersReducedMotion else {
            button.transform = .identity
            return
        }
        let duration = FullScreenReviewCommentStashControl.appearanceDuration
        if isNew {
            button.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: 0.72,
                initialSpringVelocity: 0.9,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                button.transform = .identity
            }
            return
        }
        UIView.animate(
            withDuration: duration / 2,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            button.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        } completion: { _ in
            UIView.animate(
                withDuration: duration / 2,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn]
            ) {
                button.transform = .identity
            }
        }
    }
}
