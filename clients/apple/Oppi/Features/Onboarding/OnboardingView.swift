import OSLog
// SwiftUI only for `ComputerSetupSheet`, which presents the SwiftUI Tailscale
// screen until that screen moves to UIKit.
import SwiftUI
import UIKit

private let pairingLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "Pairing")

/// Mode for the onboarding flow.
enum OnboardingMode {
    /// First-time setup or re-launch with no servers.
    case initial
    /// Adding an additional server from Settings.
    case addServer
}

/// Idle pairing choices on first-run and Add Server onboarding.
/// Nearby Mac pairing is omitted until the Mac app can advertise.
enum OnboardingIdlePairingCTA: Equatable {
    /// Tailscale, then a machine, then install and pair: no terminal needed.
    case setUpComputer
    /// The QR code `oppi pair` shows on a computer that already runs the server.
    case scanQR
    /// A pasted pairing link, or host and pairing token.
    case enterManually

    /// Scanning needs a camera, so without one the screen offers set-up and
    /// manual entry only.
    static func visible(canScan: Bool) -> [Self] {
        canScan ? [.setUpComputer, .scanQR, .enterManually] : [.setUpComputer, .enterManually]
    }

    var title: String {
        switch self {
        case .setUpComputer: String(localized: "Set Up a Computer")
        case .scanQR: String(localized: "Scan QR Code")
        case .enterManually: String(localized: "Enter manually")
        }
    }

    var systemImage: String? {
        switch self {
        case .setUpComputer: "desktopcomputer"
        case .scanQR: "qrcode.viewfinder"
        case .enterManually: nil
        }
    }

    var accessibilityHint: String? {
        switch self {
        case .setUpComputer:
            String(localized: "Finds your Mac or Linux computer through Tailscale and sets up the Oppi server on it")
        case .scanQR, .enterManually:
            nil
        }
    }

    /// `onboarding.tailscale` predates the Set Up a Computer label; UI tests use it.
    var accessibilityIdentifier: String {
        switch self {
        case .setUpComputer: "onboarding.tailscale"
        case .scanQR: "onboarding.scanQR"
        case .enterManually: "onboarding.manual"
        }
    }

    enum Prominence {
        case primary
        case bordered
        /// A text button under the others.
        case link
    }

    var prominence: Prominence {
        switch self {
        case .setUpComputer: .primary
        case .scanQR: .bordered
        case .enterManually: .link
        }
    }
}

/// A failed pairing as onboarding shows it: what happened, and the next step
/// its recovery allows.
struct OnboardingPairingFailure: Equatable {
    let message: String
    let recovery: PairingRecovery

    init(message: String, recovery: PairingRecovery) {
        self.message = message
        self.recovery = recovery
    }

    @MainActor
    init(_ error: Error, host: String) {
        let failure = InviteBootstrapService.pairingFailure(for: error, host: host)
        self.init(message: failure.message, recovery: failure.recovery)
    }

    var title: String {
        recovery == .reachability
            ? String(localized: "Can’t Reach the Server")
            : String(localized: "Couldn’t Pair")
    }

    /// Try Again sends the same code again, so it shows only while the code
    /// is unspent.
    var offersRetry: Bool {
        recovery == .reachability || recovery == .retry
    }

    func hint(deviceModel: String) -> String? {
        switch recovery {
        case .newCode:
            String(localized: "On your computer, run oppi pair for a new code, or choose Set Up a Computer.")
        case .reachability:
            String(localized: "Check that this \(deviceModel) and the computer are on the same network, or that Tailscale is on for both. Then try again.")
        case .serverSetup, .retry:
            nil
        }
    }
}

// MARK: - Screen

/// The first-run and Add Server screen: what Oppi is, then the ways to pair a
/// server. First run embeds it as the app root's content; Add Server
/// presents it as a sheet, which closes itself after pairing or Cancel.
@MainActor
final class OnboardingViewController: UIViewController, RouterModalContainer {
    var onDismissed: (() -> Void)?

    private enum Phase: Equatable {
        case idle
        case pairing
        case waitingForApproval(expiresAt: Int64)
        case connected
        case failed(OnboardingPairingFailure)
    }

    private let root: AppRootEnvironment
    private let mode: OnboardingMode
    private let canScan: Bool
    /// "iPhone" or "iPad", for copy that names this device.
    private let deviceModel = UIDevice.current.model

