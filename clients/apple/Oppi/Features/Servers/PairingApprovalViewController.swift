import UIKit

/// The sheet that asks the owner of an already-paired device to approve a new device:
/// who is asking (a device symbol, its name, the server it wants to pair with), what is
/// known about the request (how, from where, when, and how long it stays open), and
/// Approve or Deny pinned under the scrolling list so they stay reachable at any detent or
/// text size. A failure shows above them. While a request is in flight the sheet cannot be
/// swiped away.
///
/// It is a mirror of `PairingApprovalController.presented`: `PairingApprovalPresentation`
/// shows it once per request and hands it each newer state through `apply(_:)` (busy,
/// error), so a state change never presents it again. Approve and Deny name the request
/// the sheet is showing (`Presented.id`), so a tap can only reach that request on its own
/// server; the controller authenticates the owner before anything is signed, and refuses a
/// request that has expired.
@MainActor
final class PairingApprovalViewController: SettingsListViewController<PairingApprovalViewController.Section, PairingApprovalViewController.Item> {
    enum Section: Hashable, Sendable { case header, facts }
    enum Item: Hashable, Sendable { case header, method, source, requested, expires }

    private(set) var presented: PairingApprovalController.Presented
    private let controller: PairingApprovalController
    private let root: AppRootEnvironment
    private let actionBar = PairingApprovalActionBar()
    private var expiryTimer: Timer?
    /// Advances every second so the countdown row is drawn again.
    private var tick = 0
    private var barHeight: CGFloat = 0

    init(presented: PairingApprovalController.Presented, controller: PairingApprovalController, root: AppRootEnvironment) {
        self.presented = presented
        self.controller = controller
        self.root = root
        super.init(
            title: String(localized: "Approve New Device?"),
            listIdentifier: "pairing.approval.prompt",
            scope: .server(presented.serverName)
        )
        traitOverrides.appRootEnvironment = root
    }

    isolated deinit {
        expiryTimer?.invalidate()
    }

    /// The newer state of the request on screen. Another request is not this sheet's to show.
    func apply(_ next: PairingApprovalController.Presented) {
        guard next.id == presented.id else { return }
        presented = next
        setNeedsUpdateProperties()
    }

    private var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(presented.approval.expiresAt) / 1_000) }
    private var isExpired: Bool { expiresAt <= Date() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
        NSLayoutConstraint.activate([
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        actionBar.onApprove = { [weak self] in self?.approve() }
        actionBar.onDeny = { [weak self] in self?.deny() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        expiryTimer?.invalidate()
        // In the common modes, so the countdown keeps ticking while the list scrolls.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.secondPassed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The list scrolls above the pinned actions: inset it by the bar (which already covers
        // the home indicator the list's own safe-area inset would count again).
        let height = actionBar.bounds.height
        guard height != barHeight else { return }
        barHeight = height
        let inset = max(0, height - view.safeAreaInsets.bottom)
        collectionView.contentInset.bottom = inset
        collectionView.verticalScrollIndicatorInsets.bottom = inset
    }

    override func updateProperties() {
        super.updateProperties()
        // Approve or Deny is in flight: the sheet stays until it settles.
        isModalInPresentation = presented.isBusy
        navigationController?.isModalInPresentation = presented.isBusy
        let palette = ThemeRuntimeState.currentPalette()
        actionBar.configure(
            isBusy: presented.isBusy,
            canApprove: !presented.isBusy && !isExpired,
            errorMessage: presented.errorMessage,
            palette: palette
        )
    }

    /// The countdown moves. At zero (by this device's clock; the server decides for itself)
    /// the controller drops the request and the sheet goes, unless an approval is in flight:
    /// that one settles first, and what it leaves behind is synced after.
    private func secondPassed() {
        tick += 1
        setNeedsUpdateProperties()
        if isExpired, !presented.isBusy {
            expiryTimer?.invalidate()
            expiryTimer = nil
            controller.sync(coordinator: root.coordinator)
        }
    }

    // MARK: - Actions

    private func approve() {
        let id = presented.id
        Task { [controller, coordinator = root.coordinator] in
            await controller.approve(presentedId: id, coordinator: coordinator)
        }
    }

    private func deny() {
        let id = presented.id
        Task { [controller, coordinator = root.coordinator] in
            await controller.deny(presentedId: id, coordinator: coordinator)
        }
    }

    // MARK: - Rows

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        var facts: [Item] = [.method]
        if PairingApprovalPromptFormatting.source(presented.approval.source) != nil { facts.append(.source) }
        facts.append(contentsOf: [.requested, .expires])
        return [
            SettingsSectionModel(.header, items: [.header]),
            SettingsSectionModel(.facts, items: facts),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .header:
            return AnyHashable([presented.approval.deviceName, presented.serverName])
        case .method:
            return AnyHashable(presented.approval.method)
        case .source:
            return AnyHashable(presented.approval.source ?? "")
        case .requested:
            return AnyHashable(presented.approval.requestedAt)
        case .expires:
            return AnyHashable(tick)
        }
    }

    private lazy var headerRow = UICollectionView.CellRegistration<PairingApprovalHeaderCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            deviceName: presented.approval.deviceName,
            serverName: presented.serverName,
            symbol: PairingApprovalPromptFormatting.deviceSymbol(presented.approval.deviceName)
        )
    }

    override func prepareRegistrations() {
        _ = headerRow
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .header: collectionView.dequeueConfiguredReusableCell(using: headerRow, for: indexPath, item: item)
        case .method, .source, .requested, .expires: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = content(.info)
        let approval = presented.approval
        switch item {
        case .method:
            content.text = String(localized: "Method")
            content.secondaryText = PairingApprovalPromptFormatting.method(approval.method)
            cell.accessibilityIdentifier = "pairing.approval.method"
        case .source:
            content.text = String(localized: "Source")
            content.secondaryText = PairingApprovalPromptFormatting.source(approval.source)
            cell.accessibilityIdentifier = "pairing.approval.source"
        case .requested:
            content.text = String(localized: "Requested")
            content.secondaryText = PairingApprovalPromptFormatting.timestamp(approval.requestedAt)
            cell.accessibilityIdentifier = "pairing.approval.requested"
        case .expires:
            content.text = String(localized: "Expires")
            content.secondaryText = PairingApprovalPromptFormatting.expiry(approval.expiresAt, now: Date())
            content.secondaryTextProperties.font = UIFont.scaled(.body, monospacedDigits: true)
            cell.accessibilityIdentifier = "pairing.approval.expiry"
        case .header:
            break
        }
        cell.contentConfiguration = content
    }
}

