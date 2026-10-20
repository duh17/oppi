import SwiftUI
import UIKit

/// The one lock indicator for servers, workspaces, and sessions: `lock.fill`
/// while locked, `lock.open.fill` while unlocked for now. Place it right
/// after the item's name, before any value or status.
struct LockBadge: View {
    let state: ScopedLockState

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .locked:
            symbol("lock.fill")
                .accessibilityLabel("Locked")
                .accessibilityIdentifier("lockBadge.locked")
        case .unlocked:
            symbol("lock.open.fill")
                .accessibilityLabel("Unlocked")
                .accessibilityIdentifier("lockBadge.unlocked")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.themeComment)
            .fixedSize()
    }
}

/// Shows `content` only while `target` is reachable; otherwise a lock cover
/// with Unlock. Content is torn down while locked, so nothing from a locked
/// scope (streams, toolbars, titles) stays mounted behind it. This is what
/// enforces a lock when an unlock expires under an open screen or a route
/// reaches a destination without passing a navigation gate.
struct ScopedLockGate<Content: View, Accessory: View>: View {
    let target: ScopedLockTarget?
    let title: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    @State private var locks = ScopedLockService.shared

    init(
        target: ScopedLockTarget?,
        title: String,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.target = target
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        if let target, locks.isLocked(target) {
            ScopedLockCoverView(title: title, isAuthenticating: locks.isAuthenticating) {
                Task { _ = await locks.authorize(target) }
            } accessory: {
                accessory()
            }
        } else {
            content()
        }
    }
}

extension ScopedLockGate where Accessory == EmptyView {
    init(
        target: ScopedLockTarget?,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(target: target, title: title, accessory: { EmptyView() }, content: content)
    }
}

/// `ScopedLockGate`'s cover for UIKit screens: the screen shows this in place
/// of its content while `target` is locked, and tears its content down.
/// Unlock authorizes `target`. Draws what `ScopedLockCoverView` draws.
@MainActor
final class ScopedLockCoverViewController: UIViewController {
    /// The locked item's name.
    var coverTitle: String {
        didSet { if coverTitle != oldValue { setNeedsUpdateProperties() } }
    }

    private let target: ScopedLockTarget
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let lockedLabel = UILabel()
    private let unlockButton = UIButton(configuration: .borderedProminent())

    init(target: ScopedLockTarget, title: String) {
        self.target = target
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
            let target = target
            Task { _ = await ScopedLockService.shared.authorize(target) }
        }, for: .primaryActionTriggered)
        // SwiftUI's `minWidth: 180` sat on the label, inside the large
        // button's 20 pt sides.
        unlockButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let stack = UIStackView(arrangedSubviews: [symbol, titleLabel, lockedLabel, unlockButton])
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
        let palette = (HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()).palette
        view.backgroundColor = UIColor(palette.bg)
        symbol.tintColor = UIColor(palette.comment)
        titleLabel.text = coverTitle
        titleLabel.textColor = UIColor(palette.fg)
        lockedLabel.textColor = UIColor(palette.comment)

        let method = AppLockService.shared.method
        var configuration = unlockButton.configuration ?? .borderedProminent()
        configuration.title = method == .passcode
            ? String(localized: "Unlock")
            : String(localized: "Unlock with \(method.name)")
        configuration.image = UIImage(systemName: method.systemImage)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .medium)
        configuration.imagePadding = 8
        configuration.buttonSize = .large
        configuration.baseBackgroundColor = UIColor(palette.blue)
        unlockButton.configuration = configuration
        unlockButton.isEnabled = !ScopedLockService.shared.isAuthenticating
    }
}

/// Opaque stand-in for a locked server, workspace, or session.
struct ScopedLockCoverView<Accessory: View>: View {
    let title: String
    let isAuthenticating: Bool
    /// Overrides the Unlock button (a cover that cannot unlock closes instead).
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    let onUnlock: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    @State private var appLock = AppLockService.shared

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.themeBg)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Locked")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)

                Button(action: onUnlock) {
                    Label(actionTitle ?? unlockTitle, systemImage: actionSystemImage ?? appLock.method.systemImage)
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.themeBlue)
                .controlSize(.large)
                .disabled(isAuthenticating)
                .padding(.top, 6)
                .accessibilityIdentifier("scopedLock.unlock")

                accessory()
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scopedLock.cover")
    }

    private var unlockTitle: String {
        appLock.method == .passcode
            ? String(localized: "Unlock")
            : String(localized: "Unlock with \(appLock.method.name)")
    }
}