    private var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            setNeedsUpdateProperties()
            announcesPhase = true
        }
    }
    private var announcesPhase = false
    private var pairingTask: Task<Void, Never>?
    private var pairingGeneration: UInt64 = 0
    /// The last attempt's credentials, for Try Again.
    private var lastCredentials: ServerCredentials?
    private weak var computerSetupScreen: UIViewController?

    private let scrollView = UIScrollView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let taglineLabel = UILabel()
    private let prerequisiteLabel = UILabel()
    private let pairingSpinner = UIActivityIndicatorView(style: .medium)
    private let pairingLabel = UILabel()
    /// The spinner and "Pairing…", centered at their own width.
    private let pairingSlot = UIView()
    private let waitingView = PairingApprovalWaitingView()
    private let connectedLabel = UILabel()
    private let failureCard = OnboardingFailureCard()
    private let choicesStack = UIStackView()
    private var choiceButtons: [(cta: OnboardingIdlePairingCTA, button: UIButton)] = []
    private let helpButton = UIButton(configuration: .plain())
    private let leaveButton = UIButton(configuration: .plain())

    /// `canScan` defaults to whether this device can scan; screenshot previews
    /// pass true, since the simulator has no camera.
    init(root: AppRootEnvironment, mode: OnboardingMode = .initial, canScan: Bool? = nil) {
        self.root = root
        self.mode = mode
        self.canScan = canScan ?? QRScannerViewController.isAvailable
        super.init(nibName: nil, bundle: nil)
        // Router presentations from here find the root before this screen is in a window.
        traitOverrides.appRootEnvironment = root
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHierarchy()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.setNeedsUpdateProperties()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme or the active
        // connection's credentials change.
        overrideUserInterfaceStyle = root.themeStore.userInterfaceStyle
        let palette = root.themeStore.activeThemeID.palette
        let colors = ComposerThemeColors(palette: palette)
        view.backgroundColor = colors.bg

        titleLabel.textColor = colors.fg
        taglineLabel.textColor = colors.fg
        prerequisiteLabel.textColor = colors.comment
        pairingSpinner.color = colors.comment
        pairingLabel.textColor = colors.fg
        connectedLabel.attributedText = Self.symbolText(
            String(localized: "Connected"),
            symbol: "checkmark.circle.fill",
            color: colors.green,
            font: .scaled(.headline, .semibold)
        )
        waitingView.apply(colors: colors)
        for (cta, button) in choiceButtons {
            button.configuration = Self.configuration(for: cta, colors: colors)
        }
        helpButton.configuration = Self.linkConfiguration(
            String(localized: "How to set up the server"),
            color: colors.blue
        )
        applyLeaveButton(colors: colors)
        applyPhase(colors: colors)
    }

    // MARK: Layout

    private func buildHierarchy() {
        iconView.image = InstalledAppIcon.image
            ?? UIImage(systemName: "bubble.left.and.text.bubble.right.fill")
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 22
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
        ])

        titleLabel.text = "Oppi"
        titleLabel.font = .scaled(.largeTitle, .bold)
        titleLabel.accessibilityTraits.insert(.header)

        taglineLabel.text = String(
            localized: "Run AI coding agents on your own computer. Follow and approve their work from your \(deviceModel)."
        )
        taglineLabel.font = .scaled(.body)
        taglineLabel.accessibilityIdentifier = "onboarding.tagline"

        prerequisiteLabel.text = String(
            localized: "The agents run in the Oppi server on your Mac or Linux computer, not on this \(deviceModel). Set it up from here, or install it yourself and scan the pairing code it shows."
        )
        prerequisiteLabel.font = .scaled(.footnote)
        prerequisiteLabel.accessibilityIdentifier = "onboarding.prerequisite"
        prerequisiteLabel.isHidden = mode != .initial

        for label in [titleLabel, taglineLabel, prerequisiteLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }

        let hero = UIStackView(arrangedSubviews: [iconView, titleLabel, taglineLabel, prerequisiteLabel])
        hero.axis = .vertical
        hero.alignment = .center
        hero.spacing = 12
        hero.setCustomSpacing(16, after: iconView)
        hero.setCustomSpacing(16, after: taglineLabel)

        pairingLabel.text = String(localized: "Pairing…")
        pairingLabel.font = .scaled(.body)
        pairingLabel.adjustsFontForContentSizeCategory = true
        pairingLabel.accessibilityIdentifier = "onboarding.pairing"
        pairingSpinner.startAnimating()
        let pairingRow = UIStackView(arrangedSubviews: [pairingSpinner, pairingLabel])
        pairingRow.axis = .horizontal
        pairingRow.spacing = 8
        pairingRow.alignment = .center
        pairingRow.translatesAutoresizingMaskIntoConstraints = false
        pairingSlot.addSubview(pairingRow)
        NSLayoutConstraint.activate([
            pairingRow.topAnchor.constraint(equalTo: pairingSlot.topAnchor),
            pairingRow.bottomAnchor.constraint(equalTo: pairingSlot.bottomAnchor),
            pairingRow.centerXAnchor.constraint(equalTo: pairingSlot.centerXAnchor),
            pairingRow.leadingAnchor.constraint(greaterThanOrEqualTo: pairingSlot.leadingAnchor),
        ])

        connectedLabel.adjustsFontForContentSizeCategory = true
        connectedLabel.textAlignment = .center
        connectedLabel.accessibilityIdentifier = "onboarding.connected"

        waitingView.onCancel = { [weak self] in self?.cancelPairing() }
        failureCard.onRetry = { [weak self] in self?.retryPairing() }

        choicesStack.axis = .vertical
        choicesStack.spacing = 12
        for cta in OnboardingIdlePairingCTA.visible(canScan: canScan) {
            let button = UIButton(configuration: .plain())
            button.accessibilityIdentifier = cta.accessibilityIdentifier
            button.accessibilityHint = cta.accessibilityHint
            button.addAction(UIAction { [weak self] _ in self?.activate(cta) }, for: .primaryActionTriggered)
            choicesStack.addArrangedSubview(button)
            choiceButtons.append((cta, button))
        }

        helpButton.accessibilityIdentifier = "onboarding.setupHelp"
        helpButton.accessibilityHint = String(localized: "Opens the public server setup and pairing guide")
        helpButton.addAction(UIAction { [weak self] _ in self?.openSetupGuide() }, for: .primaryActionTriggered)
        leaveButton.addAction(UIAction { [weak self] _ in self?.leave() }, for: .primaryActionTriggered)

        let footer = UIStackView(arrangedSubviews: [helpButton, leaveButton])
        footer.axis = .vertical
        footer.alignment = .center
        footer.spacing = 4

        let content = UIStackView(arrangedSubviews: [
            hero, pairingSlot, waitingView, connectedLabel, failureCard, choicesStack, footer,
        ])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 24
        content.setCustomSpacing(32, after: hero)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        scrollView.addSubview(container)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)

        let safe = view.safeAreaLayoutGuide
        let frame = scrollView.frameLayoutGuide
        let fillHeight = container.heightAnchor.constraint(equalTo: frame.heightAnchor)
        fillHeight.priority = .defaultLow
        let centered = content.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        centered.priority = .defaultHigh
        let preferredWidth = content.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safe.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            container.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            container.widthAnchor.constraint(equalTo: frame.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            fillHeight,

            // Centered while it fits; scrolls when Dynamic Type makes it taller.
            content.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
            centered,
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            // One column, capped so iPad does not grow wide buttons.
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            content.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48),
            preferredWidth,
        ])
    }

    private func applyPhase(colors: ComposerThemeColors) {
        var showsChoices = false
        var shown: UIView?
        pairingSlot.isHidden = true
        waitingView.isHidden = true
        connectedLabel.isHidden = true
        failureCard.isHidden = true
        switch phase {
        case .idle:
            showsChoices = true
        case .pairing:
            pairingSlot.isHidden = false
            shown = pairingLabel
        case .waitingForApproval(let expiresAt):
            waitingView.show(expiresAt: expiresAt)
            waitingView.isHidden = false
            shown = waitingView
        case .connected:
            connectedLabel.isHidden = false
            shown = connectedLabel
        case .failed(let failure):
            failureCard.configure(failure, deviceModel: deviceModel, colors: colors)
            failureCard.isHidden = false
            showsChoices = true
            shown = failureCard.titleLabel
        }
        choicesStack.isHidden = !showsChoices
        if announcesPhase {
            announcesPhase = false
            if let shown {
                UIAccessibility.post(notification: .layoutChanged, argument: shown)
            }
        }
    }

    private func applyLeaveButton(colors: ComposerThemeColors) {
        let title: String?
        switch mode {
        case .addServer:
            title = String(localized: "Cancel")
            leaveButton.accessibilityIdentifier = "onboarding.cancel"
        case .initial:
            // Reached again from a server that still works (a deep link, or a
            // removed server's replacement): offer the way back.
            title = root.coordinator.activeConnection.credentials != nil
                ? String(localized: "Back to current server")
                : nil
            leaveButton.accessibilityIdentifier = "onboarding.backToServer"
        }
        // Once paired the screen is closing; there is nothing to leave.
        leaveButton.isHidden = title == nil || phase == .connected
        if let title {
            leaveButton.configuration = Self.linkConfiguration(title, color: colors.blue)
        }
    }

    private static func configuration(
        for cta: OnboardingIdlePairingCTA,
        colors: ComposerThemeColors
    ) -> UIButton.Configuration {
        var configuration: UIButton.Configuration
        let font: UIFont
        switch cta.prominence {
        case .primary:
            configuration = .borderedProminent()
            configuration.baseBackgroundColor = colors.blue
            configuration.baseForegroundColor = ComposerColorContrast.foreground(
                for: colors.blue,
                fg: colors.fg,
                bg: colors.bg
            )
            font = .scaled(.headline, .semibold)
        case .bordered:
            configuration = .bordered()
            configuration.baseForegroundColor = colors.blue
            font = .scaled(.headline, .semibold)
        case .link:
            configuration = .plain()
            configuration.baseForegroundColor = colors.blue
            font = .scaled(.body)
        }
        configuration.title = cta.title
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        configuration.titleLineBreakMode = .byWordWrapping
        if let symbol = cta.systemImage {
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePadding = 8
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font)
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        return configuration
    }

    private static func linkConfiguration(_ title: String, color: UIColor) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = color
        configuration.titleLineBreakMode = .byWordWrapping
        let font = UIFont.scaled(.footnote)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        return configuration
    }

    fileprivate static func symbolText(_ text: String, symbol: String, color: UIColor, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(color, renderingMode: .alwaysOriginal) {
            result.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            result.append(NSAttributedString(string: " "))
        }
        result.append(NSAttributedString(string: text))
        result.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Actions

    private func activate(_ cta: OnboardingIdlePairingCTA) {
        switch cta {
        case .setUpComputer: presentComputerSetup()
        case .scanQR: presentScanner()
        case .enterManually: presentManualEntry()
        }
    }

    private func presentScanner() {
        let scanner = QRScannerViewController { [weak self] scanner, credentials in
            Router.finish(scanner)
            self?.startPairing(credentials)
        }
        Router.present(scanner, presentation: .sheet.inNavigation(), from: self, theme: root.themeStore)
    }

    private func presentManualEntry() {
        let entry = ManualEntryViewController(root: root, deviceModel: deviceModel) { [weak self] entry, credentials in
            Router.finish(entry)
            self?.startPairing(credentials)
        }
        Router.present(entry, presentation: .sheet.inNavigation(), from: self, theme: root.themeStore)
    }

    /// Computer set-up already saved the server it paired. Show the same
    /// success beat as QR and manual pairing, then leave onboarding.
    fileprivate func completeComputerSetup() {
        if let computerSetupScreen {
            Router.finish(computerSetupScreen)
        }
        phase = .connected
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.leaveOnboardingAfterPair()
        }
    }

    private func openSetupGuide() {
        root.opener.open(AppOpenRequest(url: AppSupportLinks.setupURL, origin: .inAppHyperlink))
    }

    private func leave() {
        switch mode {
        case .initial:
            phase = .idle
            root.navigation.showOnboarding = false
        case .addServer:
            finishAddServer()
        }
    }

    private func leaveOnboardingAfterPair() {
        switch mode {
        case .initial:
            root.navigation.shouldGuideWorkspaceCreation = true
            root.navigation.selectedTab = .workspaces
            root.navigation.showOnboarding = false
        case .addServer:
            finishAddServer()
        }
    }

    /// Add Server is presented; a screenshot preview embeds it instead.
    private func finishAddServer() {
        guard presentingViewController != nil else { return }
        Router.finish(self)
    }

    // MARK: Pairing

    private func startPairing(_ credentials: ServerCredentials) {
        lastCredentials = credentials
        pairingTask?.cancel()
        pairingGeneration &+= 1
        let generation = pairingGeneration
        pairingTask = Task { [weak self] in
            await self?.pair(credentials, generation: generation)
        }
    }

    private func retryPairing() {
        guard let lastCredentials else { return }
        startPairing(lastCredentials)
    }

    /// Cancel during the approval wait. The server took the code when the
    /// wait began, so another attempt needs a new one.
    private func cancelPairing() {
        pairingGeneration &+= 1
        pairingTask?.cancel()
        pairingTask = nil
        phase = .failed(OnboardingPairingFailure(
            message: String(localized: "Pairing cancelled."),
            recovery: .newCode
        ))
    }

    private func pair(_ credentials: ServerCredentials, generation: UInt64) async {
        phase = .pairing
        let coordinator = root.coordinator
        do {
            let enrollment = try await InviteBootstrapService.enroll(
                credentials: credentials,
                serverStore: coordinator.serverStore,
                coordinator: coordinator,
                onWaitingForApproval: { [weak self] expiresAt in
                    guard let self, generation == self.pairingGeneration else { return }
                    self.phase = expiresAt.map { .waitingForApproval(expiresAt: $0) } ?? .pairing
                },
                confirmTrust: { reason in
                    await BiometricService.shared.authenticate(reason: reason)
                }
            )
            // A newer attempt only takes over the UI; this pairing is saved.
            guard generation == pairingGeneration, !Task.isCancelled else { return }
            // A newer picker selection owns navigation, even if this pairing succeeded.
            guard enrollment.selected else { return }

            // Load sessions into the connection that was just selected, not
            // the one that was active when onboarding opened.
            let selectedConnection = coordinator.activeConnection
            selectedConnection.sessionStore.markSyncStarted()
            selectedConnection.sessionStore.applyServerSnapshot(enrollment.sessions)
            selectedConnection.sessionStore.markSyncSucceeded()

            phase = .connected
            // Short delay then transition. Guided workspace creation still
            // waits for the workspace refresh, not this session snapshot.
            try? await Task.sleep(for: .milliseconds(600))
            guard generation == pairingGeneration else { return }
            leaveOnboardingAfterPair()
        } catch {
            guard generation == pairingGeneration else { return }
            coordinator.activeConnection.sessionStore.markSyncFailed()
            phase = .failed(OnboardingPairingFailure(error, host: credentials.host))
        }
    }
}