// MARK: - Header

/// The device symbol, its name, and "wants to pair with <server>", centered on the page (no card).
final class PairingApprovalHeaderCell: UICollectionViewListCell {
    private let symbolView = UIImageView()
    private let nameLabel = UILabel()
    private let serverLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // On the page itself, not on a card.
        configurationUpdateHandler = { cell, _ in cell.backgroundConfiguration = .clear() }
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 32)
        symbolView.contentMode = .scaleAspectFit
        symbolView.isAccessibilityElement = false
        nameLabel.font = UIFont.scaled(.title2, .bold)
        serverLabel.font = .preferredFont(forTextStyle: .subheadline)
        for label in [nameLabel, serverLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
        }
        nameLabel.accessibilityIdentifier = "pairing.approval.deviceName"
        serverLabel.accessibilityIdentifier = "pairing.approval.server"
        let stack = UIStackView(arrangedSubviews: [symbolView, nameLabel, serverLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        stack.setCustomSpacing(6, after: symbolView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(deviceName: String, serverName: String, symbol: String) {
        // The old prompt's tokens: themeBlue, themeFg, themeFgDim.
        let palette = ThemeRuntimeState.currentPalette()
        symbolView.image = UIImage(systemName: symbol)
        symbolView.tintColor = UIColor(palette.blue)
        nameLabel.text = deviceName
        nameLabel.textColor = UIColor(palette.fg)
        serverLabel.text = String(localized: "wants to pair with \(serverName)")
        serverLabel.textColor = UIColor(palette.fgDim)
    }
}

// MARK: - Actions

/// The error line, Approve, and Deny, on an opaque bar pinned to the bottom of the sheet.
final class PairingApprovalActionBar: UIView {
    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?

    private let errorLabel = UILabel()
    private let approveButton = UIButton(configuration: .filled())
    private let denyButton = UIButton(configuration: .bordered())
    private let hairline = UIView()
    private lazy var hairlineHeight = hairline.heightAnchor.constraint(equalToConstant: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "pairing.approval.error"
        approveButton.accessibilityIdentifier = "pairing.approval.approve"
        denyButton.accessibilityIdentifier = "pairing.approval.deny"
        approveButton.addAction(UIAction { [weak self] _ in self?.onApprove?() }, for: .touchUpInside)
        denyButton.addAction(UIAction { [weak self] _ in self?.onDeny?() }, for: .touchUpInside)
        // The error line sits 4 pt inside the buttons' edges.
        let errorRow = UIView()
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorRow.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: errorRow.topAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: errorRow.bottomAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: errorRow.leadingAnchor, constant: 4),
            errorLabel.trailingAnchor.constraint(equalTo: errorRow.trailingAnchor, constant: -4),
        ])
        let stack = UIStackView(arrangedSubviews: [errorRow, approveButton, denyButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairlineHeight,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // One device pixel.
        hairlineHeight.constant = 1 / max(traitCollection.displayScale, 1)
    }

    func configure(isBusy: Bool, canApprove: Bool, errorMessage: String?, palette: ThemePalette) {
        backgroundColor = UIColor(palette.bg)
        hairline.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.25)
        let message = errorMessage.flatMap { $0.isEmpty ? nil : $0 }
        errorLabel.text = message
        errorLabel.textColor = UIColor(palette.red)
        errorLabel.superview?.isHidden = message == nil

        var approve = UIButton.Configuration.filled()
        approve.title = String(localized: "Approve")
        approve.buttonSize = .large
        approve.cornerStyle = .capsule
        approve.baseBackgroundColor = UIColor(palette.blue)
        approve.showsActivityIndicator = isBusy
        approveButton.configuration = approve
        approveButton.isEnabled = canApprove

        var deny = UIButton.Configuration.tinted()
        deny.title = String(localized: "Deny")
        deny.buttonSize = .large
        deny.cornerStyle = .capsule
        deny.baseForegroundColor = UIColor(palette.red)
        deny.baseBackgroundColor = UIColor(palette.red)
        denyButton.configuration = deny
        denyButton.isEnabled = !isBusy
    }
}

