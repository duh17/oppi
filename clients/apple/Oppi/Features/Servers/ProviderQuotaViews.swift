import UIKit

/// A usage bar: the remaining share filled from the leading edge, and a tick
/// where the fill would sit at an even pace (the share of the window still
/// ahead). Fill past the tick means usage is ahead of supply; short of it,
/// behind. A changed value slides there unless Reduce Motion is on.
final class ProviderQuotaBar: UIView {
    static let trackHeight: CGFloat = 6
    private static let tickSize = CGSize(width: 2.5, height: 12)

    private let track = UIView()
    private let fill = UIView()
    private let tick = UIView()
    private var fraction: Double = 0
    private var pace: Double?
    private var hasValue = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for view in [track, fill] {
            view.layer.cornerRadius = Self.trackHeight / 2
            view.layer.cornerCurve = .continuous
        }
        tick.layer.cornerRadius = Self.tickSize.width / 2
        [track, fill, tick].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.tickSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let trackY = (bounds.height - Self.trackHeight) / 2
        track.frame = CGRect(x: 0, y: trackY, width: width, height: Self.trackHeight)
        fill.frame = CGRect(x: 0, y: trackY, width: width * fraction, height: Self.trackHeight)
        layoutTick()
    }

    private func layoutTick() {
        guard let pace else { return }
        // Inset by half the tick so it stays inside the track at 0 and 1.
        let width = bounds.width
        let half = Self.tickSize.width / 2
        let x = min(max(width * pace, half), width - half) - half
        tick.frame = CGRect(origin: CGPoint(x: x, y: 0), size: Self.tickSize)
    }

    /// `fraction` and `pace` are 0...1; a nil `pace` hides the tick.
    func apply(fraction: Double, pace: Double?, color: UIColor, trackColor: UIColor, tickColor: UIColor) {
        let fraction = min(max(fraction, 0), 1)
        let animates = hasValue
            && window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && (fraction != self.fraction || pace != self.pace)
        hasValue = true
        self.fraction = fraction
        tick.isHidden = pace == nil
        // A tick that appears starts where it belongs instead of sliding in from 0.
        let tickAppears = self.pace == nil && pace != nil
        self.pace = pace
        track.backgroundColor = trackColor
        tick.backgroundColor = tickColor
        if tickAppears {
            UIView.performWithoutAnimation { layoutTick() }
        }
        setNeedsLayout()
        guard animates else {
            fill.backgroundColor = color
            return
        }
        UIView.animate(springDuration: 0.5, bounce: 0) {
            fill.backgroundColor = color
            layoutIfNeeded()
        }
    }
}