// MARK: - Set Up a Computer

extension OnboardingViewController {
    /// The Tailscale screen finds the person's computer and pairs it. It is
    /// SwiftUI until its UIKit conversion; then this function presents that
    /// controller with the same Cancel and `onPaired`.
    fileprivate func presentComputerSetup() {
        computerSetupScreen = Router.present(root: root, presentation: .sheet.inNavigation(), from: self) { [weak self] in
            ComputerSetupSheet { self?.completeComputerSetup() }
        }
    }
}

/// The Tailscale screen with Cancel, as onboarding presents it.
private struct ComputerSetupSheet: View {
    let onPaired: () -> Void
    @Environment(\.screenNavigator) private var navigator

    var body: some View {
        // Its machine rows and Check a Machine push through the navigator.
        TailnetSettingsView(onPaired: onPaired)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { navigator.finish() }
                }
            }
    }
}

// MARK: - Failure card

/// The failed attempt: what happened, what to do next, and Try Again when the
/// same code can still work. The pairing choices stay below it.
@MainActor
private final class OnboardingFailureCard: UIView {
    let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let hintLabel = UILabel()
    private let retryButton = UIButton(configuration: .bordered())
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "onboarding.failure"
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous

        titleLabel.accessibilityIdentifier = "onboarding.failure.title"
        titleLabel.accessibilityTraits.insert(.header)
        messageLabel.accessibilityIdentifier = "onboarding.failure.message"
        hintLabel.accessibilityIdentifier = "onboarding.failure.hint"
        for label in [titleLabel, messageLabel, hintLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }

