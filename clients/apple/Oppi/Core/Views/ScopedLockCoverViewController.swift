import UIKit

/// The opaque stand-in for a locked server, workspace, or session: the screen
/// shows this in place of its content while `target` is locked, and tears its
/// content down, so nothing from a locked scope (streams, toolbars, titles)
/// stays mounted behind it. Unlock authorizes `target`.
///
/// A cover that cannot unlock (a reader with content but no lock origin)
/// closes instead: `init(title:closeTitle:onClose:)` replaces Unlock with that
/// action. `accessory` sits under the button (the server cover's Switch Server).
@MainActor
final class ScopedLockCoverViewController: UIViewController {
    private enum Action {
        case unlock(ScopedLockTarget)
        case close(title: String, handler: @MainActor () -> Void)
    }

    /// The locked item's name.
    var coverTitle: String {
        didSet { if coverTitle != oldValue { setNeedsUpdateProperties() } }
    }

    private let action: Action
    private let accessory: UIView?
    /// Reads the name each pass, so a rename shows while the cover is up.
    private let titleSource: (@MainActor () -> String)?
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let lockedLabel = UILabel()
    private let unlockButton = UIButton(configuration: .borderedProminent())

    init(target: ScopedLockTarget, title: String, accessory: UIView? = nil) {
        action = .unlock(target)
        self.accessory = accessory
        titleSource = nil
        coverTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    /// A cover whose name is read from observable state in `updateProperties()`.
    init(target: ScopedLockTarget, titleSource: @escaping @MainActor () -> String, accessory: UIView? = nil) {
        action = .unlock(target)
        self.accessory = accessory
        self.titleSource = titleSource
        coverTitle = titleSource()
        super.init(nibName: nil, bundle: nil)
    }

    init(title: String, closeTitle: String, onClose: @escaping @MainActor () -> Void) {
        action = .close(title: closeTitle, handler: onClose)
        accessory = nil
        titleSource = nil
        coverTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        symbol.image = UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        )
        symbol.isAccessibilityElement = false
        titleLabel.font = UIFont.scaled(.title3, .semibold)
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        lockedLabel.text = String(localized: "Locked")
        lockedLabel.font = .preferredFont(forTextStyle: .subheadline)
        for label in [titleLabel, lockedLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        unlockButton.accessibilityIdentifier = "scopedLock.unlock"
        unlockButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            switch action {
            case .unlock(let target):
                Task { _ = await ScopedLockService.shared.authorize(target) }
            case .close(_, let handler):
                handler()
            }
        }, for: .primaryActionTriggered)
        // The label's 180 pt minimum plus the large button's 20 pt sides.
        unlockButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let stack = UIStackView(arrangedSubviews: [symbol, titleLabel, lockedLabel, unlockButton])
        if let accessory { stack.addArrangedSubview(accessory) }
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(20, after: lockedLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
        view.accessibilityIdentifier = "scopedLock.cover"
    }

    override func updateProperties() {
        super.updateProperties()
        let palette = (AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
        view.backgroundColor = palette.ui.bg
        symbol.tintColor = palette.ui.comment
        titleLabel.text = titleSource?() ?? coverTitle
        titleLabel.textColor = palette.ui.fg
        lockedLabel.textColor = palette.ui.comment

        let method = AppLockService.shared.method
        var configuration = unlockButton.configuration ?? .borderedProminent()
        switch action {
        case .unlock:
            configuration.title = method == .passcode
                ? String(localized: "Unlock")
                : String(localized: "Unlock with \(method.name)")
            configuration.image = UIImage(systemName: method.systemImage)
        case .close(let title, _):
            configuration.title = title
            configuration.image = UIImage(systemName: "xmark")
        }
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
        configuration.imagePadding = 8
        configuration.buttonSize = .large
        configuration.baseBackgroundColor = palette.ui.blue
        unlockButton.configuration = configuration
        // Only Unlock waits for a prompt that is up; Close always leaves.
        switch action {
        case .unlock: unlockButton.isEnabled = !ScopedLockService.shared.isAuthenticating
        case .close: unlockButton.isEnabled = true
        }
    }
}