// MARK: - Formatting

enum PairingApprovalPromptFormatting {
    static func deviceSymbol(_ deviceName: String) -> String {
        // Whole words only: "Camacho" and "Machine" are not Macs.
        let words = deviceName.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.contains("ipad") { return "ipad" }
        if words.contains("iphone") { return "iphone" }
        if words.contains("macbook") { return "laptopcomputer" }
        if words.contains("imac") { return "desktopcomputer" }
        if let mac = words.firstIndex(of: "mac"), mac + 1 < words.count {
            switch words[mac + 1] {
            case "mini": return "macmini"
            case "studio": return "macstudio"
            case "pro": return "macpro.gen3"
            default: break
            }
        }
        return "ipad.and.iphone"
    }

    static func method(_ raw: String) -> String {
        switch raw.lowercased() {
        case "invite": "Invite"
        case "tailscale": "Tailscale"
        case "custom": "Custom"
        default: raw
        }
    }

    static func source(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func timestamp(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    /// "In 1:30", "In 42s", and "Expired" once the request's time is up.
    static func expiry(_ ms: Int64, now: Date) -> String {
        let remaining = TimeInterval(ms) / 1_000 - now.timeIntervalSince1970
        guard remaining > 0 else { return String(localized: "Expired") }
        let seconds = Int(remaining.rounded(.down))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return "In \(minutes):\(String(format: "%02d", remainder))"
        }
        return "In \(remainder)s"
    }
}

// MARK: - Presentation

/// Presents the sheet for `PairingApprovalController.presented` over whatever the window
/// shows: a router modal slot on `anchor` (the app root), set from the controller's state in
/// the anchor's `updateProperties()`. The sheet is made once per request and refreshed in place
/// afterwards (`RouterScreen.liveController`), and swiping it away snoozes the request.
@MainActor
final class PairingApprovalPresentation {
    private let slot = RouterModalPresenter()
    private let controller: PairingApprovalController
    private let root: AppRootEnvironment

    init(controller: PairingApprovalController, root: AppRootEnvironment, anchor: UIViewController) {
        self.controller = controller
        self.root = root
        slot.anchor = anchor
    }

    /// Reads `controller.presented`, so the anchor's `updateProperties()` runs again when it changes.
    func update() {
        let presented = controller.presented
        let controller = controller
        let root = root
        slot.update(
            id: presented?.id,
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            root: root,
            clear: { controller.dismiss(snooze: true) },
            screen: {
                guard let presented else { return .controller({ UIViewController() }) }
                return .liveController({
                    PairingApprovalViewController(presented: presented, controller: controller, root: root)
                }, update: { screen in
                    screen.apply(presented)
                })
            }
        )
    }

    /// The anchor is in a window: a request that arrived earlier can present now.
    func anchorDidAppear() {
        slot.sync()
    }
}