        retryButton.accessibilityIdentifier = "onboarding.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, hintLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ failure: OnboardingPairingFailure, deviceModel: String, colors: ComposerThemeColors) {
        backgroundColor = colors.bgHighlight
        titleLabel.attributedText = OnboardingViewController.symbolText(
            failure.title,
            symbol: failure.recovery == .reachability ? "wifi.exclamationmark" : "xmark.circle.fill",
            color: colors.red,
            font: .scaled(.headline, .semibold)
        )
        messageLabel.text = failure.message
        messageLabel.font = .scaled(.subheadline)
        messageLabel.textColor = colors.fg

        let hint = failure.hint(deviceModel: deviceModel)
        hintLabel.isHidden = hint == nil
        hintLabel.attributedText = hint.map { Self.hintText($0, color: colors.comment) }

        retryButton.isHidden = !failure.offersRetry
        var retry = UIButton.Configuration.bordered()
        retry.title = String(localized: "Try Again")
        retry.baseForegroundColor = colors.blue
        retry.cornerStyle = .capsule
        retryButton.configuration = retry
    }

    /// The hint with the `oppi pair` command in the monospaced font.
    private static func hintText(_ hint: String, color: UIColor) -> NSAttributedString {
        let font = UIFont.scaled(.footnote)
        let text = NSMutableAttributedString(string: hint, attributes: [.font: font, .foregroundColor: color])
        let command = (hint as NSString).range(of: "oppi pair")
        if command.location != NSNotFound {
            text.addAttribute(.font, value: UIFont.scaledMonospaced(.footnote), range: command)
        }
        return text
    }
}

/// The installed app icon from the bundle, or nil when it has none.
private enum InstalledAppIcon {
    @MainActor static let image: UIImage? = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        let names = (files ?? []).reversed() + [primary?["CFBundleIconName"] as? String, "AppIcon"].compactMap { $0 }
        return names.lazy.compactMap { UIImage(named: $0) }.first
    }()
}

// MARK: - Manual Entry

/// What manual entry turns into pairing credentials.
enum ManualPairingEntry {
    /// A pasted pairing link (`oppi://connect…`), a QR payload, or the whole
    /// `oppi pair --json` output, whose `inviteURL` is the link.
    static func credentials(fromPasted text: String) -> ServerCredentials? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let credentials = ServerCredentials.decodeInviteURLString(trimmed)
            ?? ServerCredentials.decodeInvitePayload(trimmed) {
            return credentials
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = object["inviteURL"] as? String else { return nil }
        return ServerCredentials.decodeInviteURLString(link)
    }

    /// The host fields: the host, port, and `pairingToken` from
    /// `oppi pair --json`. A host typed as a URL gives its own port. Without a
    /// name the server is named after its host.
    static func credentials(host: String, port: String, pairingToken: String, name: String) -> ServerCredentials? {
        var hostText = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var portNumber = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
        if hostText.contains("://"), let url = URLComponents(string: hostText), let urlHost = url.host {
            hostText = urlHost
            portNumber = url.port ?? portNumber
        }
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostText.isEmpty, let portNumber, (1...65_535).contains(portNumber), !token.isEmpty else {
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerCredentials(
            host: hostText,
            port: portNumber,
            token: "",
            name: trimmedName.isEmpty ? hostText : trimmedName,
            scheme: .https,
            pairingToken: token
        )
    }
}

/// Pairs from a pasted pairing link, or from a host and pairing token. The
/// link carries the server's identity and certificate; the host fields carry
/// neither, so they work only with a certificate iOS already trusts.
/// Presented in a navigation sheet; Connect hands the credentials back.
@MainActor
final class ManualEntryViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable { case link, hostToggle, host }
    private enum Item: Hashable { case link, invalidLink, hostToggle, host, port, token, name }

    private let root: AppRootEnvironment
    private let deviceModel: String
    private let onConnect: (ManualEntryViewController, ServerCredentials) -> Void
    private var linkText = ""
    private var host = ""
    private var port = "7749"
    private var token = ""
    private var name = ""
    private var showsHostFields = false

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var lastThemeID: ThemeID?

