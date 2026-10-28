import UIKit

/// Opaque App Lock cover. While locked it offers Unlock; while only
/// obscuring an inactive or backgrounded scene it shows the app identity.
///
/// `AppLockCoverController` puts one in its own window, which paints before
/// the app root exists. This controller therefore reads no app services: the
/// theme comes from `ThemeRuntimeState` (`UIColor.theme*`) and the lock state
/// from the `AppLockService` it is given.
@MainActor
final class AppLockCoverViewController: UIViewController {
    private let service: AppLockService
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let unlockButton = UIButton(configuration: .borderedProminent())

    init(service: AppLockService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Opaque from the first frame; `updateProperties()` keeps it current.
        view.backgroundColor = .themeBg
        view.accessibilityIdentifier = "appLock.cover"

        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 18
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),
        ])

        titleLabel.text = "Oppi"
        titleLabel.textAlignment = .center

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "appLock.status"

        for label in [titleLabel, statusLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        unlockButton.accessibilityIdentifier = "appLock.unlock"
        unlockButton.addAction(UIAction { [weak self] _ in
            guard let service = self?.service else { return }
            Task { await service.unlock() }
        }, for: .primaryActionTriggered)
        // SwiftUI's `minWidth: 180` sat on the label, inside the large
        // button's 20 pt sides.
        unlockButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, statusLabel, unlockButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(24, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The window is reused: the theme may have changed while it was hidden.
        setNeedsUpdateProperties()
    }

    override func updateProperties() {
        super.updateProperties()
        view.backgroundColor = .themeBg
        // Reading the trait registers the dependency, so a text-size change
        // re-runs this and re-resolves the scaled font.
        _ = traitCollection.preferredContentSizeCategory
        titleLabel.font = UIFont.scaled(.title2, .semibold)
        titleLabel.textColor = .themeFg
        statusLabel.textColor = .themeComment

        if let image = Self.appIcon {
            iconView.image = image
            iconView.tintColor = nil
            iconView.contentMode = .scaleAspectFit
        } else {
            iconView.image = UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            )
            iconView.tintColor = .themeBlue
            iconView.contentMode = .center
        }

        let locked = service.isLocked
        statusLabel.isHidden = !locked
        unlockButton.isHidden = !locked
        guard locked else { return }
        statusLabel.text = service.unlockFailed
            ? String(localized: "Couldn’t verify it’s you. Try again.")
            : String(localized: "Oppi is locked.")

        let method = service.method
        var configuration = unlockButton.configuration ?? .borderedProminent()
        configuration.title = method == .passcode
            ? String(localized: "Unlock")
            : String(localized: "Unlock with \(method.name)")
        configuration.image = UIImage(systemName: method.systemImage)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
        configuration.imagePadding = 8
        configuration.buttonSize = .large
        configuration.baseBackgroundColor = .themeBlue
        unlockButton.configuration = configuration
        unlockButton.isEnabled = !service.isAuthenticating
    }

    /// The installed app icon, or nil when the bundle has none.
    private static let appIcon: UIImage? = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        let names = (files ?? []).reversed() + [primary?["CFBundleIconName"] as? String, "AppIcon"].compactMap { $0 }
        return names.lazy.compactMap { UIImage(named: $0) }.first
    }()
}
