// SwiftUI only for `ComputerSetupSheet`, which presents the SwiftUI Tailscale
// screen until that screen moves to UIKit.
import SwiftUI
import UIKit

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
    /// A pasted pairing link or `oppi pair --json` output.
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
/// its recovery allows. A spent code is worded here, because the hint below
/// it already says how to get a new one.
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
        self.init(
            message: failure.codeProblem.map(Self.message(for:)) ?? failure.message,
            recovery: failure.recovery
        )
    }

    static func message(for problem: PairingCodeProblem) -> String {
        switch problem {
        case .expiredOrUsed:
            String(localized: "This pairing code expired or was already used.")
        case .tooManyAttempts:
            String(localized: "The server refused this code after too many invalid pairing attempts. Wait a moment before you use a new one.")
        case .denied:
            String(localized: "Pairing was denied on your other device.")
        case .approvalEnded:
            String(localized: "The approval request ended before another device approved it.")
        case .lostContactDuringApproval:
            String(localized: "Oppi lost contact with the server while waiting for approval.")
        case .cancelled:
            String(localized: "Pairing cancelled.")
        case .responseLost:
            String(localized: "Pairing may have finished, but the server\u{2019}s answer was lost.")
        case .unsigned:
            String(localized: "This pairing code is not signed by an Oppi server, so Oppi cannot verify it.")
        case .invalidResponse:
            String(localized: "The server sent a pairing answer Oppi could not use.")
        case .unexplained:
            String(localized: "Pairing failed.")
        }
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
            message: OnboardingPairingFailure.message(for: .cancelled),
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