    init(
        root: AppRootEnvironment,
        deviceModel: String,
        onConnect: @escaping (ManualEntryViewController, ServerCredentials) -> Void
    ) {
        self.root = root
        self.deviceModel = deviceModel
        self.onConnect = onConnect
        var list = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        list.headerMode = .supplementary
        list.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: list)
        )
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Connect Manually")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Router.finish(self)
            }
        )
        let connect = UIBarButtonItem(
            title: String(localized: "Connect"),
            primaryAction: UIAction { [weak self] _ in self?.connect() }
        )
        connect.style = .prominent
        connect.accessibilityIdentifier = "onboarding.manual.connect"
        navigationItem.rightBarButtonItem = connect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A pasted link wins; the host fields count only while they are shown.
    private var credentials: ServerCredentials? {
        if !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ManualPairingEntry.credentials(fromPasted: linkText)
        }
        guard showsHostFields else { return nil }
        return ManualPairingEntry.credentials(host: host, port: port, pairingToken: token, name: name)
    }

    private var linkIsInvalid: Bool {
        !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ManualPairingEntry.credentials(fromPasted: linkText) == nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        SSHTerminalSettingsList.pin(collectionView, in: view)
        installDataSource()
        applySnapshot()
        updateConnectItem()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the theme changes.
        let themeID = root.themeStore.activeThemeID
        guard lastThemeID != themeID else { return }
        lastThemeID = themeID
        SSHTerminalSettingsList.applyTheme(to: view, collectionView: collectionView, themeID: themeID)
        if var snapshot = dataSource?.snapshot() {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource?.apply(snapshot, animatingDifferences: false)
        }
    }

    private func installDataSource() {
        let field = UICollectionView.CellRegistration<SSHTerminalTextFieldCell, Item> { [weak self] cell, _, item in
            self?.configureField(cell, item: item)
        }
        let action = UICollectionView.CellRegistration<SSHTerminalActionCell, Item> { [weak self] cell, _, _ in
            self?.configureHostToggle(cell)
        }
        let notice = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "This is not an Oppi pairing link.")
            content.textProperties.color = UIColor(root.themeStore.activeThemeID.palette.red)
            content.textProperties.font = .scaled(.footnote)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "onboarding.manual.invalidLink"
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.headerTitle(at: indexPath)
            cell.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerText(at: indexPath)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .hostToggle:
                collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: item)
            case .invalidLink:
                collectionView.dequeueConfiguredReusableCell(using: notice, for: indexPath, item: item)
            case .link, .host, .port, .token, .name:
                collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
            }
        }
        dataSource?.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func configureField(_ cell: SSHTerminalTextFieldCell, item: Item) {
        let palette = root.themeStore.activeThemeID.palette
        let fg = UIColor(palette.fg)
        let onReturn: () -> Void = { [weak self] in self?.connect() }
        switch item {
        case .link:
            cell.configure(
                text: linkText,
                placeholder: "oppi://connect?…",
                identifier: "onboarding.manual.link",
                keyboard: .URL,
                textColor: fg,
                returnKey: .go,
                onReturn: onReturn
            ) { [weak self] in
                self?.linkText = $0
                self?.inputChanged()
            }
        case .host:
            cell.configure(
                text: host,
                placeholder: "my-mac.tail1234.ts.net",
                identifier: "onboarding.manual.host",
                label: String(localized: "Host"),
                keyboard: .URL,
                textColor: fg,
                labelColor: fg,
                returnKey: .go,
                onReturn: onReturn
            ) { [weak self] in
                self?.host = $0
                self?.inputChanged()
            }
        case .port:
            cell.configure(
                text: port,
                placeholder: "7749",
                identifier: "onboarding.manual.port",
                label: String(localized: "Port"),
                keyboard: .numberPad,
                textColor: fg,
                labelColor: fg
            ) { [weak self] in
                self?.port = $0
                self?.inputChanged()
            }
        case .token:
            cell.configure(
                text: token,
                placeholder: "pt_…",
                identifier: "onboarding.manual.token",
                label: String(localized: "Pairing Token"),
                contentType: .oneTimeCode,
                monospaced: true,
                textColor: fg,
                labelColor: fg,
                returnKey: .go,
                onReturn: onReturn
            ) { [weak self] in
                self?.token = $0
                self?.inputChanged()
            }
        case .name:
            cell.configure(
                text: name,
                placeholder: String(localized: "Optional"),
                identifier: "onboarding.manual.name",
                label: String(localized: "Name"),
                autocapitalization: .words,
                textColor: fg,
                labelColor: fg,
                returnKey: .go,
                onReturn: onReturn
            ) { [weak self] in
                self?.name = $0
                self?.inputChanged()
            }
        case .invalidLink, .hostToggle:
            break
        }
        // The row's title label is decorative; the field speaks its purpose.
        cell.textField.accessibilityLabel = switch item {
        case .link: String(localized: "Pairing Link")
        case .host: String(localized: "Host")
        case .port: String(localized: "Port")
        case .token: String(localized: "Pairing Token")
        case .name: String(localized: "Name")
        case .invalidLink, .hostToggle: nil
        }
    }

    private func configureHostToggle(_ cell: SSHTerminalActionCell) {
        let palette = root.themeStore.activeThemeID.palette
        cell.configure(
            title: String(localized: "Use Host and Pairing Token"),
            identifier: "onboarding.manual.hostFields",
            color: UIColor(palette.blue),
            image: showsHostFields ? "chevron.down" : "chevron.right",
            action: { [weak self] in self?.toggleHostFields() }
        )
        cell.button.accessibilityValue = showsHostFields
            ? String(localized: "Shown")
            : String(localized: "Hidden")
    }

    private func headerTitle(at indexPath: IndexPath) -> String? {
        switch dataSource?.sectionIdentifier(for: indexPath.section) {
        case .link: String(localized: "Pairing Link")
        case .host: String(localized: "Host and Pairing Token")
        case .hostToggle, nil: nil
        }
    }

    private func footerText(at indexPath: IndexPath) -> String? {
        switch dataSource?.sectionIdentifier(for: indexPath.section) {
        case .link:
            String(localized: "Paste the link that oppi pair shows on your computer. It starts with oppi://connect, works once, and expires after 90 seconds unless you set --ttl.\n\nAway from the computer’s network, this \(deviceModel) reaches it only through Tailscale or a public HTTPS address.")
        case .host:
            String(localized: "Use the host, port, and pairingToken from oppi pair --json. This works only when the server has a certificate iOS trusts: a Tailscale name (.ts.net) or a public HTTPS address. A server with its own certificate on your local network needs the pairing link, which carries that certificate.")
        case .hostToggle, nil:
            nil
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.link])
        snapshot.appendItems(linkIsInvalid ? [.link, .invalidLink] : [.link], toSection: .link)
        snapshot.appendSections([.hostToggle])
        snapshot.appendItems([.hostToggle], toSection: .hostToggle)
        if showsHostFields {
            snapshot.appendSections([.host])
            snapshot.appendItems([.host, .port, .token, .name], toSection: .host)
        }
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    /// Typing never reconfigures a field, so it keeps focus and selection.
    private func inputChanged() {
        if dataSource?.snapshot().itemIdentifiers.contains(.invalidLink) != linkIsInvalid {
            applySnapshot()
        }
        updateConnectItem()
    }

    private func toggleHostFields() {
        showsHostFields.toggle()
        applySnapshot()
        if var snapshot = dataSource?.snapshot() {
            snapshot.reconfigureItems([.hostToggle])
            dataSource?.apply(snapshot, animatingDifferences: false)
        }
        updateConnectItem()
    }

    private func updateConnectItem() {
        navigationItem.rightBarButtonItem?.isEnabled = credentials != nil
    }

    private func connect() {
        guard let credentials else { return }
        view.endEditing(true)
        onConnect(self, credentials)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource?.itemIdentifier(for: indexPath) == .hostToggle
    }

    /// Selecting the row runs the same action as its button.
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource?.itemIdentifier(for: indexPath) == .hostToggle {
            toggleHostFields()
        }
    }
}

// MARK: - Invite bootstrap

struct InviteBootstrapResult {
    let effectiveCredentials: ServerCredentials
    let sessions: [Session]
}

/// A pairing the server committed and Oppi saved.
struct InviteEnrollment {
    let name: String
    /// False when a newer pairing attempt or server pick took the selection.
    let selected: Bool
    /// The sessions read while pairing, for the caller to show when selected.
    let sessions: [Session]
}

/// What the person can do after pairing failed.
enum PairingRecovery: Equatable, Sendable {
    /// The pairing code was used, expired, or refused, or it may have been
    /// used (its response was lost). Only a new code helps.
    case newCode
    /// The server did not answer before the code was sent, so the same code
    /// still works once the server is reachable.
    case reachability
    /// The address or certificate cannot work from this device. The server's
    /// setup or the way of pairing must change first.
    case serverSetup
    /// Nothing reached the server (the trust prompt was declined). The same
    /// code works again.
    case retry
}