/// One usage window: title and share left, the bar with its even-pace tick,
/// then the pacing verdict and reset time on one line. One accessibility
/// element per window.
final class ProviderQuotaWindowView: UIView {
    private let titleLabel = UILabel()
    private let remainingLabel = UILabel()
    private let bar = ProviderQuotaBar()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .scaled(.caption1, monospacedDigits: true)
        titleLabel.adjustsFontForContentSizeCategory = true
        remainingLabel.font = .scaled(.caption1, .semibold, monospacedDigits: true)
        remainingLabel.adjustsFontForContentSizeCategory = true
        remainingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        remainingLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.font = .scaled(.caption2, monospacedDigits: true)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [titleLabel, remainingLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let stack = UIStackView(arrangedSubviews: [header, bar, detailLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(8, after: bar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        _ window: ProviderQuota.Window,
        providerId: String,
        providerName: String,
        palette: ThemePalette,
        now: Date
    ) {
        let tone = Self.tone(for: window, palette: palette)
        let remaining = "\(Int(window.remainingPercent.rounded()))% left"
        let pace = window.evenPaceRemainingFraction(at: now)
        titleLabel.text = window.title
        titleLabel.textColor = UIColor(palette.comment)
        remainingLabel.text = remaining
        remainingLabel.textColor = tone
        bar.apply(
            fraction: window.remainingPercent / 100,
            pace: pace,
            color: tone,
            trackColor: UIColor(palette.comment).withAlphaComponent(0.18),
            tickColor: UIColor(palette.fg)
        )

        let reset = window.resetDate.map { Self.resetLabel(for: $0, window: window, now: now) }
        let verdict = window.pacing.flatMap { $0.hasVerdict ? $0 : nil }
        detailLabel.text = [verdict?.compactLabel, reset].compactMap(\.self).joined(separator: " · ")
        detailLabel.textColor = UIColor(palette.comment)
        detailLabel.isHidden = detailLabel.text?.isEmpty ?? true

        accessibilityIdentifier = "provider.quota.\(providerId).\(window.key)"
        accessibilityLabel = "\(providerName) \(window.title) quota"
        accessibilityValue = [
            remaining,
            verdict?.accessibilityLabel,
            pace.map { "even pace \(Int(($0 * 100).rounded()))% left" },
            reset,
        ].compactMap(\.self).joined(separator: ", ")
    }

    /// The pacing verdict colors the bar, so a window that is low but has
    /// time on its side reads as fine. Without a verdict, the share left does.
    static func tone(for window: ProviderQuota.Window, palette: ThemePalette) -> UIColor {
        let byRemaining = ProviderQuota.badgeTone(for: window.remainingPercent)
        switch window.pacing?.status {
        case "plenty":
            return UIColor(palette.green)
        case "on_pace":
            return UIColor(palette.blue)
        case "conserve":
            return UIColor(byRemaining == .red ? palette.red : palette.orange)
        default:
            switch byRemaining {
            case .green: return UIColor(palette.green)
            case .orange: return UIColor(palette.orange)
            case .red: return UIColor(palette.red)
            }
        }
    }

    static func resetLabel(for date: Date, window: ProviderQuota.Window, now: Date) -> String {
        let secondsUntilReset = date.timeIntervalSince(now)
        let formatted: String = if secondsUntilReset <= 36 * 60 * 60, !window.includeWeekdayInReset {
            // Short windows (e.g. Codex 5h): time of day is enough.
            date.formatted(.dateTime.hour().minute())
        } else if secondsUntilReset <= 8 * 24 * 60 * 60 {
            // Within about a week: weekday and time.
            date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        } else {
            // Farther out (monthly): calendar day and time.
            date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return "resets \(formatted)"
    }
}

/// What a provider row's trailing control does.
enum ProviderRowAction {
    /// A sign-in, key save, or sign-out is running for this provider.
    case busy
    /// A borderless menu button (a connected provider's ⋯).
    case menu(UIMenu)
    /// A bordered button: one action, or a menu of connect choices.
    case connect(title: String, enabled: Bool, menu: UIMenu?, action: (() -> Void)?)
}

/// A provider in Model Providers: its mark, name, and credential status, the
/// trailing action, and for a connected provider its plan, usage windows,
/// credit, and quota error. The view updates in place across refreshes, so
/// the usage bars can slide to new values.
struct ProviderRowConfiguration: UIContentConfiguration {
    let provider: ProviderAuthProviderStatus
    let quota: ProviderQuota?
    let action: ProviderRowAction
    let themeID: ThemeID
    let now: Date

    func makeContentView() -> UIView & UIContentView {
        ProviderRowContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> Self { self }
}

private final class ProviderRowContentView: UIView, UIContentView {
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let actionButton = UIButton(type: .system)
    private let quotaStack = UIStackView()
    private let planPill = ControlStatusPill()
    private let footnoteLabel = UILabel()
    private let errorLabel = UILabel()
    private var windowViews: [String: ProviderQuotaWindowView] = [:]
    private var onAction: (() -> Void)?
    private var iconKey: (provider: String, theme: ThemeID)?
    /// The provider whose actions the button's menu carries. A reused view
    /// shows other providers, so their menus are never kept for it.
    private var menuProviderId: String?

    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: ProviderRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = true
        // Stacks that are not `.fill` aligned (the plan pill, a window's title
        // row) bound their height only from below, so self-sizing grew the row
        // without limit and UIKit threw. Pull it to its smallest height, as
        // `ControlViewContent` does.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = UILayoutPriority(UILayoutPriority.fittingSizeLevel.rawValue + 1)
        hug.isActive = true

        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [nameLabel, statusLabel])
        text.axis = .vertical
        text.spacing = 2

        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .primaryActionTriggered)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        let trailing = UIStackView(arrangedSubviews: [spinner, actionButton])
        trailing.axis = .horizontal
        trailing.alignment = .center

        planPill.setContentHuggingPriority(.required, for: .horizontal)
        let planRow = UIStackView(arrangedSubviews: [planPill, ControlRowViews.spacer()])
        planRow.axis = .horizontal
        planRow.alignment = .center
        planRow.accessibilityElements = [planPill]
        for label in [footnoteLabel, errorLabel] {
            label.font = .scaled(.caption1)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        quotaStack.axis = .vertical
        quotaStack.spacing = 12
        quotaStack.addArrangedSubview(planRow)
        quotaStack.addArrangedSubview(footnoteLabel)
        quotaStack.addArrangedSubview(errorLabel)
        quotaStack.setCustomSpacing(10, after: planRow)

        // The header lays out the icon, text, and action; the quota stack
        // under it collapses when hidden.
        let header = UIView()
        for view in [icon, text, trailing] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let iconSize: CGFloat = 18
        let textInset = iconSize + 12
        quotaStack.isLayoutMarginsRelativeArrangement = true
        quotaStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: textInset, bottom: 0, trailing: 0)
        let rows = UIStackView(arrangedSubviews: [header, quotaStack])
        rows.axis = .vertical
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        let margins = layoutMarginsGuide
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            rows.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
            // Centered on the name's first line, not on the whole text block.
            icon.centerYAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor, constant: -nameLabel.font.capHeight / 2),
            text.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: textInset),
            text.topAnchor.constraint(equalTo: header.topAnchor),
            text.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            trailing.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor),
            trailing.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func apply() {
        guard let configuration = configuration as? ProviderRowConfiguration else { return }
        let provider = configuration.provider
        let palette = configuration.themeID.palette

        if iconKey?.provider != provider.id || iconKey?.theme != configuration.themeID {
            iconKey = (provider.id, configuration.themeID)
            icon.image = ComposerProviderIconRenderer.image(
                provider: provider.id,
                size: 18,
                colors: SessionRowStyle.for(configuration.themeID).colors
            )
        }
        nameLabel.text = provider.name
        nameLabel.textColor = UIColor(palette.fg)
        statusLabel.text = Self.statusText(provider)
        statusLabel.textColor = UIColor(provider.authenticated ? palette.green : palette.comment)
        applyAction(configuration.action, palette: palette, providerId: provider.id, name: provider.name)
        applyQuota(configuration.quota, provider: provider, palette: palette, now: configuration.now)
    }