/// A pairing failure: the message to show and what the person can do next.
struct InviteBootstrapError: LocalizedError, Equatable {
    let message: String
    let recovery: PairingRecovery

    var errorDescription: String? { message }
}

protocol InviteBootstrapAPI: Sendable {
    func startPairDevice(
        pairingToken: String,
        deviceName: String?,
        devicePublicKey: DevicePublicKey
    ) async throws -> PairDeviceStart
    func pollPairingApprovalStatus(
        approvalId: String,
        pendingToken: String
    ) async throws -> PairingApprovalPoll
    func health() async throws -> Bool
    func me() async throws -> User
    func serverInfo() async throws -> ServerInfo
    func listSessionsFromWorkspaces(recentDays: Int) async throws -> [Session]
    func revokeAuthDevice(id: String) async throws
}

extension APIClient: InviteBootstrapAPI {}

@MainActor
enum InviteBootstrapService {
    static func credentials(from inviteURL: URL) -> ServerCredentials? {
        ServerCredentials.decodeInviteURL(inviteURL)
    }

    static func validateAndBootstrap(
        credentials: ServerCredentials,
        existingCredentials: ServerCredentials?,
        confirmTrust: @MainActor (String) async -> Bool,
        apiFactory: @MainActor (URL, String, String?) -> any InviteBootstrapAPI = { baseURL, token, tlsCertFingerprint in
            APIClient(baseURL: baseURL, token: token, tlsCertFingerprint: tlsCertFingerprint)
        },
        deviceName: String? = PairingDeviceName.current(),
        deviceKeyProvider: @MainActor () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        /// The approval wait's expiry while another device must approve, then `nil`
        /// once the server enrolled this device: the wait and its Cancel end there.
        onWaitingForApproval: (@MainActor (Int64?) -> Void)? = nil,
        /// The wait between approval polls; tests skip the real two-second interval.
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> InviteBootstrapResult {
        guard credentials.resolvedScheme == .https, let baseURL = credentials.baseURL else {
            throw InviteBootstrapError(
                message: "HTTPS is required. Ask the server owner for an HTTPS/Tailscale invite.",
                recovery: .serverSetup
            )
        }
        if credentials.normalizedTLSCertFingerprint != nil,
           !ServerTLSTrustPolicy.allowsPinnedLeaf(forHost: credentials.host) {
            throw InviteBootstrapError(
                message: "\(credentials.host) uses a self-signed certificate, which iOS does not allow on Tailscale names. "
                    + "On the server, run `oppi config set tls.mode tailscale`, restart, and create a new invite.",
                recovery: .serverSetup
            )
        }
        let existingFingerprint = existingCredentials?.normalizedServerFingerprint
        let inviteFingerprint = credentials.normalizedServerFingerprint
        if (existingFingerprint != nil && inviteFingerprint != nil && existingFingerprint != inviteFingerprint)
            || inviteFingerprint != nil {
            let reason = existingFingerprint != nil && existingFingerprint != inviteFingerprint
                ? "Server identity changed for \(displayTarget(credentials)). Confirm trust reset."
                : "Trust \(displayTarget(credentials)) (\(shortFingerprint(inviteFingerprint ?? "unknown")))"
            guard await confirmTrust(reason) else {
                throw InviteBootstrapError(message: "Trust confirmation cancelled", recovery: .retry)
            }
        }

        let api: any InviteBootstrapAPI
        if let pairingToken = credentials.pairingToken, !pairingToken.isEmpty {
            let bootstrapAPI = apiFactory(baseURL, credentials.token, credentials.normalizedTLSCertFingerprint)
            try await requireReachable(bootstrapAPI, host: displayTarget(credentials))
            let pairResult: PairDeviceResponse
            var didRequireApproval = false
            do {
                let start = try await bootstrapAPI.startPairDevice(
                    pairingToken: pairingToken,
                    deviceName: PairingDeviceName.resolved(deviceName),
                    devicePublicKey: try deviceKeyProvider().publicKey
                )
                if case .approvalRequired(let required) = start {
                    didRequireApproval = true
                    onWaitingForApproval?(required.expiresAt)
                }
                pairResult = try await PairingEnrollment.complete(
                    start: start,
                    poll: { approvalId, pendingToken in
                        try await bootstrapAPI.pollPairingApprovalStatus(
                            approvalId: approvalId,
                            pendingToken: pendingToken
                        )
                    },
                    onWaiting: { expiresAt in
                        onWaitingForApproval?(expiresAt)
                    },
                    sleep: sleep
                )
                if Task.isCancelled {
                    if let deviceCredential = pairResult.deviceCredential {
                        revokeAbandonedEnrollment(
                            deviceId: deviceCredential.deviceId,
                            using: apiFactory(
                                baseURL,
                                deviceCredential.accessToken,
                                credentials.normalizedTLSCertFingerprint
                            )
                        )
                    }
                    throw PairingEnrollment.Failure.cancelled
                }
                if didRequireApproval { onWaitingForApproval?(nil) }
            } catch {
                throw pairingMutationFailure(
                    for: error,
                    host: displayTarget(credentials),
                    didRequireApproval: didRequireApproval
                )
            }
            guard let deviceCredential = pairResult.deviceCredential else {
                throw InviteBootstrapError(
                    message: "Server returned an invalid pairing response. Request a fresh invite and try again.",
                    recovery: .newCode
                )
            }
            var effective = credentials.withDeviceCredential(deviceCredential)
            let pairedAPI = apiFactory(baseURL, deviceCredential.accessToken, credentials.normalizedTLSCertFingerprint)
            if effective.normalizedServerFingerprint == nil {
                effective = try await confirmServerIdentity(
                    of: effective,
                    existing: existingCredentials,
                    deviceId: deviceCredential.deviceId,
                    using: pairedAPI,
                    confirmTrust: confirmTrust
                )
            }
            let sessions: [Session]
            do {
                sessions = try await bootstrapSessions(using: pairedAPI)
            } catch let error as InviteBootstrapError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The server took the code, so another attempt needs a new one.
                throw InviteBootstrapError(
                    message: pairingFailure(for: error, host: displayTarget(credentials)).message,
                    recovery: .newCode
                )
            }
            return InviteBootstrapResult(effectiveCredentials: effective, sessions: sessions)
        }

        api = apiFactory(baseURL, credentials.effectiveAccessToken, credentials.normalizedTLSCertFingerprint)
        let sessions = try await bootstrapSessions(using: api)
        return InviteBootstrapResult(effectiveCredentials: credentials, sessions: sessions)
    }