    private func applyAction(_ action: ProviderRowAction, palette: ThemePalette, providerId: String, name: String) {
        spinner.isHidden = true
        spinner.stopAnimating()
        actionButton.isHidden = false
        onAction = nil
        switch action {
        case .busy:
            actionButton.isHidden = true
            setMenu(nil, providerId: providerId)
            spinner.isHidden = false
            spinner.startAnimating()
        case .menu(let menu):
            var config = UIButton.Configuration.plain()
            config.image = .scaledSymbol("ellipsis.circle", style: .title3)
            config.baseForegroundColor = UIColor(palette.comment)
            // About 44 pt to tap; the margin stays the row's.
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 0)
            actionButton.configuration = config
            actionButton.isEnabled = true
            setMenu(menu, providerId: providerId)
            actionButton.showsMenuAsPrimaryAction = true
            actionButton.accessibilityLabel = "Manage \(name)"
            actionButton.accessibilityIdentifier = "server.modelProviders.\(providerId).manage"
        case .connect(let title, let enabled, let menu, let action):
            var config = UIButton.Configuration.bordered()
            config.title = title
            config.buttonSize = .small
            config.cornerStyle = .capsule
            config.baseForegroundColor = UIColor(palette.blue)
            if menu != nil {
                config.image = .scaledSymbol("chevron.down", style: .caption2, weight: .semibold)
                config.imagePlacement = .trailing
                config.imagePadding = 4
            }
            actionButton.configuration = config
            actionButton.isEnabled = enabled
            setMenu(menu, providerId: providerId)
            actionButton.showsMenuAsPrimaryAction = menu != nil
            onAction = action
            actionButton.accessibilityLabel = "\(title), \(name)"
            actionButton.accessibilityIdentifier = "server.modelProviders.\(providerId).connect"
        }
    }

    private func applyQuota(_ quota: ProviderQuota?, provider: ProviderAuthProviderStatus, palette: ThemePalette, now: Date) {
        quotaStack.isHidden = quota == nil
        guard let quota else { return }

        let plan = quota.planLabel
        planPill.superview?.isHidden = plan == nil
        if let plan {
            planPill.apply(text: plan, tone: UIColor(palette.blue), emphasis: .tinted, palette: palette)
            planPill.isAccessibilityElement = true
            planPill.accessibilityTraits = .staticText
            planPill.accessibilityLabel = "\(provider.name) plan \(plan)"
            planPill.accessibilityIdentifier = "provider.quota.\(quota.providerId).plan"
        }

        // Keyed by window, so a refreshed window keeps its view and its bar slides.
        let windows = quota.detailWindows
        let keys = Set(windows.map(\.key))
        for (key, view) in windowViews where !keys.contains(key) {
            view.removeFromSuperview()
            windowViews[key] = nil
        }
        for (offset, window) in windows.enumerated() {
            let view = windowViews[window.key] ?? ProviderQuotaWindowView()
            windowViews[window.key] = view
            // After the plan row, in window order.
            if quotaStack.arrangedSubviews.firstIndex(of: view) != offset + 1 {
                quotaStack.insertArrangedSubview(view, at: offset + 1)
            }
            view.apply(window, providerId: quota.providerId, providerName: provider.name, palette: palette, now: now)
        }

        let credit = quota.creditLines
        footnoteLabel.text = credit.joined(separator: "\n")
        footnoteLabel.textColor = UIColor(palette.comment)
        footnoteLabel.isHidden = credit.isEmpty
        errorLabel.text = quota.error
        errorLabel.textColor = UIColor(palette.comment)
        errorLabel.isHidden = quota.error == nil
        errorLabel.accessibilityLabel = quota.error.map { "\(provider.name) quota error: \($0)" }
    }

    static func statusText(_ provider: ProviderAuthProviderStatus) -> String {
        guard provider.authenticated else { return "Not connected" }
        switch provider.credentialType {
        case .apiKey:
            return provider.maskedKey.map { "API key · \($0)" } ?? "API key connected"
        case .oauth:
            if let expiry = provider.expiresAtDate {
                return "OAuth · expires \(expiry.formatted(date: .abbreviated, time: .shortened))"
            }
            return "OAuth connected"
        case .none:
            return "Connected"
        }
    }

    /// A usage refresh redraws the row, and replacing an open menu would close
    /// it. The menu stays only for the same provider with the same choices:
    /// its actions capture that provider.
    private func setMenu(_ menu: UIMenu?, providerId: String) {
        guard menu == nil || menuProviderId != providerId || !Self.sameChoices(actionButton.menu, menu) else { return }
        actionButton.menu = menu
        menuProviderId = menu == nil ? nil : providerId
    }

    /// Same titles and enablement: for one provider, the actions do the same thing.
    static func sameChoices(_ lhs: UIMenu?, _ rhs: UIMenu?) -> Bool {
        func choices(_ menu: UIMenu?) -> [String]? {
            menu?.children.map { element in
                let action = element as? UIAction
                return "\(element.title)|\(action?.attributes.rawValue ?? 0)"
            }
        }
        return choices(lhs) == choices(rhs)
    }
}

extension ProviderQuota {
    /// Credit and prepaid balance, worded as `oppi quota` prints them.
    var creditLines: [String] {
        var lines: [String] = []
        if let credits {
            if credits.unlimited {
                lines.append("Credits: unlimited")
            } else if let balance = credits.balance {
                lines.append("Credits: \(balance)")
            }
        }
        if let prepaidBalanceCents {
            let dollars = (Double(prepaidBalanceCents) / 100).formatted(.currency(code: "USD"))
            lines.append("Prepaid balance: \(dollars)")
        }
        return lines
    }
}