    /// Reaches the server before the single-use code goes out, so a network
    /// or certificate failure leaves the code usable and says so.
    private static func requireReachable(_ api: any InviteBootstrapAPI, host: String) async throws {
        let healthy: Bool
        do {
            healthy = try await api.health()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = pairingFailure(for: error, host: host)
            // Nothing was sent, so no failure here spends the code.
            throw InviteBootstrapError(
                message: failure.message,
                recovery: failure.recovery == .newCode ? .retry : failure.recovery
            )
        }
        guard healthy else {
            throw InviteBootstrapError(
                message: "\(host) answered, but not as an Oppi server. Check the address and port.",
                recovery: .serverSetup
            )
        }
    }

    /// Host-and-token entry has no signed invite, so it carries no server
    /// identity. Read it over the connection that just paired: TLS already
    /// verified the host against a certificate iOS trusts (a self-signed
    /// server without the link's pin fails before pairing). The person
    /// confirms it as they would an invite's. A failure or a declined prompt
    /// revokes the device this pairing enrolled.
    private static func confirmServerIdentity(
        of credentials: ServerCredentials,
        existing: ServerCredentials?,
        deviceId: String,
        using api: any InviteBootstrapAPI,
        confirmTrust: @MainActor (String) async -> Bool
    ) async throws -> ServerCredentials {
        let target = displayTarget(credentials)
        let fingerprint: String
        do {
            fingerprint = try await api.serverInfo().identity?.fingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch is CancellationError {
            revokeAbandonedEnrollment(deviceId: deviceId, using: api)
            throw CancellationError()
        } catch {
            fingerprint = ""
        }
        guard !fingerprint.isEmpty else {
            revokeAbandonedEnrollment(deviceId: deviceId, using: api)
            throw InviteBootstrapError(
                message: "\(target) did not report its server identity. Pair with its pairing link or QR code instead.",
                recovery: .newCode
            )
        }
        let existingFingerprint = existing?.normalizedServerFingerprint
        if existingFingerprint != fingerprint {
            let reason = existingFingerprint != nil
                ? "Server identity changed for \(target). Confirm trust reset."
                : "Trust \(target) (\(shortFingerprint(fingerprint)))"
            guard await confirmTrust(reason) else {
                revokeAbandonedEnrollment(deviceId: deviceId, using: api)
                throw InviteBootstrapError(message: "Trust confirmation cancelled", recovery: .newCode)
            }
        }
        return credentials.withServerFingerprint(fingerprint)
    }

    /// Cancel landed as the server enrolled this device, so the phone keeps no
    /// credential. Revoke the device with its own just-issued bearer so it does
    /// not stay in Paired Devices. Best effort: runs outside the cancelled task,
    /// and a failure is only logged. A Cancel while the poll request is in
    /// flight never sees the credential and still leaves the device enrolled.
    static func revokeAbandonedEnrollment(deviceId: String, using api: any InviteBootstrapAPI) {
        Task {
            do {
                try await api.revokeAuthDevice(id: deviceId)
                pairingLogger.notice("Revoked the device enrolled as pairing was cancelled")
            } catch {
                pairingLogger.error(
                    "Revoking the device enrolled as pairing was cancelled failed: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    private static func bootstrapSessions(using api: any InviteBootstrapAPI) async throws -> [Session] {
        guard try await api.health() else {
            throw InviteBootstrapError(message: "Server is not healthy", recovery: .newCode)
        }
        _ = try await api.me()
        return try await api.listSessionsFromWorkspaces(recentDays: 3)
    }

    /// A failure while the server held the code: after `requireReachable`, so
    /// a lost response may mean the server already took it.
    private static func pairingMutationFailure(
        for error: Error,
        host: String,
        didRequireApproval: Bool = false
    ) -> InviteBootstrapError {
        if didRequireApproval {
            return InviteBootstrapError(
                message: PairingEnrollment.Failure.classify(error).errorDescription
                    ?? PairingEnrollment.Failure.disconnected.errorDescription
                    ?? "Lost contact while waiting for approval. Request a fresh invite and try again.",
                recovery: .newCode
            )
        }
        if APIClientAvailabilityFailure(error: error) != nil {
            return InviteBootstrapError(
                message: "Pairing may have completed, but its response was lost. Open Oppi to check, or request a fresh invite before trying again.",
                recovery: .newCode
            )
        }
        return pairingFailure(for: error, host: host)
    }

    static func pairingFailureMessage(for error: Error, host: String) -> String {
        pairingFailure(for: error, host: host).message
    }

    static func pairingFailure(for error: Error, host: String) -> InviteBootstrapError {
        if let failure = error as? InviteBootstrapError {
            return failure
        }
        if let failure = error as? PairingEnrollment.Failure {
            return InviteBootstrapError(
                message: failure.errorDescription ?? "Pairing failed. Request a fresh invite and try again.",
                recovery: .newCode
            )
        }
        if let apiError = error as? APIError {
            let message = switch apiError {
            case .invalidResponse:
                "Server returned an invalid pairing response. Request a fresh invite and try again."
            case .server(401, let message) where message.localizedCaseInsensitiveContains("invalid or expired pairing token"):
                "Invite link expired or was already used. Request a fresh invite."
            case .server(429, _):
                "Too many invalid pairing attempts. Wait a moment, request a fresh invite, and try again."
            case .server(let status, let message), .codedServer(let status, let message, _):
                "Pairing failed with server error (\(status)): \(message)"
            }
            return InviteBootstrapError(message: message, recovery: .newCode)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed, .cannotLoadFromNetwork:
                return InviteBootstrapError(
                    message: "Could not reach \(host). Check the address, VPN, or network and try again.",
                    recovery: .reachability
                )
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .serverCertificateUntrusted, .clientCertificateRejected, .clientCertificateRequired:
                return InviteBootstrapError(
                    message: "Secure connection to \(host) failed. Verify the invite host and certificate, then try again.",
                    recovery: .serverSetup
                )
            default: break
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return InviteBootstrapError(
            message: message.isEmpty ? "Pairing failed. Request a fresh invite and try again." : "Pairing failed: \(message)",
            recovery: .newCode
        )
    }

    private static func displayTarget(_ credentials: ServerCredentials) -> String {
        credentials.host.isEmpty ? credentials.name : credentials.host
    }

    private static func shortFingerprint(_ fingerprint: String) -> String {
        fingerprint.count > 24 ? String(fingerprint.prefix(24)) + "…" : fingerprint
    }

    /// Turns an already-minted invite URL into a selected paired server.
    /// Tailscale same-user pairing and SSH pairing both stop here. Sends one
    /// `/pair`. Does not log the invite.
    @MainActor
    static func enroll(
        inviteURL: String,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator,
        onWaitingForApproval: (@MainActor (Int64?) -> Void)? = nil,
        confirmTrust: @MainActor (String) async -> Bool
    ) async throws -> InviteEnrollment {
        guard let credentials = ServerCredentials.decodeInviteURLString(inviteURL) else {
            throw InviteBootstrapError(
                message: "The pairing invite was not usable. Request a fresh one and try again.",
                recovery: .newCode
            )
        }
        return try await enroll(
            credentials: credentials,
            serverStore: serverStore,
            coordinator: coordinator,
            onWaitingForApproval: onWaitingForApproval,
            confirmTrust: confirmTrust
        )
    }

    /// The one pair-then-save path: QR, manual entry, `oppi://` invite links,
    /// Tailscale, and SSH all pair here, so each one warns when a known
    /// server's identity changed. The seams exist for tests.
    @MainActor
    static func enroll(
        credentials: ServerCredentials,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator,
        onWaitingForApproval: (@MainActor (Int64?) -> Void)? = nil,
        confirmTrust: @MainActor (String) async -> Bool,
        apiFactory: @MainActor (URL, String, String?) -> any InviteBootstrapAPI = { baseURL, token, tlsCertFingerprint in
            APIClient(baseURL: baseURL, token: token, tlsCertFingerprint: tlsCertFingerprint)
        },
        deviceKeyProvider: @MainActor () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> InviteEnrollment {
        try await save(credentials: credentials, serverStore: serverStore, coordinator: coordinator) { existing in
            try await validateAndBootstrap(
                credentials: credentials,
                existingCredentials: existing,
                confirmTrust: confirmTrust,
                apiFactory: apiFactory,
                deviceKeyProvider: deviceKeyProvider,
                onWaitingForApproval: onWaitingForApproval,
                sleep: sleep
            )
        }
    }

    /// Pairs through `bootstrap`, given the saved credentials for this server
    /// (by fingerprint, else host and port), then saves the result. Cancelling
    /// the task before the save keeps the pairing out of the store.
    @MainActor
    fileprivate static func save(
        credentials: ServerCredentials,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator,
        bootstrap: @MainActor (_ existing: ServerCredentials?) async throws -> InviteBootstrapResult
    ) async throws -> InviteEnrollment {
        let existing = credentials.normalizedServerFingerprint.flatMap {
            serverStore.server(for: $0)?.credentials
        } ?? serverStore.server(forHost: credentials.host, port: credentials.port)?.credentials
        let attempt = coordinator.beginPairingAttempt()
        let result = try await bootstrap(existing)
        if Task.isCancelled { throw PairingEnrollment.Failure.cancelled }
        guard let pairedServer = PairedServer(
            from: result.effectiveCredentials,
            sortOrder: serverStore.servers.count
        ) else {
            throw InviteBootstrapError(message: "Missing server fingerprint", recovery: .newCode)
        }
        // Committed: the server enrolled this device and the wait (with its
        // Cancel) has ended. A newer attempt only takes the selection.
        let outcome = await coordinator.addEnrolledServer(pairedServer, attempt: attempt)
        guard outcome != .failed else {
            throw InviteBootstrapError(message: "Connection blocked by server transport policy", recovery: .serverSetup)
        }
        return InviteEnrollment(
            name: pairedServer.name,
            selected: outcome == .selected,
            sessions: result.sessions
        )
    }
}

#if DEBUG
/// Apple E2E must pair with a real P-256 DeviceAuthSession. The harness script
/// `at_` is for XCTest lab API only and cannot refresh inside the app.
@MainActor
enum E2EAppAuthBootstrap {
    /// Launch-invite pairing for E2E: reuses a matching pairing, else pairs
    /// without the trust prompt, then saves like every other path.
    static func enroll(
        credentials: ServerCredentials,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator
    ) async throws -> InviteEnrollment {
        try await InviteBootstrapService.save(
            credentials: credentials,
            serverStore: serverStore,
            coordinator: coordinator
        ) { existing in
            if shouldReuseExistingPairing(existing: existing, invite: credentials), let existing {
                return InviteBootstrapResult(effectiveCredentials: existing, sessions: [])
            }
            return try await pairInvite(credentials: credentials)
        }
    }

    static func shouldPreserveServer(_ server: PairedServer, matching invite: ServerCredentials) -> Bool {
        shouldReuseExistingPairing(existing: server.credentials, invite: invite)
    }

    static func shouldReuseExistingPairing(
        existing: ServerCredentials?,
        invite: ServerCredentials
    ) -> Bool {
        guard let existing,
              existing.deviceCredential != nil,
              let existingFingerprint = existing.normalizedServerFingerprint,
              let inviteFingerprint = invite.normalizedServerFingerprint,
              existingFingerprint == inviteFingerprint,
              existing.host == invite.host,
              existing.port == invite.port else {
            return false
        }
        return true
    }

    static func pairInvite(
        credentials: ServerCredentials,
        deviceKeyProvider: () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        apiFactory: (URL, String, String?) -> any InviteBootstrapAPI = { baseURL, token, tlsCertFingerprint in
            APIClient(baseURL: baseURL, token: token, tlsCertFingerprint: tlsCertFingerprint)
        }
    ) async throws -> InviteBootstrapResult {
        guard let pairingToken = credentials.pairingToken, !pairingToken.isEmpty else {
            throw InviteBootstrapError(message: "E2E invite is missing a pairing token", recovery: .newCode)
        }
        guard let baseURL = credentials.baseURL else {
            throw InviteBootstrapError(message: "Invalid E2E invite URL", recovery: .serverSetup)
        }
        let pairingAPI = apiFactory(baseURL, "", credentials.normalizedTLSCertFingerprint)
        let pairResult: PairDeviceResponse
        do {
            let start = try await pairingAPI.startPairDevice(
                pairingToken: pairingToken,
                deviceName: PairingDeviceName.current(),
                devicePublicKey: try deviceKeyProvider().publicKey
            )
            pairResult = try await PairingEnrollment.complete(
                start: start,
                poll: { approvalId, pendingToken in
                    try await pairingAPI.pollPairingApprovalStatus(
                        approvalId: approvalId,
                        pendingToken: pendingToken
                    )
                }
            )
            if Task.isCancelled {
                if let deviceCredential = pairResult.deviceCredential {
                    InviteBootstrapService.revokeAbandonedEnrollment(
                        deviceId: deviceCredential.deviceId,
                        using: apiFactory(
                            baseURL,
                            deviceCredential.accessToken,
                            credentials.normalizedTLSCertFingerprint
                        )
                    )
                }
                throw PairingEnrollment.Failure.cancelled
            }
        } catch {
            throw InviteBootstrapService.pairingFailure(for: error, host: credentials.host)
        }
        guard let deviceCredential = pairResult.deviceCredential else {
            throw InviteBootstrapError(
                message: "Server returned an invalid pairing response. Request a fresh invite and try again.",
                recovery: .newCode
            )
        }
        let effective = credentials.withDeviceCredential(deviceCredential)
        let authed = apiFactory(
            baseURL,
            deviceCredential.accessToken,
            credentials.normalizedTLSCertFingerprint
        )
        let sessions = try await authed.listSessionsFromWorkspaces(recentDays: 3)
        return InviteBootstrapResult(effectiveCredentials: effective, sessions: sessions)
    }
}
#endif
