import UIKit

/// Live SSH terminal: UIKit owns the screen, floating controls, grid,
/// notices, lists, and chat bar (`ComposerBarController` in a terminal
/// configuration). The navigation bar stays hidden while this screen is on
/// top; Back, status, Herdr or Rex, and the … menu sit in a glass bar at the bottom
/// edge, below the grid, so they never cover a terminal row.
@MainActor
final class SSHTerminalViewController: UIViewController, NavigationBarHiding {
    /// Back and the actions float over the grid instead.
    var hidesNavigationBar: Bool { true }
    private(set) var channel: SSHTerminalChannel
    private let reconnect: () -> Void
    private let editHost: () -> Void
    /// Follows the terminal shown: the switcher changes it.
    private var hostLabel: String
    private weak var session: SSHTerminalConnectSession?
    /// Screenshot preview only: a server-scoped connection so the hosted
    /// composer can claim dictation. The live app uses the window's root.
    private let composerConnection: ServerConnection?
    /// How a pane of another Rex session opens: the connect session's own way
    /// unless the owner says otherwise (a preview with no host to dial).
    private let rexPaneOpener: ((RexPaneTarget) -> Void)?
    /// Screenshot preview only. A normal launch never sets this.
    var presentsStatusDetailOnAppear = false

    private(set) var gridView: SSHTerminalGridView?
    private let overlay = SSHTerminalPassthroughView()
    /// The bottom bar's container: Back at the leading edge, the one centred
    /// pill of buttons, and a Rex session's pane switcher at the trailing one.
    /// It ends at the keyboard layout guide, so with a docked keyboard up (and a
    /// broken connection, the one case that keeps the bar) it floats just above
    /// the keyboard.
    private let bottomBar = SSHTerminalPassthroughView()
    private var bottomBarHeight: NSLayoutConstraint?
    /// A Rex session's window minimap at the grid's top right. Its pane
    /// switcher is the bar's trailing pill (`rexPill`).
    private let rexMinimap = SSHTerminalRexMinimapView()
    /// The terminal shows a Rex session: the grid swipes (past the last pane
    /// that opens a new one) and takes VoiceOver's pane actions. The Rex
    /// control (`rexPill`) shows for every such session.
    private var rexSwipes = false
    /// The pane being opened (`createPane`), while one is. One at a time.
    private var newPaneTask: Task<Void, Never>?
    private let topStack = UIStackView()
    private let backPill = SSHTerminalBackPill()
    private let connectionBanner = SSHTerminalConnectionBannerView()
    private let inputBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.inputNotice")
    private let pasteBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.pasteNotice")
    private let openBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.openNotice")
    private let noticeCard = SSHTerminalNoticeCardView()
    private let copyNotice = SSHTerminalCopyNoticeView()
    private let backToLive = JumpToBottomButton()
    private var backToLiveThemeID: ThemeID?
    private let statusGlyph = SSHTerminalStatusGlyphButton()
    /// The bottom bar's one centred pill (Settings > Terminal > Bottom
    /// Bar), between Back and the pane switcher.
    private lazy var barPill = SSHTerminalBarPill(status: statusGlyph)
    /// A Rex pane's one Rex control, bottom trailing.
    private let rexPill = SSHTerminalRexPanesPill()
    private let barStore: SSHTerminalBarStore
    private lazy var barLayout = barStore.layout
    private lazy var barCustomKeys = barStore.customKeys
    private lazy var rexPanelSettings = barStore.rexPanel
    /// What the bar drew on the last pass. The … menu offers its `menu`,
    /// so the menu opened now matches the bar on screen.
    private var barPlacement = SSHTerminalBarPlacement(slots: [], menu: [])
    private var barLayoutObserver: NSObjectProtocol?
    /// The width and side insets the pill's capacity was last worked out for.
    private var barFit = SSHTerminalBarFit()
    /// The pill's room runs to the pane switcher while it shows, else to the edge.
    private var roomEndsAtPanes: NSLayoutConstraint?
    private var roomEndsAtEdge: NSLayoutConstraint?
    private var menuTitle: String?
    private var composerBar: ComposerBarController?
    private var composerSession: SSHTerminalComposerHost?
    private var composerKeyStrip: SSHTerminalKeyStripView?
    private var composerContainer: UIView?
    private var sendFailureLabel: UILabel?
    private var dictationFailureView: ComposerDictationFailureView?
    private var composerHeightConstraint: NSLayoutConstraint?
    private var lastAppliedComposerFocus = 0
    private var voicePrepareTask: Task<Void, Never>?
    private let gridClip = UIView()
    private var gridBottom: NSLayoutConstraint?
    /// Overlay notices and Back to Live stay above a chat bar that grew.
    private var overlayAboveComposer: NSLayoutConstraint?
    /// The chat bar's resting height, which the grid leaves free. Changes
    /// only with focus (the keyboard), width, or text size; never as the
    /// draft grows.
    private var composerReservedHeight: CGFloat = 0
    /// Rows the grid leaves free for the bottom bar, from the one rule in
    /// `SSHTerminalFloatingControls`: never with a keyboard up, so reconnecting
    /// never resizes the remote shell.
    private var bottomBarReserve: CGFloat {
        SSHTerminalFloatingControls.bottomBarReserve(keyboardUp: keyboardUp)
    }
    /// How much of the grid's bottom the chat bar covers right now.
    private var composerCoveredHeight: CGFloat = 0

    private var pendingPaste: String?
    private var pasteNotice: String?
    private var pasteNoticeTask: Task<Void, Never>?
    private var openNotice: String?
    private var openNoticeTask: Task<Void, Never>?
    /// What the open notice's Retry button runs, while that notice offers one.
    private var openNoticeRetry: (() -> Void)?
    /// The paired server's home folder, once known: the root every owner-host
    /// file path opens inside.
    private var pairedHome: String?
    private var pairedHomeTask: Task<Void, Never>?
    /// The Open or Browse Files Here lookup in flight, so a second choice can
    /// replace it and leaving the screen cancels it.
    private var openTask: Task<Void, Never>?
    /// Which open task is the newest, so an older one finishing late cannot
    /// clear the handle of the one that replaced it.
    private var openTaskGeneration = 0
    private var copyNoticeText: String?
    private var copyNoticeTask: Task<Void, Never>?
    private var lastCopies = 0
    /// The terminal on screen and the chat-bar drafts of the ones left, so a
    /// swap does not lose what was being typed.
    private var shownIdentity: SSHTerminalIdentity?
    private var composerDrafts: [SSHTerminalIdentity: SSHTerminalComposerHost.Draft] = [:]
    private var detached = false
    /// A password prompt is up on the live screen (the grid's secure entry).
    private var secureEntryActive = false
    /// The Face ID prompt and send behind a tap on Fill Password, until it ends.
    private var passwordFillTask: Task<Void, Never>?
    /// The password prompt ended while that task was waiting on the person.
    private var passwordFillPromptEnded = false
    /// The cursor shift was held for history or a touch on the last update.
    private var cursorShiftHeld = false
    private var rawKeyboard = false
    private var herdr = HerdrMonitor()
    private var rex: RexMonitor
    private var keymap = SSHTerminalKeymapLoader()
    /// What the person chose with Type in Terminal or Chat Bar. It lives with
    /// this screen: leaving it (Back, then reopening the terminal builds a new
    /// screen), a terminal switch, a Rex pane, or a reconnect starts over at
    /// direct typing. A program's report never changes it.
    private var inputMode: SSHTerminalInputMode = .terminal
    private var focusComposerAfterRaw = false
    private var composerFocusRequest = 0
    private var keyboardUp = false
    private var controlsVisible = true
    /// Popped, swiped back, or covered by a push: the navigation bar belongs
    /// to the incoming screen and this screen's layout no longer sizes the shell.
    private var isLeaving = false
    private var keyboardTransition = 0
    private var resizeHoldTask: Task<Void, Never>?
    private var backSwipe: SSHTerminalBackSwipe?
    private var reconnectOnReturn = false
    private var attention = SSHTerminalAttention()
    private let attentionFeedback = SSHTerminalAttentionFeedback()
    private var shownNoticeKey: SSHTerminalNotice.Key?
    /// Each multiplexer's poll, keyed by the bar action that opens its overview.
    private var overviewTasks: [SSHTerminalBarAction: Task<Void, Never>] = [:]
    private var keymapTask: Task<Void, Never>?
    private var keymapToken: String?
    /// The host's Ghostty colors, or the app theme where it has none.
    private var colorLoader: SSHTerminalColorLoader
    private var colorChoice: SSHTerminalColorChoice
    private var colorTask: Task<Void, Never>?
    private var colorToken: String?
    private var lastTerminalColors: SSHTerminalColorTheme?
    /// The registry closed this terminal while this screen was showing.
    private var sawClosedForBackground = false
    private var isOnScreen = false
    /// Leaving was asked for since the session last showed a terminal.
    private var requestedFinish = false
    private var presentingOverview = false
    private var presentingStatusDetail = false
    private var reduceMotion = UIAccessibility.isReduceMotionEnabled
    private var lastThemeID: ThemeID?
    private var defaultsObserver: NSObjectProtocol?
    /// The Rex and Herdr experiments changing while this terminal is on screen.
    private var experimentObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var keyboardObserver: NSObjectProtocol?

    init(
        channel: SSHTerminalChannel,
        reconnect: @escaping () -> Void,
        editHost: @escaping () -> Void,
        hostLabel: String = "",
        session: SSHTerminalConnectSession? = nil,
        composerConnection: ServerConnection? = nil,
        rexPaneOpener: ((RexPaneTarget) -> Void)? = nil,
        barStore: SSHTerminalBarStore = SSHTerminalBarStore()
    ) {
        self.rexPaneOpener = rexPaneOpener
        self.barStore = barStore
        self.channel = channel
        self.reconnect = reconnect
        self.editHost = editHost
        self.hostLabel = hostLabel
        self.session = session
        self.composerConnection = composerConnection
        rex = Self.makeRexMonitor(for: session?.connectedProfile, hosts: session?.rexHosts)
        let profileID = session?.connectedProfile?.id
        let choice = profileID.map { SSHTerminalColorStore().choice(for: $0) } ?? .host
        colorChoice = choice
        colorLoader = SSHTerminalColorLoader(
            profileID: profileID, choice: choice,
            dark: ThemeRuntimeState.currentThemeID().preferredColorScheme != .light
        )
        super.init(nibName: nil, bundle: nil)
        attention.glyphFrame.rect = .zero
        statusGlyph.glyphFrame.rect = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        shownIdentity = terminalIdentity
        buildLayout()
        barLayoutObserver = NotificationCenter.default.addObserver(
            forName: SSHTerminalBarStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadBarSettings() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.colorChoiceChanged()
            }
        }
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotionChanged()
            }
        }
        experimentObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.Experiments.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.experimentChanged() }
        }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
            let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
            let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
            let screen = notification.object as? UIScreen
            MainActor.assumeIsolated {
                self?.keyboardWillChange(endFrame: end, screen: screen, duration: duration, curve: curve)
            }
        }
        setNeedsUpdateProperties()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        isLeaving = false
        gridView?.releaseResize()
        applyControlsVisibility(animation: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        backSwipe?.uninstall()
        backSwipe = SSHTerminalBackSwipe(navigation: navigationController)
        // Remote clipboard writes apply only while this screen is in front.
        channel.isViewed = AppScenePhase.shared.phase == .active
        // The panes beside the shown one stream while the screen shows them, so
        // a swipe slides in a pane that is already live.
        channel.rex?.isWarming = true
        attentionFeedback.prepare()
        if presentsStatusDetailOnAppear, !presentingStatusDetail, programRollup != nil {
            presentsStatusDetailOnAppear = false
            showStatusDetail()
        }
        setNeedsUpdateProperties()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateComposerHeight()
        updateCursorShift()
        // A rotation, a resized iPad window, or a notch moving sides changes
        // how many middle buttons fit.
        if SSHTerminalBarFit(view) != barFit { setNeedsUpdateProperties() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        backSwipe?.uninstall()
        backSwipe = nil
        // A pop (Back or swipe) or a push has already changed the top screen.
        // Do not read isMovingFromParent here: while this screen presents a
        // sheet, reading it now leaves it false in viewDidDisappear.
        let leavingTop = navigationController.map { $0.topViewController !== self } ?? false
        guard leavingTop || isBeingDismissed else { return }
        isLeaving = true
        // The keyboard going down and the pop move this screen's layout
        // through sizes the shell must not get. Return sends the real size.
        resizeHoldTask?.cancel()
        gridView?.holdResize()
        channel.cancelPendingResize()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let leaving = isMovingFromParent || isBeingDismissed
        let coveredByPush = navigationController != nil && navigationController?.topViewController !== self
        // Herdr, status detail, and paste alerts cover this screen; stay viewed.
        // Swipe-back or a push over this screen still clears the clipboard gate
        // even if a modal is up: OSC 52 must not land after the user left.
        if presentedViewController != nil, !leaving, !coveredByPush { return }
        isOnScreen = false
        channel.isViewed = false
        // Off screen the terminal keeps its shown pane only: the neighbours'
        // streams go back to the host.
        channel.rex?.isWarming = false
        passwordFillTask?.cancel()
        pasteNoticeTask?.cancel()
        copyNoticeTask?.cancel()
        openNoticeTask?.cancel()
        pairedHomeTask?.cancel()
        pairedHomeTask = nil
        openTask?.cancel()
        openTask = nil
        stopOverviewPolls()
        keymapTask?.cancel()
        keymapTask = nil
        keymapToken = nil
        colorTask?.cancel()
        colorTask = nil
        colorToken = nil
        attentionFeedback.cancel()
        // Leaving the screen does not close the terminal: `SSHTerminalRegistry`
        // owns the channel, and Disconnect or the host's lifecycle ends it.
        guard leaving else { return }
        composerSession?.releaseVoice()
        session?.showsTerminal = false
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
        }
        if let keyboardObserver {
            NotificationCenter.default.removeObserver(keyboardObserver)
            self.keyboardObserver = nil
        }
        if let barLayoutObserver {
            NotificationCenter.default.removeObserver(barLayoutObserver)
            self.barLayoutObserver = nil
        }
        if let experimentObserver {
            NotificationCenter.default.removeObserver(experimentObserver)
            self.experimentObserver = nil
        }
    }

    override func updateProperties() {
        super.updateProperties()
        if let session, let next = session.channel, next !== channel {
            if let profile = session.connectedProfile {
                hostLabel = profile.terminalLabel(folder: session.folder, rexPane: session.rexPane)
            }
            replaceChannel(next)
        }
        // A Rex terminal is named for the pane it shows now.
        if let shown = channel.rex?.shownTarget, let profile = session?.connectedProfile {
            hostLabel = profile.terminalLabel(folder: nil, rexPane: shown)
        }
        let connected = channel.connected
        let connecting = channel.connecting
        let networkChanged = channel.networkChanged
        _ = channel.reason
        _ = channel.inputNotice
        _ = channel.title
        _ = channel.copies
        _ = channel.lastCopyLength
        _ = channel.command
        _ = channel.closedForBackground
        _ = channel.programStatus.records
        _ = channel.programStatus.root
        _ = channel.progress.report
        _ = channel.workingDirectory
        _ = channel.alerts.notification
        _ = channel.alerts.bell
        for action in SSHTerminalBarAction.overviews {
            _ = overview(action)?.available
            _ = overview(action)?.needsAttention
        }
        _ = keymap.actions
        _ = keymap.profile
        _ = keymap.userFile
        _ = colorLoader.resolution
        if let manager = composerSession?.voiceManager {
            _ = manager.transcriptPresentationRevision
            _ = manager.currentTranscript
            _ = manager.state
            _ = manager.currentComposerCaptureFailure
            composerSession?.applyOwnedVoiceObservation()
            applyDictationFailure()
        }
        let locked = AppLockService.shared.isLocked
        let phase = AppScenePhase.shared.phase
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        _ = AppRootEnvironment.near(self)?.themeStore.appTheme

        let terminalColors = colorLoader.theme
        // One palette for everything drawn over the grid: Oppi's theme when
        // it is on the terminal's light/dark side, else the built-in that is.
        let chromeID = SSHTerminalColorTheme.chromeTheme(themeID, colors: terminalColors)
        if lastThemeID != themeID || lastTerminalColors != terminalColors {
            lastThemeID = themeID
            lastTerminalColors = terminalColors
            applyTheme(chromeID, colors: terminalColors)
        }
        if channel.copies != lastCopies {
            lastCopies = channel.copies
            if lastCopies > 0 { showCopyNotice() }
        }
        // A remote clipboard write is applied only while this screen is in front.
        channel.isViewed = isOnScreen && phase == .active
        if channel.closedForBackground, isOnScreen, !sawClosedForBackground {
            reconnectOnReturn = true
        }
        sawClosedForBackground = channel.closedForBackground
        // A notice asking for Retry cannot be retried on a connection that went
        // away, so it leaves with it.
        if !connected, openNoticeRetry != nil {
            openNotice = nil
            openNoticeRetry = nil
            openNoticeTask?.cancel()
            openNoticeTask = nil
        }
        if phase == .active { reconnectAfterReturn() }
        if !locked { reconnectAfterReturn() }
        // This pass re-runs on every update; leave once per showing. A session
        // that shows a terminal again re-arms the request.
        if let session {
            if session.showsTerminal {
                requestedFinish = false
            } else if isOnScreen, !isMovingFromParent, !requestedFinish {
                requestedFinish = true
                Router.finish(self)
            }
        }

        navigationItem.title = channel.title.isEmpty ? "Terminal" : channel.title
        updatePolling()
        refreshPairedHome()
        updateFloatingControls(themeID: chromeID)
        updateBanners(connecting: connecting, connected: connected, networkChanged: networkChanged, themeID: chromeID)
        updateNotice(themeID: chromeID)
        updateCopyAndLive(themeID: chromeID)
        updateComposer()
        takeTerminalKeyboard()
        updatePasswordFill(connected: connected)
        if let gridView {
            gridView.setKeyActions(keymap.actions)
            gridView.showModifiers()
            gridView.applyTheme(chromeID, colors: terminalColors)
            gridView.needsPaint = true
        }
        attentionFeedback.apply(
            notice: visibleNotice,
            bell: channel.alerts.bell
        ) { [weak self] key in
            self?.attention.dismiss(key)
            self?.setNeedsUpdateProperties()
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .vertical
        topStack.alignment = .center
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false

        backPill.button.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .touchUpInside)
        barPill.perform = { [weak self] slot in self?.perform(slot) }
        barPill.deliverPaste = { [weak self] items in self?.gridView?.paste(itemProviders: items) }
        connectionBanner.onReconnect = { [weak self] in self?.reconnect() }
        noticeCard.onDismiss = { [weak self] key in
            self?.attention.dismiss(key)
            self?.setNeedsUpdateProperties()
        }
        noticeCard.onFrameChange = { [weak self] in self?.attention.cardFrame = $0 }
        backToLive.accessibilityIdentifier = "sshTerminal.backToLive"
        backToLive.accessibilityLabel = "Back to Live"
        backToLive.onTap = { [weak self] in self?.gridView?.backToLive() }
        statusGlyph.onOpen = { [weak self] in self?.showStatusDetail() }

        connectionBanner.isHidden = true
        inputBanner.isHidden = true
        pasteBanner.isHidden = true
        openBanner.isHidden = true
        noticeCard.isHidden = true
        copyNotice.isHidden = true
        topStack.addArrangedSubview(connectionBanner)
        topStack.addArrangedSubview(inputBanner)
        topStack.addArrangedSubview(pasteBanner)
        topStack.addArrangedSubview(openBanner)
        topStack.addArrangedSubview(noticeCard)
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        noticeCard.translatesAutoresizingMaskIntoConstraints = false
        inputBanner.translatesAutoresizingMaskIntoConstraints = false
        pasteBanner.translatesAutoresizingMaskIntoConstraints = false
        openBanner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            connectionBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            inputBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            pasteBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            openBanner.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            noticeCard.widthAnchor.constraint(equalTo: topStack.widthAnchor),
        ])

        // Under the banners and the notice card: a notice can cover the
        // minimap for the moment it shows.
        overlay.addSubview(rexMinimap)
        overlay.addSubview(topStack)
        overlay.addSubview(copyNotice)
        overlay.addSubview(backToLive)
        copyNotice.translatesAutoresizingMaskIntoConstraints = false
        backToLive.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Notices float at the grid's top edge and keep the bar's place
            // out of the way: they never change the grid's size.
            rexMinimap.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 8),
            topStack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 8),
            topStack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            copyNotice.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            copyNotice.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
            backToLive.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -8),
            backToLive.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
        ])

        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(backPill)
        bottomBar.addSubview(barPill)
        bottomBar.addSubview(rexPill)
        // The pill centers on the screen, so it grows the same distance each
        // way, and moves off center only when it would come closer than 8 pt
        // to Back or to what is at the trailing end (the pane switcher's pill
        // while it shows, else the screen's edge): its edges must stay in the
        // room between them, which wins over the centering
        // (`SSHTerminalBottomBar.pillMinX` is the same rule as a function).
        let room = UILayoutGuide()
        bottomBar.addLayoutGuide(room)
        let centered = barPill.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor)
        centered.priority = .defaultHigh
        // Below required: the capacity keeps the pill inside the room, and a
        // bar too narrow for "…" alone should crowd, not break constraints.
        let notBeforeRoom = barPill.leadingAnchor.constraint(greaterThanOrEqualTo: room.leadingAnchor)
        notBeforeRoom.priority = .required - 1
        let notPastRoom = barPill.trailingAnchor.constraint(lessThanOrEqualTo: room.trailingAnchor)
        notPastRoom.priority = .required - 1
        let endsAtPanes = room.trailingAnchor.constraint(equalTo: rexPill.leadingAnchor, constant: -SSHTerminalBottomBar.pillGap)
        let endsAtEdge = room.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -SSHTerminalBottomBar.sideInset
        )
        roomEndsAtPanes = endsAtPanes
        roomEndsAtEdge = endsAtEdge
        NSLayoutConstraint.activate([
            room.leadingAnchor.constraint(equalTo: backPill.trailingAnchor, constant: SSHTerminalBottomBar.pillGap),
            centered,
            notBeforeRoom,
            notPastRoom,
            barPill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
        ])

        // Hidden until a switch shows it (`SSHTerminalRexMinimapView`).
        // The minimap's cells, the switcher's menu, and the swipe all show a
        // pane through `showPane`.
        rexMinimap.select = { [weak self] block in self?.showPane(block) }
        rexPill.button.addAction(UIAction { [weak self] _ in self?.showRexPanel() }, for: .touchUpInside)
        rexPill.button.installMenu(
            state: { [weak self] in self?.channel.rex?.state },
            select: { [weak self] block in self?.showPane(block) },
            newPane: { [weak self] in self?.gridView?.createPane() }
        )
        gridClip.translatesAutoresizingMaskIntoConstraints = false
        gridClip.clipsToBounds = true
        view.addSubview(gridClip)
        view.addSubview(overlay)
        view.addSubview(bottomBar)
        let controlsInset = SSHTerminalBottomBar.sideInset
        // The room runs to the screen's edge until the pane switcher shows; this
        // one needs the bar in the view, for the safe area it names.
        endsAtEdge.isActive = true
        let barHeight = bottomBar.heightAnchor.constraint(equalToConstant: SSHTerminalBottomBar.shownHeight)
        bottomBarHeight = barHeight
        NSLayoutConstraint.activate([
            // Clear of a landscape notch: the grid runs edge to edge, the
            // controls stay inside the safe area.
            backPill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: controlsInset),
            backPill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
            rexPill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -controlsInset),
            rexPill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
            // Clear of a landscape notch, like the bar's pills.
            rexMinimap.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The guide rests on the bottom safe area and rides the keyboard.
            bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            barHeight,
            gridClip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            gridClip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridClip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridClip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        installGrid(makeGrid())
    }

    /// The grid ends above the bottom bar and the chat bar's resting height;
    /// a taller chat bar overlaps it. The clip hides rows the cursor shift
    /// moves above the grid's top.
    private func installGrid(_ grid: SSHTerminalGridView) {
        gridView = grid
        gridClip.addSubview(grid)
        let bottom = grid.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -(composerReservedHeight + bottomBarReserve)
        )
        gridBottom = bottom
        let overlayBottom = overlay.bottomAnchor.constraint(equalTo: grid.bottomAnchor)
        overlayBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: gridClip.topAnchor),
            grid.leadingAnchor.constraint(equalTo: gridClip.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: gridClip.trailingAnchor),
            bottom,
            overlay.topAnchor.constraint(equalTo: grid.topAnchor),
            overlayBottom,
            overlay.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
        ])
    }

    private func makeGrid() -> SSHTerminalGridView {
        let grid = SSHTerminalGridView(
            channel: channel,
            paste: { [weak self] in self?.requestPaste($0) },
            followChanged: { [weak self] following in
                self?.detached = !following
                self?.updateCursorShift()
                self?.setNeedsUpdateProperties()
            }
        )
        grid.translatesAutoresizingMaskIntoConstraints = false
        // Output moves the cursor; keep its row above a grown chat bar.
        grid.didDrawFrame = { [weak self] in self?.cursorMayHaveMoved() }
        grid.rawKeyboardChanged = { [weak self] raw in
            guard let self else { return }
            self.rawKeyboard = raw
            if !raw, self.focusComposerAfterRaw {
                self.focusComposerAfterRaw = false
                if self.inputMode == .chat { self.composerFocusRequest += 1 }
            }
            self.setNeedsUpdateProperties()
        }
        grid.useChatBar = { [weak self] in self?.showChatBar() }
        grid.keyboardDismissed = { [weak self] in self?.keyboardWasHidden() }
        grid.secureInputChanged = { [weak self] in self?.secureInputChanged($0) }
        grid.fillPassword = { [weak self] in self?.fillPassword() }
        grid.pasteImage = { [weak self] in self?.pasteImage($0) }
        grid.openTargetForHeldCell = { [weak self] held in self?.heldOpenTarget(held) }
        grid.open = { [weak self] target in self?.open(target) }
        grid.paneStepping = paneStepping
        grid.paneTransition.onSwitching = { [weak self] in self?.rexMinimap.setSwitching($0) }
        return grid
    }

    private func replaceChannel(_ next: SSHTerminalChannel) {
        // A terminal switched away from stays open in the registry; it is no
        // longer in front, so its remote clipboard writes are dropped.
        channel.isViewed = false
        channel.rex?.isWarming = false
        channel.cancelPendingResize()
        stopOverviewPolls()
        keymapTask?.cancel()
        colorTask?.cancel()
        keymapTask = nil
        keymapToken = nil
        colorTask = nil
        colorToken = nil
        // The switcher can show another host's terminal: its colors, choice
        // and cache are that host's, not the one this screen opened with.
        let hostID = session?.connectedProfile?.id
        if hostID != colorLoader.profileID {
            colorChoice = hostID.map { SSHTerminalColorStore().choice(for: $0) } ?? .host
            colorLoader = SSHTerminalColorLoader(profileID: hostID, choice: colorChoice, dark: appIsDark)
        }
        herdr = HerdrMonitor()
        rex = Self.makeRexMonitor(for: session?.connectedProfile, hosts: session?.rexHosts)
        keymap = SSHTerminalKeymapLoader()
        inputMode = .terminal
        attention = SSHTerminalAttention()
        shownNoticeKey = nil
        pasteNotice = nil
        copyNoticeText = nil
        openNotice = nil
        openNoticeRetry = nil
        pairedHome = nil
        pairedHomeTask?.cancel()
        pairedHomeTask = nil
        openTask?.cancel()
        openTask = nil
        detached = false
        passwordFillTask?.cancel()
        passwordFillTask = nil
        secureEntryActive = false
        cursorShiftHeld = false
        rawKeyboard = false
        automaticTerminalTyping = false
        refocusAfterSecurePrompt = true
        sawClosedForBackground = false
        reconnectOnReturn = false
        channel = next
        channel.isViewed = isOnScreen && AppScenePhase.shared.phase == .active
        // Not this terminal's copies: a swap shows no notice for the last one's.
        lastCopies = next.copies
        // The glyph's hold, ring, and last root belong to the terminal left.
        statusGlyph.reset()
        // Another terminal's switcher and swipe are not this one's; the next
        // pass shows this one's.
        rexSwipes = false
        newPaneTask?.cancel()
        newPaneTask = nil
        rexMinimap.reset()
        stashComposerDraft()
        destroyComposer()
        shownIdentity = terminalIdentity
        gridView?.removeFromSuperview()
        installGrid(makeGrid())
    }

    /// The clock and battery read against the terminal's background, which can
    /// be on the other side of light/dark from the app's theme. The default is
    /// today's: follow the app's appearance until the first theme is applied.
    private var terminalStatusBarStyle = UIStatusBarStyle.default
    override var preferredStatusBarStyle: UIStatusBarStyle { terminalStatusBarStyle }

    /// The terminal's own background when the host's theme sets one, so the
    /// screen, its bars and its pills read as one surface with the grid.
    private func applyTheme(_ themeID: ThemeID, colors: SSHTerminalColorTheme?) {
        let theme = themeID.appTheme
        view.backgroundColor = colors?.background.map(UIColor.init) ?? UIColor(theme.bg.primary)
        let dark = SSHTerminalColorTheme.isDark(background: colors?.background, fallback: themeID.preferredColorScheme != .light)
        overrideUserInterfaceStyle = dark ? .dark : .light
        let style: UIStatusBarStyle = dark ? .lightContent : .darkContent
        if terminalStatusBarStyle != style {
            terminalStatusBarStyle = style
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// Oppi's own appearance, which picks the side of a `light:`/`dark:` pair.
    private var appIsDark: Bool {
        (lastThemeID ?? ThemeRuntimeState.currentThemeID()).preferredColorScheme != .light
    }

    /// The theme for chrome over the grid; see `updateProperties`.
    private var chromeTheme: ThemeID {
        SSHTerminalColorTheme.chromeTheme(lastThemeID ?? ThemeRuntimeState.currentThemeID(), colors: lastTerminalColors)
    }

    private func colorChoiceChanged() {
        guard let id = session?.connectedProfile?.id else { return }
        let choice = SSHTerminalColorStore().choice(for: id)
        guard choice != colorChoice else { return }
        colorChoice = choice
        colorLoader.use(choice, dark: appIsDark)
        setNeedsUpdateProperties()
    }

    // MARK: - Floating controls

    /// The … menu's header names the screen: the shell's title when it
    /// set one, else the host, followed by the shell's folder when it reported
    /// one (OSC 7). The navigation bar that showed it is hidden.
    private func installMenu(title: String, folder: String) {
        let header = SSHTerminalMenuHeader.text(title: title, folder: folder)
        guard header != menuTitle else { return }
        menuTitle = header
        barPill.more.menu = UIMenu(
            title: header,
            children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.overflowElements() ?? [])
            }]
        )
    }

    /// The switcher's menu is built when it opens, so it lists the terminals
    /// open then, with the one on screen checked. Installed once.
    private func installSwitcherMenu() {
        guard barPill.switcher.menu == nil else { return }
        barPill.switcher.menu = UIMenu(children: [switcherElements()])
    }

    /// The open terminals, resolved when the menu opens. The switcher button and
    /// the … menu's Switch Terminal (when that button is hidden) both show it.
    private func switcherElements() -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, let session = self.session else { return completion([]) }
            let terminals = session.openTerminals()
            let items = SSHTerminalSwitcher.items(terminals: terminals, current: self.channel)
            completion(SSHTerminalSwitcher.menuElements(
                items: items,
                themeID: self.lastThemeID ?? ThemeRuntimeState.currentThemeID()
            ) { [weak self] index in
                guard terminals.indices.contains(index) else { return }
                self?.session?.show(terminals[index])
            })
        }
    }

    /// The … menu: the bar's actions that have no button now (turned off, or
    /// no room), in the layout's order, then the host's commands, then
    /// Customize Bar. Inline groups draw the separators.
    private func overflowElements() -> [UIMenuElement] {
        var groups: [UIMenuElement] = []
        let hidden = barPlacement.menu.map(menuElement(for:))
        if !hidden.isEmpty { groups.append(UIMenu(options: .displayInline, children: hidden)) }
        var items: [UIMenuElement] = []
        if channel.connected, let route = channel.rex?.route {
            // How this Rex terminal reaches Rex; information, not an action.
            let info = UIAction(title: route.label, image: UIImage(systemName: "network"), attributes: .disabled) { _ in }
            info.accessibilityIdentifier = "sshTerminal.menu.rexRoute"
            items.append(info)
        }
        // A Rex reached over Tailscale alone has no saved host to edit.
        if session?.currentProfile?.rexTailnet == nil {
            items.append(UIAction(title: "Edit Host", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.editHost()
            })
        }
        if channel.connected {
            items.append(UIAction(
                title: "Disconnect",
                image: UIImage(systemName: "xmark"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.channel.close(reason: "Closed by you.")
            })
        } else if !channel.connecting {
            items.append(UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.reconnect()
            })
        }
        groups.append(UIMenu(options: .displayInline, children: items))
        let customize = UIAction(
            title: String(localized: "Customize Bar…"),
            image: UIImage(systemName: "slider.horizontal.3")
        ) { [weak self] _ in self?.customizeBar() }
        customize.accessibilityIdentifier = "sshTerminal.menu.customize"
        groups.append(customize)
        return groups
    }

    private func menuElement(for slot: SSHTerminalBarSlot) -> UIMenuElement {
        let image: UIImage? = switch slot.content {
        case .action(let action): action.image()
        case .customKey, .shortcut: UIImage(systemName: "keyboard")
        }
        if case .action(.switcher) = slot.content {
            let menu = UIMenu(title: slot.title, image: image, children: [switcherElements()])
            menu.accessibilityIdentifier = slot.menuIdentifier
            return menu
        }
        // A shortcut's menu title carries its key, as its bar button's cap does.
        var title = slot.title
        if case .shortcut(let shortcut) = slot.content { title += " (\(shortcut.keyLabel))" }
        let item = UIAction(
            title: title,
            image: image,
            attributes: slot.sendsKeys && !canSendKeys ? .disabled : []
        ) { [weak self] _ in self?.perform(slot) }
        item.accessibilityIdentifier = slot.menuIdentifier
        return item
    }

    /// What the bar offers this terminal now (`SSHTerminalBarOffer`): the one
    /// owner the bar, the … menu, and VoiceOver read, from the multiplexer, the
    /// hosts this screen reaches, the program in front, its custom keys and its
    /// shortcuts. One that could only fail is neither drawn nor in the menu.
    private func barOffer(openTerminals: Int) -> SSHTerminalBarOffer {
        SSHTerminalBarOffer(
            context: barContext,
            overviews: Set(SSHTerminalBarAction.overviews.filter { overview($0)?.available == true }),
            openTerminals: openTerminals,
            // The Files browser over this terminal's folder needs the host to
            // report one and to be a paired Oppi server.
            canBrowseFiles: !channel.workingDirectory.isEmpty && pairedServer != nil,
            program: keymapProgram,
            customKeys: barCustomKeys,
            shortcuts: keymap.actions
        )
    }

    /// Which multiplexer this terminal belongs to: the owner of what the bar,
    /// the … menu, and Customize Bar leave out.
    private var barContext: SSHTerminalBarContext {
        SSHTerminalBarContext(isRexPane: channel.rex != nil, command: channel.command)
    }

    private var canSendKeys: Bool { channel.connected && !channel.inputClosed }

    /// Where typing goes now: the terminal's keyboard or the chat bar.
    private var selectedInput: SSHTerminalBarAction {
        inputMode == .chat && !rawKeyboard ? .chatBar : .keyboard
    }

    /// One owner for a bar button, whether it came from its button, VoiceOver,
    /// or the … menu.
    private func perform(_ slot: SSHTerminalBarSlot) {
        switch slot.content {
        case .action(let action):
            switch action {
            case .keyboard: showTerminalKeyboard()
            case .chatBar: focusChatBar()
            case .escape, .interrupt, .tab, .up, .down, .enter:
                channel.keys(slot.strokes)
            case .paste: break // The system paste control delivers through barPill.deliverPaste.
            case .browseFiles: browseFilesHere()
            case .herdr, .rex: showOverview(action)
            case .switcher: break // A menu, not an action.
            }
        case .customKey, .shortcut:
            channel.keys(slot.strokes)
        }
    }

    /// The saved layout, custom keys, and Rex panel choices, read again when
    /// Bottom Bar changes any of them.
    private func reloadBarSettings() {
        barLayout = barStore.layout
        barCustomKeys = barStore.customKeys
        rexPanelSettings = barStore.rexPanel
        setNeedsUpdateProperties()
    }

    /// What the Rex pane switcher's icon says (`SSHTerminalRexPillStatus`): the
    /// shown pane's program status and OSC 9;4 progress, and how many other
    /// panes need you; none of it when the person turned it off.
    private func rexPillStatus(headline: SessionStatusKind?, progress: SSHTerminalProgressReport?) -> SSHTerminalRexPillStatus {
        guard rexPanelSettings.showsStatusOnIcon else { return .none }
        let state = channel.rex?.state
        return SSHTerminalRexPillStatus(
            // The terminal's own OSC 7501 reports, else what Rex reports for the pane.
            headline: headline ?? state?.panes.first { $0.blockID == state?.shown }?.status,
            progress: progress,
            needsYou: rex.failure == nil
                ? SSHTerminalRexPanelContent.needsYou(state: state, snapshot: rex.snapshot, sessionID: channel.rex?.sessionID) : 0
        )
    }

    /// Settings > Terminal > Bottom Bar, pushed over the terminal so the
    /// bar being customized is one Back away.
    private func customizeBar() {
        Router.push(SSHTerminalBarSettingsViewController(context: barContext), from: self)
    }

    private func updateFloatingControls(themeID: ThemeID) {
        let rollup = programRollup
        let headline = rollup?.headline
        let progress = channel.progress.report
        // A Rex pane draws its program's status on the pane switcher's icon, not
        // as a symbol of its own in the bar's pill.
        let showsStatus = (headline != nil || progress != nil) && barContext.showsProgramStatus
        if showsStatus {
            statusGlyph.apply(
                status: headline,
                summary: rollup?.summaryText ?? "",
                themeID: themeID,
                reduceMotion: reduceMotion,
                root: channel.programStatus.root.map { .init(state: $0.state, revision: $0.revision) },
                progress: progress
            )
            attention.glyphFrame.rect = statusGlyph.glyphFrame.rect
        }
        let foreground = lastTerminalColors?.foreground.map(UIColor.init)
        let tint = foreground ?? themeID.palette.ui.fg
        let openTerminals = session?.openTerminals().count ?? 0
        barFit = SSHTerminalBarFit(view)
        // The Rex pane switcher's pill holds the room at the trailing end only
        // while it shows; the pill is centred in what is left.
        let rexPanesShown = channel.rex != nil
        let animates = !reduceMotion && isOnScreen && view.window != nil
        if roomEndsAtPanes?.isActive != rexPanesShown {
            roomEndsAtEdge?.isActive = !rexPanesShown
            roomEndsAtPanes?.isActive = rexPanesShown
            if animates {
                UIView.animate(withDuration: SSHTerminalBarPill.changeDuration, delay: 0, options: [.beginFromCurrentState]) {
                    self.bottomBar.layoutIfNeeded()
                }
            }
        }
        barPlacement = barOffer(openTerminals: openTerminals).placement(
            layout: barLayout,
            capacity: SSHTerminalBottomBar.capacity(
                width: view.bounds.width,
                safeInsets: view.safeAreaInsets,
                rexPanesShown: rexPanesShown,
                // The status symbol, when a program has reported, and ….
                fixedItems: (showsStatus ? 1 : 0) + 1
            )
        )
        barPill.apply(
            themeID: themeID,
            waiting: overviewsWaiting,
            openTerminals: openTerminals,
            tint: tint,
            background: lastTerminalColors?.background.map(UIColor.init) ?? themeID.palette.ui.bg,
            selected: selectedInput,
            keysEnabled: canSendKeys
        )
        barPill.show(barPlacement.slots, showsStatus: showsStatus, animated: animates)
        installSwitcherMenu()
        rexPill.apply(
            state: channel.rex?.state, tint: tint, status: rexPillStatus(headline: headline, progress: progress),
            themeID: themeID, reduceMotion: reduceMotion
        )
        if rexPanesShown, headline != nil || progress != nil { attention.glyphFrame.rect = rexPill.button.glyphFrame.rect }
        backPill.apply(themeID: themeID, attentionPending: attentionPending(), foreground: lastTerminalColors?.foreground.map(UIColor.init))
        updateRexPanes(themeID: themeID)
        installMenu(
            title: SSHTerminalMenuHeader.name(
                shellTitle: channel.title, hostLabel: hostLabel,
                hostName: session?.connectedProfile?.endpointLabel, shellFolder: channel.workingDirectory
            ),
            folder: channel.workingDirectory
        )
        applyControlsVisibility(animation: .init(duration: 0.2, options: [.curveEaseInOut, .beginFromCurrentState]))
    }

    /// Puts the pane the session shows on the grid, unless a slide is running
    /// (it presents its own end). Idempotent.
    private func reconcileShownPane() {
        guard gridView?.paneTransition.phase == .idle else { return }
        gridView?.presentShownPane()
    }

    /// A Rex terminal's minimap and swipe. The swipe works for every session
    /// (past the last pane it opens a new one); the minimap is available only
    /// for a window with more than one pane, and shows only while a switch runs.
    private func updateRexPanes(themeID: ThemeID) {
        let rex = channel.rex?.state
        let swipes = channel.rex != nil
        // A session that arrives (or reconnects) while this screen is up warms
        // its neighbours too; idempotent, so every pass may ask.
        channel.rex?.isWarming = isOnScreen && AppScenePhase.shared.phase == .active
        // One owner of "the pane on screen is the pane typing reaches": a switch
        // with no slide of its own (a pane closed in Rex, a refusal recovered, a
        // new pane) lands here. A slide owns the pixels until it ends.
        channel.rex?.onShown = { [weak self] _ in self?.reconcileShownPane() }
        reconcileShownPane()
        if let rex {
            let background = lastTerminalColors?.background.map(UIColor.init) ?? themeID.palette.ui.bg
            rexMinimap.apply(
                state: rex, shownTint: themeID.palette.ui.blue,
                otherTint: themeID.palette.ui.fgDim.withAlphaComponent(0.5),
                backdropColor: background.withAlphaComponent(0.75)
            )
        }
        rexMinimap.isAvailable = rex?.showsMinimap == true
        if swipes != rexSwipes {
            rexSwipes = swipes
            gridView?.paneStepping = paneStepping
        }
    }

    /// The grid's swipe and VoiceOver actions, for a Rex session.
    private var paneStepping: SSHTerminalPaneStepping? {
        guard rexSwipes else { return nil }
        return SSHTerminalPaneStepping(
            neighbour: { [weak self] delta in self?.channel.rex?.latest.neighbour(offsetBy: delta)?.name },
            step: { [weak self] delta in self?.channel.rex?.step(delta) ?? false },
            shown: { [weak self] in self?.channel.rex?.latest.shown },
            newPane: { [weak self] in self?.openNewPane() ?? false },
            canCreatePane: { [weak self] in self?.newPaneTask == nil },
            target: { [weak self] delta in self?.channel.rex?.latest.pane(offsetBy: delta) },
            takeAhead: { [weak self] block in self?.channel.rex?.takeAhead(block) }
        )
    }

    /// Starts opening a new pane after the shown one, unless one is already
    /// opening. The grid's cover (`SSHTerminalPaneTransition`) waits for the
    /// answer: the new pane is shown through the session like any switch, or
    /// the cover slides away to the pane the terminal was on and a notice says
    /// why. Nothing is ever left stuck: a request that never answers ends at
    /// Rex's request timeout, and the cover's own creation timeout covers the rest.
    private func openNewPane() -> Bool {
        guard let rex = channel.rex, newPaneTask == nil else { return false }
        newPaneTask = Task { [weak self] in
            let created: Result<String, any Error>
            do { created = .success(try await rex.newPane()) } catch { created = .failure(error) }
            // A terminal swapped out meanwhile cancelled this; its cover is gone.
            guard let self, !Task.isCancelled else { return }
            newPaneTask = nil
            switch created {
            case .success(let name):
                gridView?.paneTransition.paneCreated(named: name)
            case .failure(let error):
                gridView?.paneTransition.creationFailed()
                showOpenNotice("Could not open a new pane. \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Shows `blockID` for the switcher's menu and the minimap's cells: the
    /// session takes the request, and the grid slides in the direction of
    /// travel. The pane icon and the minimap's highlight follow the session's
    /// state, as they do for a swipe.
    private func showPane(_ blockID: String) {
        guard let rex = channel.rex, gridView?.paneTransition.isAwaitingCreation != true else { return }
        let before = rex.latest
        guard let from = before.shownIndex, let to = before.panes.firstIndex(where: { $0.blockID == blockID }) else { return }
        // The slide goes first, naming the pane it heads for: the session's move
        // then lands at the slide's end, not under it.
        gridView?.paneTransition.slide(toward: to > from ? 1 : -1, neighbour: before.panes[to].name, target: blockID)
        guard rex.show(blockID) else { return }
    }

    /// Fades the bar with the keyboard. A hidden bar takes no touches, leaves
    /// the accessibility tree, and gives its rows back to the grid; edge-swipe
    /// back still works.
    private func applyControlsVisibility(animation: SSHTerminalKeyboard.Animation?) {
        let visible = SSHTerminalFloatingControls.visible(keyboardUp: keyboardUp, connected: channel.connected)
        // Geometry is idempotent and must apply even when the bar's visibility
        // does not change: the keyboard alone moves the reserve.
        applyBottomBarGeometry(visible: visible)
        guard visible != controlsVisible || animation == nil else { return }
        controlsVisible = visible
        for pill in [backPill, barPill, rexPill] as [UIView] {
            pill.isUserInteractionEnabled = visible
            pill.accessibilityElementsHidden = !visible
        }
        let apply = {
            self.backPill.alpha = visible ? 1 : 0
            self.barPill.alpha = visible ? 1 : 0
            self.rexPill.alpha = visible ? 1 : 0
        }
        if let animation, isOnScreen, view.window != nil {
            UIView.animate(withDuration: animation.duration, delay: 0, options: animation.options, animations: apply)
        } else {
            apply()
        }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// The bar's height and the rows the grid leaves for it. Two inputs: the
    /// bar shows or it does not, and the keyboard is up or it is not (with a
    /// docked keyboard up the grid never gives the bar rows; a broken
    /// connection then floats the bar over them instead).
    private func applyBottomBarGeometry(visible: Bool) {
        let height = visible ? SSHTerminalBottomBar.shownHeight : 0
        if abs((bottomBarHeight?.constant ?? 0) - height) > 0.5 {
            bottomBarHeight?.constant = height
        }
        updateBottomRows()
    }

    private func goBack() {
        Router.finish(self)
    }

    /// VoiceOver's two-finger scrub goes back, as it would with a bar.
    override func accessibilityPerformEscape() -> Bool {
        guard navigationController.map({ $0.viewControllers.count > 1 }) ?? false else { return false }
        goBack()
        return true
    }

    private func attentionPending() -> Bool {
        SSHTerminalFloatingControls.attentionPending(
            multiplexersWaiting: overviewsWaiting.values.reduce(0, +),
            blockedProgram: SSHTerminalProgramStatusPresentation.blockedNotice(
                store: channel.programStatus,
                isStopped: programIsStopped
            ) != nil
        )
    }

    /// One resize per keyboard transition. Layout-driven resizes are held,
    /// the chat bar's end state is laid out inside the keyboard's animation,
    /// and the grid size the keyboard settles at is sent once. Layout passes
    /// in between (the chat bar, the bottom bar, and the keyboard guide move in
    /// separate passes) are ignored until the transition ends; the release
    /// sends the real size only if the prediction missed. The bottom bar and
    /// the floating controls change the grid's free rows, but inside that same
    /// transition, so they never add a resize of their own.
    private func keyboardWillChange(endFrame: CGRect, screen: UIScreen?, duration: TimeInterval, curve: UInt) {
        guard let viewScreen = view.window?.windowScene?.screen,
              let end = SSHTerminalKeyboard.endFrame(
                endFrame,
                keyboardScreen: screen,
                viewScreen: viewScreen,
                screenSpace: viewScreen.coordinateSpace,
                in: view
              )
        else { return }
        keyboardUp = SSHTerminalKeyboard.isUp(endFrameInView: end, viewBounds: view.bounds)
        // The reserve depends on the keyboard, and the bar's visibility may not
        // change with it (a broken connection keeps the bar), so size the grid
        // here too: it lands in the one resize this change already sends.
        applyBottomBarGeometry(
            visible: SSHTerminalFloatingControls.visible(keyboardUp: keyboardUp, connected: channel.connected)
        )
        applyControlsVisibility(animation: SSHTerminalKeyboard.animation(duration: max(duration, 0.2), curve: curve))
        guard isOnScreen, !isLeaving, let gridView else { return }
        keyboardTransition &+= 1
        let transition = keyboardTransition
        gridView.holdResize()
        resizeHoldTask?.cancel()
        resizeHoldTask = Task { [weak self, weak gridView] in
            // The chat bar's text view finishes editing after this
            // notification and drops its key strip. Lay out and measure once
            // that has happened, still inside the keyboard's animation.
            await Task.yield()
            guard let self, let gridView, transition == self.keyboardTransition, !self.isLeaving else { return }
            self.settleKeyboardTransition(end: end, grid: gridView, duration: duration, curve: curve)
            do { try await Task.sleep(for: .seconds(max(duration, 0.25) + 0.15)) } catch { return }
            guard transition == self.keyboardTransition, !self.isLeaving else { return }
            gridView.releaseResize()
        }
    }

    private func settleKeyboardTransition(
        end: CGRect,
        grid gridView: SSHTerminalGridView,
        duration: TimeInterval,
        curve: UInt
    ) {
        let animation = SSHTerminalKeyboard.animation(duration: duration, curve: curve)
        UIView.animate(withDuration: animation.duration, delay: 0, options: animation.options) {
            self.updateComposerHeight()
            self.view.layoutIfNeeded()
        }
        let settled = SSHTerminalKeyboard.settledGridSize(
            current: gridView.bounds.size,
            guideTop: view.keyboardLayoutGuide.layoutFrame.minY,
            settledGuideTop: SSHTerminalKeyboard.settledGuideTop(
                endFrameInView: end,
                viewBounds: view.bounds,
                bottomSafeArea: view.safeAreaInsets.bottom
            )
        )
        if let geometry = gridView.geometry(for: settled) { channel.resize(geometry) }
    }

    // MARK: - Overlays

    private func updateBanners(connecting: Bool, connected: Bool, networkChanged: Bool, themeID: ThemeID) {
        let showStatus = connecting || !connected || networkChanged
        connectionBanner.isHidden = !showStatus
        if showStatus {
            connectionBanner.apply(
                text: statusText,
                showsProgress: connecting || networkChanged,
                showsReconnect: !connected && !connecting,
                themeID: themeID
            )
        }
        let input = channel.inputNotice
        inputBanner.isHidden = input.isEmpty
        if !input.isEmpty {
            inputBanner.apply(text: input, color: themeID.palette.ui.orange)
        }
        pasteBanner.isHidden = pasteNotice == nil
        if let pasteNotice {
            pasteBanner.apply(text: pasteNotice, color: themeID.palette.ui.orange)
        }
        openBanner.isHidden = openNotice == nil
        if let openNotice {
            openBanner.apply(
                text: openNotice,
                color: themeID.palette.ui.fg,
                action: openNoticeRetry.map { handler in
                    SSHTerminalTextBannerView.Action(title: String(localized: "Retry"), handler: handler)
                }
            )
        }
    }

    private func updateNotice(themeID: ThemeID) {
        let notice = visibleNotice
        if notice?.key == shownNoticeKey {
            if let notice {
                noticeCard.isHidden = false
                noticeCard.apply(notice: notice, hostCaption: hostLabel, themeID: themeID, reduceMotion: reduceMotion)
            }
            return
        }
        let previousKey = shownNoticeKey
        shownNoticeKey = notice?.key
        let duration: TimeInterval = reduceMotion ? 0.2 : 0.35
        if previousKey != nil {
            let transform = reduceMotion
                ? CGAffineTransform.identity
                : SSHTerminalNoticeCardView.collapseTransform(card: attention.cardFrame, glyph: attention.glyphFrame.rect)
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                if self.reduceMotion {
                    self.noticeCard.alpha = 0
                } else {
                    self.noticeCard.transform = transform
                    self.noticeCard.alpha = 0
                }
            } completion: { _ in
                self.noticeCard.transform = .identity
                self.noticeCard.alpha = 1
                if let notice {
                    self.noticeCard.isHidden = false
                    self.noticeCard.apply(notice: notice, hostCaption: self.hostLabel, themeID: themeID, reduceMotion: self.reduceMotion)
                    self.animateNoticeIn(duration: duration)
                } else {
                    self.noticeCard.isHidden = true
                }
            }
        } else if let notice {
            noticeCard.isHidden = false
            noticeCard.apply(notice: notice, hostCaption: hostLabel, themeID: themeID, reduceMotion: reduceMotion)
            animateNoticeIn(duration: duration)
        } else {
            noticeCard.isHidden = true
        }
    }

    private func animateNoticeIn(duration: TimeInterval) {
        if reduceMotion {
            noticeCard.alpha = 0
            UIView.animate(withDuration: duration) { self.noticeCard.alpha = 1 }
        } else {
            noticeCard.alpha = 0
            noticeCard.transform = CGAffineTransform(translationX: 0, y: -24)
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
                self.noticeCard.alpha = 1
                self.noticeCard.transform = .identity
            }
        }
    }

    private func updateCopyAndLive(themeID: ThemeID) {
        copyNotice.isHidden = copyNoticeText == nil
        if let copyNoticeText {
            copyNotice.apply(text: copyNoticeText, themeID: themeID)
        }
        if backToLiveThemeID != themeID {
            backToLiveThemeID = themeID
            // The terminal never shows the button busy; the tint is unused.
            backToLive.apply(palette: themeID.palette, busyTint: themeID.palette.ui.blue)
        }
        backToLive.setVisible(detached)
    }

    // MARK: - Composer

    private func updateComposer() {
        let show = inputMode == .chat && !rawKeyboard
        if show {
            embedComposer()
            refreshComposerChrome()
            if composerFocusRequest != lastAppliedComposerFocus {
                lastAppliedComposerFocus = composerFocusRequest
                composerSession?.requestFocus()
            }
        } else {
            unembedComposer()
        }
    }

    private func serverConnection() -> ServerConnection? {
        composerConnection ?? AppRootEnvironment.near(self)?.coordinator.activeConnection
    }

    private func makeComposer() {
        let session = SSHTerminalComposerHost(
            channel: channel,
            connection: serverConnection(),
            draftStore: AppRootEnvironment.near(self)?.composerDraftStore,
            themeID: chromeTheme,
            terminalColors: lastTerminalColors,
            showRawKeyboard: { [weak self] in self?.showTerminalKeyboard() }
        )
        if let identity = terminalIdentity, let draft = composerDrafts[identity] { session.restore(draft) }
        session.onNeedsLayout = { [weak self] in self?.updateComposerHeight() }
        session.onFailureChange = { [weak self] message in self?.applySendFailure(message) }

        let bar = ComposerBarController()
        session.attach(bar)
        _ = bar.view

        let strip = SSHTerminalKeyStripView(
            role: .composer,
            handlers: SSHTerminalKeyStripView.Handlers(
                sendStrokes: { [weak self] strokes in self?.channel.keys(strokes) },
                sendKey: { [weak self] key in _ = self?.channel.key(key) },
                sendArrow: { [weak self] key in self?.channel.key(key) ?? false },
                showRawKeyboard: { [weak self] in self?.showTerminalKeyboard() },
                fillPassword: { [weak self] in self?.fillPassword() }
            )
        )
        bar.installKeyStrip(strip)

        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .fill
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let dictation = ComposerDictationFailureView()
        dictation.isHidden = true
        dictation.onRetry = { [weak session] in session?.retryVoice() }

        let failure = UILabel()
        failure.font = UIFont.preferredFont(forTextStyle: .caption1)
        failure.numberOfLines = 0
        failure.accessibilityIdentifier = "sshTerminal.composer.failure"
        failure.isHidden = true

        bar.view.translatesAutoresizingMaskIntoConstraints = false
        bar.view.backgroundColor = .clear
        let dictationWrap = UIView()
        dictation.translatesAutoresizingMaskIntoConstraints = false
        dictationWrap.addSubview(dictation)
        NSLayoutConstraint.activate([
            dictation.leadingAnchor.constraint(equalTo: dictationWrap.leadingAnchor, constant: 16),
            dictation.trailingAnchor.constraint(equalTo: dictationWrap.trailingAnchor, constant: -16),
            dictation.topAnchor.constraint(equalTo: dictationWrap.topAnchor),
            dictation.bottomAnchor.constraint(equalTo: dictationWrap.bottomAnchor),
        ])
        let failureWrap = UIView()
        failure.translatesAutoresizingMaskIntoConstraints = false
        failureWrap.addSubview(failure)
        NSLayoutConstraint.activate([
            failure.leadingAnchor.constraint(equalTo: failureWrap.leadingAnchor, constant: 16),
            failure.trailingAnchor.constraint(equalTo: failureWrap.trailingAnchor, constant: -16),
            failure.topAnchor.constraint(equalTo: failureWrap.topAnchor),
            failure.bottomAnchor.constraint(equalTo: failureWrap.bottomAnchor),
        ])
        dictationWrap.isHidden = true
        failureWrap.isHidden = true
        container.addArrangedSubview(dictationWrap)
        container.addArrangedSubview(failureWrap)
        container.addArrangedSubview(bar.view)

        composerSession = session
        composerBar = bar
        composerKeyStrip = strip
        composerContainer = container
        dictationFailureView = dictation
        sendFailureLabel = failure
    }

    private func embedComposer() {
        if composerBar == nil { makeComposer() }
        guard let bar = composerBar, let container = composerContainer, bar.parent !== self else {
            return
        }
        addChild(bar)
        view.addSubview(container)
        bar.didMove(toParent: self)
        let height = container.heightAnchor.constraint(equalToConstant: 60)
        composerHeightConstraint = height
        let overlayAbove = overlay.bottomAnchor.constraint(lessThanOrEqualTo: container.topAnchor)
        overlayAboveComposer = overlayAbove
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Above the bottom bar, so the two never stack on each other and
            // the bar stays on the screen's bottom edge as the chat bar does
            // while the keyboard is up (the bar is gone then).
            container.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            height,
            overlayAbove,
        ])
        voicePrepareTask?.cancel()
        voicePrepareTask = Task { [weak self] in
            await self?.composerSession?.prepareVoice()
            guard !Task.isCancelled else { return }
            self?.setNeedsUpdateProperties()
        }
        updateComposerHeight()
    }

    private func unembedComposer() {
        guard let bar = composerBar, bar.parent === self else { return }
        voicePrepareTask?.cancel()
        voicePrepareTask = nil
        composerKeyStrip?.stopRepeating()
        composerSession?.releaseVoice()
        bar.view.endEditing(true)
        composerHeightConstraint?.isActive = false
        composerHeightConstraint = nil
        overlayAboveComposer?.isActive = false
        overlayAboveComposer = nil
        bar.willMove(toParent: nil)
        composerContainer?.removeFromSuperview()
        bar.removeFromParent()
        composerReservedHeight = 0
        composerCoveredHeight = 0
        updateBottomRows()
        updateCursorShift()
    }

    /// The bottom rows the grid leaves free: the chat bar's resting height
    /// above the bottom bar's own. Keeping this in one place is what makes a
    /// keyboard change one resize: both terms settle before the size is sent.
    private func updateBottomRows() {
        let constant = -(composerReservedHeight + bottomBarReserve)
        guard abs((gridBottom?.constant ?? 0) - constant) > 0.5 else { return }
        gridBottom?.constant = constant
    }

    private var terminalIdentity: SSHTerminalIdentity? {
        guard let session, let profile = session.connectedProfile else { return nil }
        return SSHTerminalIdentity(profileID: profile.id, folder: session.folder, rexSession: session.rexPane?.sessionID)
    }

    /// Keeps the chat bar's text and attachments for the terminal being left.
    private func stashComposerDraft() {
        guard let identity = shownIdentity, let draft = composerSession?.draftEndingDictation() else { return }
        composerDrafts[identity] = draft.isEmpty ? nil : draft
    }

    private func destroyComposer() {
        voicePrepareTask?.cancel()
        voicePrepareTask = nil
        unembedComposer()
        composerBar = nil
        composerSession = nil
        composerKeyStrip = nil
        composerContainer = nil
        sendFailureLabel = nil
        dictationFailureView = nil
        lastAppliedComposerFocus = 0
    }

    private func refreshComposerChrome() {
        let themeID = chromeTheme
        composerSession?.connection = serverConnection()
        composerSession?.draftStore = AppRootEnvironment.near(self)?.composerDraftStore
        composerSession?.refreshChrome(
            themeID: themeID,
            terminalColors: lastTerminalColors,
            reduceMotion: reduceMotion,
            connected: channel.connected
        )
        let colors = ComposerThemeColors(palette: themeID.palette, terminal: lastTerminalColors)
        composerKeyStrip?.apply(
            profile: keymap.profile,
            userFile: keymap.userFile,
            colors: colors,
            foreground: colors.fg,
            background: colors.bg
        )
        applySendFailure(composerSession?.sendFailure)
        applyDictationFailure()
        composerBar?.micColors = colors
        composerBar?.apply()
        updateComposerHeight()
    }

    private func applySendFailure(_ message: String?) {
        guard let label = sendFailureLabel else { return }
        let colors = ComposerThemeColors(palette: chromeTheme.palette, terminal: lastTerminalColors)
        label.text = message
        label.textColor = colors.red
        let hidden = message == nil || message?.isEmpty == true
        label.isHidden = hidden
        label.superview?.isHidden = hidden
        updateComposerHeight()
    }

    private func applyDictationFailure() {
        guard let banner = dictationFailureView else { return }
        let colors = ComposerThemeColors(palette: chromeTheme.palette, terminal: lastTerminalColors)
        if let failure = ComposerShared.captureFailure(composerSession?.voiceManager, owner: .inlineComposer) {
            banner.apply(message: failure.message, colors: colors)
            banner.isHidden = false
            banner.superview?.isHidden = false
        } else {
            banner.isHidden = true
            banner.superview?.isHidden = true
        }
        updateComposerHeight()
    }

    private func updateComposerHeight() {
        guard let bar = composerBar, let container = composerContainer,
              container.superview != nil else { return }
        let width = max(view.bounds.width, 1)
        let barHeight = bar.sizeThatFits(width: width).height
        let dictation: CGFloat = dictationFailureView?.isHidden == false
            ? (dictationFailureView?.systemLayoutSizeFitting(
                CGSize(width: max(width - 32, 1), height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height ?? 0) + 4
            : 0
        let failure: CGFloat = sendFailureLabel?.isHidden == false
            ? (sendFailureLabel?.sizeThatFits(CGSize(width: max(width - 32, 1), height: .greatestFiniteMagnitude)).height ?? 0)
            : 0
        let height = max(barHeight + dictation + failure, 1)
        if abs((composerHeightConstraint?.constant ?? 0) - height) > 0.5 {
            composerHeightConstraint?.constant = height
        }
        // The grid keeps only the bar's resting height. A longer draft,
        // attachments, suggestions, and the failure banners grow over it,
        // so the remote terminal is not resized while you compose.
        let reserved = min(bar.restingHeight(fittedHeight: barHeight, width: width), height)
        composerReservedHeight = reserved
        composerCoveredHeight = height - reserved
        updateBottomRows()
    }

    private func cursorMayHaveMoved() {
        // A synchronized-output hold still shows the last picture.
        guard composerCoveredHeight > 0, !channel.engine.renderHeld else { return }
        updateCursorShift()
    }

    /// Moves the grid's picture up so the program's cursor row stays above
    /// a chat bar that grew over the grid. The grid's size does not change.
    /// The picture holds still while you read history and while a finger is
    /// on it or it coasts: moving the grid then would move the scroll
    /// under the finger. It eases to the live position when that ends.
    private func updateCursorShift() {
        guard let gridView else { return }
        let cellHeight = gridView.cellSize.height
        let held = detached || gridView.isHistoryScrolling
        let settling = cursorShiftHeld && !held
        cursorShiftHeld = held
        let shift = held
            ? SSHTerminalComposerOverlap.held(
                -gridView.transform.ty, covered: composerCoveredHeight, cellHeight: cellHeight
            )
            : SSHTerminalComposerOverlap.shift(
                gridHeight: gridView.bounds.height,
                covered: composerCoveredHeight,
                cursorRow: channel.engine.cursorCell.row,
                cellHeight: cellHeight
            )
        let scale = max(view.traitCollection.displayScale, 1)
        let snapped = (shift * scale).rounded(.up) / scale
        let transform = snapped > 0 ? CGAffineTransform(translationX: 0, y: -snapped) : .identity
        guard gridView.transform != transform else { return }
        if settling, !reduceMotion, gridView.window != nil {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                gridView.transform = transform
            }
        } else {
            gridView.transform = transform
        }
    }

    // MARK: - Mode

    private var keymapProgram: String {
        SSHTerminalAgentDetection.keymapProgram(root: channel.programStatus.liveRoot, app: channel.programStatus.app(of: ""))
    }

    private var programIsStopped: Bool { !channel.connected && !channel.connecting }
    private var programRollup: SessionStatusRollup? {
        SSHTerminalProgramStatusPresentation.rollup(
            store: channel.programStatus,
            isStopped: programIsStopped
        )
    }
    private var visibleNotice: SSHTerminalNotice? {
        attention.notice(from: SSHTerminalAttention.candidates(
            programStatus: channel.programStatus, alerts: channel.alerts, isStopped: programIsStopped
        ))
    }
    private var programStatusRows: [SSHTerminalStatusRow] {
        SSHTerminalProgramStatusPresentation.detailRows(
            store: channel.programStatus,
            isStopped: programIsStopped
        )
    }
    private var statusText: String {
        if channel.networkChanged { return "Network changed \u{2014} checking the connection\u{2026}" }
        return channel.connecting ? channel.reason : "Disconnected \u{00b7} \(channel.reason)"
    }

    private func showTerminalKeyboard() {
        // During a password prompt typing is already the terminal's: bring its
        // keyboard back without making that the user's choice, so the chat bar
        // still returns (with the keyboard) when the prompt ends.
        if automaticTerminalTyping {
            refocusAfterSecurePrompt = true
            askForTerminalKeyboard()
            return
        }
        manualInputChoice()
        inputMode = .terminal
        askForTerminalKeyboard()
    }

    /// The Chat Bar button: the chat bar, with its keyboard up. From the
    /// terminal's keyboard the bar focuses once that keyboard has gone.
    private func focusChatBar() {
        guard !rawKeyboard else { return showChatBar() }
        wantsTerminalKeyboard = false
        manualInputChoice()
        inputMode = .chat
        composerFocusRequest += 1
        setNeedsUpdateProperties()
    }

    private func showChatBar() {
        wantsTerminalKeyboard = false
        manualInputChoice()
        inputMode = .chat
        focusComposerAfterRaw = true
        _ = gridView?.resignFirstResponder()
        setNeedsUpdateProperties()
    }

    /// Typing moved off the chat bar automatically for a password prompt; the
    /// input bar comes back when that prompt ends. Choosing **Chat Bar** in the
    /// meantime wins over the automatic switch back. **Type in Terminal** only
    /// brings the keyboard back, and a tap on the grid is never a choice.
    private var automaticTerminalTyping = false
    /// Whether ending the automatic switch focuses the chat bar it puts back.
    /// Hiding the keyboard during the prompt keeps the bar, not the keyboard,
    /// until Type in Terminal brings it back.
    private var refocusAfterSecurePrompt = true

    private func manualInputChoice() {
        automaticTerminalTyping = false
    }

    /// The terminal is the input, but the grid has not taken the keyboard yet.
    /// UIKit refuses an ask that lands while the chat bar's text view is still
    /// resigning, and the pass that unships the bar ends that editing at the
    /// same moment, so a dropped ask leaves nothing focused — no keyboard at a
    /// password prompt. The screen asks again on its next pass until the grid
    /// holds it. Cleared when typing goes back to the chat bar, and when the
    /// person sends the keyboard away.
    private var wantsTerminalKeyboard = false

    private func askForTerminalKeyboard() {
        wantsTerminalKeyboard = true
        // Ask now too: a key strip tap or a prompt should not wait a pass.
        DispatchQueue.main.async { [weak self] in self?.takeTerminalKeyboard() }
        setNeedsUpdateProperties()
    }

    private func takeTerminalKeyboard() {
        guard wantsTerminalKeyboard, inputMode == .terminal,
              let grid = gridView, grid.window != nil
        else { return }
        if !grid.isFirstResponder { _ = grid.becomeFirstResponder() }
        if grid.isFirstResponder { wantsTerminalKeyboard = false }
    }

    /// The user sent the keyboard away. During an automatic switch for a
    /// password prompt that only keeps the keyboard down when the prompt ends;
    /// the chat bar still comes back there. Any other hide changes nothing.
    private func keyboardWasHidden() {
        wantsTerminalKeyboard = false
        guard automaticTerminalTyping else { return }
        refocusAfterSecurePrompt = false
    }

    /// A password prompt appeared or ended. Oppi never types a secret into the
    /// chat bar: the bar is a draft the user can read, save, and dictate into,
    /// so the input moves to the terminal while the prompt is up.
    private func secureInputChanged(_ secure: Bool) {
        secureEntryActive = secure
        if !secure, passwordFillTask != nil {
            passwordFillPromptEnded = true
            passwordFillTask?.cancel()
        }
        setNeedsUpdateProperties()
        if secure {
            guard !automaticTerminalTyping, inputMode == .chat, !rawKeyboard else { return }
            automaticTerminalTyping = true
            refocusAfterSecurePrompt = true
            inputMode = .terminal
            askForTerminalKeyboard()
        } else {
            guard automaticTerminalTyping else { return }
            automaticTerminalTyping = false
            wantsTerminalKeyboard = false
            // The prompt only starts from the chat bar, so that is what returns.
            inputMode = .chat
            if refocusAfterSecurePrompt { focusComposerAfterRaw = true }
            // The bar comes back either way; a keyboard the user hid stays down.
            composerSession?.setSuppressKeyboard(!refocusAfterSecurePrompt)
            refocusAfterSecurePrompt = true
            _ = gridView?.resignFirstResponder()
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Fill Password

    /// The saved host the channel being typed into belongs to, which says
    /// whether there is a password to fill. Read from that channel, not from
    /// the session: while the screen swaps to another terminal the session can
    /// already stand for the next one.
    private var passwordFillProfile: SSHTerminalProfile? { session?.profile(of: channel) ?? previewFillProfile }

    /// The screenshot preview has no connect session; it names the host here.
    var previewFillProfile: SSHTerminalProfile?

    private func isPasswordFillOffered(connected: Bool? = nil) -> Bool {
        SSHTerminalPasswordFill.isOffered(
            profile: passwordFillProfile,
            secureEntry: secureEntryActive,
            inHistory: detached,
            connected: connected ?? channel.connected
        )
    }

    /// One decision for both keys: the chat bar's strip and the keyboard bar's.
    private func updatePasswordFill(connected: Bool) {
        let host = isPasswordFillOffered(connected: connected) ? passwordFillProfile?.endpointLabel : nil
        composerKeyStrip?.setPasswordFill(host: host)
        gridView?.setPasswordFill(host: host)
    }

    /// Asks for Face ID, then types the saved password at the prompt without
    /// pressing Return. Nothing is typed when the person cancels, the check
    /// fails, or the prompt is gone by the time it passes. Right before the
    /// send the live screen decides, not the secure-entry latch: that moves
    /// with painted frames, which stop under Face ID.
    private func fillPassword() {
        guard passwordFillTask == nil, isPasswordFillOffered(), let profile = passwordFillProfile,
              let grid = gridView, let prompt = grid.passwordFillPrompt() else { return }
        let channel = channel
        passwordFillPromptEnded = false
        passwordFillTask = Task { [weak self, weak grid] in
            let outcome = await SSHTerminalPasswordFill.fill(
                profile: profile,
                promptIsLive: { [weak self, weak grid] in
                    guard let self, let grid else { return false }
                    return self.channel === channel && self.isOnScreen && grid.passwordPromptIsLive(matching: prompt)
                },
                send: { channel.send($0) }
            )
            guard let self, self.channel === channel else { return }
            self.passwordFillTask = nil
            switch outcome {
            case .filled: self.showPasteNotice("Filled password")
            case .cancelled:
                // The prompt ending dismissed the check itself.
                if self.passwordFillPromptEnded { self.showPasteNotice("Password not filled. The prompt ended.") }
            case .promptEnded: self.showPasteNotice("Password not filled. The prompt ended.")
            case .failed(let message): self.showPasteNotice("Password not filled. \(message)")
            }
        }
    }

    // MARK: - Presentations

    /// The multiplexer a trailing bar action opens the overview of.
    private func overview(_ action: SSHTerminalBarAction) -> (any SSHTerminalOverviewSource)? {
        // Rex and Herdr are experiments (Settings → Experiments): off, there is
        // nothing to read, so no button and no poll.
        guard SSHTerminalExperimentAccess.current.allows(action) else { return nil }
        return switch action {
        // Herdr is read with side commands, which a terminal without SSH has none of.
        case .herdr: channel.sideCommandsUnavailable == nil ? herdr : nil
        case .rex: rex
        default: nil
        }
    }

    /// Panes that need you, per multiplexer that has answered.
    private var overviewsWaiting: [SSHTerminalBarAction: Int] {
        var waiting: [SSHTerminalBarAction: Int] = [:]
        for action in SSHTerminalBarAction.overviews where !barContext.overviewsRuledOut.contains(action) {
            if let source = overview(action), source.available { waiting[action] = source.needsAttention }
        }
        return waiting
    }

    private func showOverview(_ action: SSHTerminalBarAction) {
        guard !presentingOverview, let source = overview(action) else { return }
        presentingOverview = true
        source.watching = true
        // A Rex pane opens here, in a terminal of its own over the same host.
        rex.openPane = { [weak self] pane in self?.openRexPane(pane) }
        let channel = channel
        Router.present(
            SSHTerminalOverviewViewController(
                content: source,
                isSheet: true,
                refresh: { await source.refresh(on: channel) },
                activate: { await source.activate($0, on: channel) }
            ),
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: self,
            onDismiss: { [weak self] in
                self?.presentingOverview = false
                source.watching = false
            }
        )
    }

    /// The Rex panel: this pane's status, the session's panes, and the other
    /// sessions, in one sheet (`SSHTerminalRexPanelContent`). Switching a pane
    /// and a new pane go through the owners a swipe uses; another session's pane
    /// opens through the one that Rex Sessions used.
    private func showRexPanel() {
        guard !presentingOverview, let model = channel.rex else { return }
        presentingOverview = true
        let sessionID = model.sessionID
        let monitor = rex
        monitor.watching = true
        monitor.openPane = { [weak self] pane in self?.openRexPane(pane) }
        let content = SSHTerminalRexPanelContent(
            monitor: monitor,
            settings: rexPanelSettings,
            sessionID: sessionID,
            sessionState: { [weak model] in model?.state },
            statusRows: { [weak self, weak model] in
                guard let self else { return [] }
                let own = programStatusRows
                if !own.isEmpty { return own }
                let state = model?.state
                return SSHTerminalRexPanelContent.statusRows(from: state?.panes.first { $0.blockID == state?.shown }?.records ?? [])
            }
        )
        let channel = channel
        Router.present(
            SSHTerminalOverviewViewController(
                content: content,
                isSheet: true,
                refresh: { await monitor.refresh(on: channel) },
                activate: { [weak self] focus in self?.activateRexPanel(focus, sessionID: sessionID) ?? false }
            ),
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: self,
            onDismiss: { [weak self] in
                self?.presentingOverview = false
                monitor.watching = false
            }
        )
    }

    /// A tapped row of the Rex panel: a pane of this session is shown, New Pane
    /// opens one, and a pane of another session opens on this device.
    private func activateRexPanel(_ focus: SSHTerminalOverviewFocus, sessionID: String) -> Bool {
        if focus == SSHTerminalRexPanelContent.newPaneFocus { return gridView?.createPane() ?? false }
        if focus.scope == sessionID || focus.scope == nil {
            showPane(focus.id)
            return true
        }
        return rex.open(focus)
    }

    private func openRexPane(_ pane: RexPaneTarget) {
        if let rexPaneOpener { rexPaneOpener(pane) } else { session?.openRexPane(pane) }
    }

    private func showStatusDetail() {
        guard !presentingStatusDetail else { return }
        presentingStatusDetail = true
        Router.present(
            SSHTerminalStatusDetailController(
                hostLabel: hostLabel,
                rows: programStatusRows,
                themeID: chromeTheme
            ),
            presentation: .popover.keepsPopoverInCompactWidth(),
            from: self,
            sourceView: statusGlyph,
            onDismiss: { [weak self] in self?.presentingStatusDetail = false }
        )
    }

    // MARK: - Opening links and paths

    /// The SSH host, as the saved profile names it. Nothing opens paths on a
    /// host this terminal was not told about.
    private var sshHost: String {
        (session?.connectedProfile?.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paired Oppi server that is this same machine, if any. Only then can
    /// a path open in Oppi's own file routes.
    private var pairedServer: PairedServer? {
        guard let root = AppRootEnvironment.near(self), !sshHost.isEmpty else { return nil }
        let servers = root.coordinator.serverStore.servers
        let paired = servers.map { (id: $0.id, host: $0.host) }
        guard let id = SSHTerminalServerMatch.serverId(forHost: sshHost, paired: paired) else { return nil }
        return servers.first { $0.id == id }
    }

    /// Open and Copy for a held link, URL, or path. A path needs a paired
    /// server, and a path outside that server's home is not offered at all:
    /// owner-host files are rooted at the user's home there.
    private func heldOpenTarget(_ held: SSHTerminalHeldCell) -> SSHTerminalOpenTarget? {
        let folder = channel.workingDirectory.isEmpty ? nil : channel.workingDirectory
        guard let target = SSHTerminalOpenResolution.target(
            text: held.text, hyperlink: held.hyperlink, folder: folder
        ) else { return nil }
        guard target.path != nil else { return target }
        guard pairedServer != nil else { return nil }
        if let home = pairedHome, let path = absoluteHostPath(target.path ?? ""), !SSHTerminalHostPathPolicy.isInside(home: home, path: path) {
            return nil
        }
        return target
    }

    private func open(_ target: SSHTerminalOpenTarget) {
        switch target {
        case .web(let url, _):
            // The app's one open owner applies the link browser preference.
            AppRootEnvironment.near(self)?.opener.open(.webLink(url))
        case .path(let path):
            openHostPath(path)
        }
    }

    /// `~/…` needs the server's home; an absolute path is already resolved.
    private func absoluteHostPath(_ path: String) -> String? {
        guard path.hasPrefix("~/") else { return path.hasPrefix("/") ? path : nil }
        guard let home = pairedHome else { return nil }
        let rest = String(path.dropFirst(2))
        return SSHTerminalPathResolution.absolute(rest, relativeTo: home)
    }

    private func openHostPath(_ path: String) {
        guard let server = pairedServer, let root = AppRootEnvironment.near(self),
              let api = root.coordinator.apiClient(for: server.id) else {
            showOpenNotice("This host is not a paired Oppi server, so its files can only be copied.")
            return
        }
        showOpenNotice("Opening \(path.split(separator: "/").last.map(String.init) ?? path)…")
        startOpenTask { [weak self] in
            guard let self else { return }
            do {
                let home = try await Self.hostHome(api: api)
                guard !Task.isCancelled else { return }
                self.pairedHome = home
                guard let target = self.absoluteHostPath(path) else {
                    self.showOpenNotice("That path cannot be resolved on the host.")
                    return
                }
                let status = try await api.getHostPathStatus(path: target)
                guard !Task.isCancelled else { return }
                switch SSHTerminalHostPathPolicy.plan(status: status, home: home) {
                case .file(let file):
                    self.pushHostFile(serverId: server.id, path: file, root: root)
                case .folder(let folder):
                    self.pushHostFolder(serverId: server.id, folder: folder, home: home, root: root)
                case .refused(let reason):
                    self.showOpenNotice(reason)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.showOpenNotice("That path could not be opened on the host.")
            }
        }
    }

    /// The folder the shell reported: the Files browser at it, on its server.
    private func browseFilesHere() {
        guard let server = pairedServer, let root = AppRootEnvironment.near(self),
              let api = root.coordinator.apiClient(for: server.id) else { return }
        let folder = channel.workingDirectory
        startOpenTask { [weak self] in
            guard let self else { return }
            do {
                let home = try await Self.hostHome(api: api)
                guard !Task.isCancelled else { return }
                self.pairedHome = home
                guard SSHTerminalHostPathPolicy.isInside(home: home, path: folder) else {
                    self.showOpenNotice("Files open inside the server's home folder.")
                    return
                }
                self.pushHostFolder(serverId: server.id, folder: folder, home: home, root: root)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.showOpenNotice("The server's home folder could not be read.")
            }
        }
    }

    /// One Open or Browse at a time, and never after the screen was left: a
    /// second choice replaces the first, and Back before the lookup finishes
    /// does not push onto the screen below.
    private func startOpenTask(_ work: @escaping @MainActor () async -> Void) {
        openTask?.cancel()
        openTaskGeneration &+= 1
        let generation = openTaskGeneration
        openTask = Task { [weak self] in
            await work()
            guard let self, self.openTaskGeneration == generation else { return }
            self.openTask = nil
        }
    }

    private static func hostHome(api: APIClient) async throws -> String {
        let status = try await api.getHostPathStatus(path: "~")
        guard status.resolvedPath.hasPrefix("/") else { throw SSHTerminalHostFilesError.homePathInvalid }
        return status.resolvedPath
    }

    /// The viewer opens a file through its own server, above this terminal.
    private func pushHostFile(serverId: String, path: String, root: AppRootEnvironment) {
        guard navigationController?.topViewController === self else { return }
        let target = WorkspaceLinkedFileNavTarget.hostFile(serverId: serverId, workspaceId: "", path: path)
        Router.push(
            WorkspaceLinkedFileViewController(target: target, placement: .pushed, root: root),
            from: self
        )
    }

    /// The Files browser lists host folders home-relative, so the folder is
    /// passed the way its own navigation builds it: no home prefix, a trailing
    /// slash, and empty for the home folder itself.
    private func pushHostFolder(serverId: String, folder: String, home: String, root: AppRootEnvironment) {
        guard navigationController?.topViewController === self else { return }
        let trimmedHome = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        var relative = folder == trimmedHome ? "" : String(folder.dropFirst(trimmedHome.count + 1))
        if !relative.isEmpty, !relative.hasSuffix("/") { relative += "/" }
        Router.push(
            FileBrowserViewController(
                root: root,
                target: .hostHome(serverId: serverId, path: relative),
                showsSidebarToggle: false
            ),
            from: self
        )
    }

    /// The server's home folder, fetched once per terminal so the hold menu
    /// can tell an owner-host path from one the file routes cannot reach.
    private func refreshPairedHome() {
        guard pairedHome == nil, pairedHomeTask == nil, let server = pairedServer,
              let api = AppRootEnvironment.near(self)?.coordinator.apiClient(for: server.id) else { return }
        pairedHomeTask = Task { [weak self] in
            let home = try? await Self.hostHome(api: api)
            guard let self else { return }
            self.pairedHomeTask = nil
            guard let home else { return }
            self.pairedHome = home
            self.setNeedsUpdateProperties()
        }
    }

    private func showOpenNotice(_ text: String, retry: (() -> Void)? = nil) {
        openNotice = text
        openNoticeRetry = retry
        openNoticeTask?.cancel()
        // A notice that offers a retry waits for it: the person may have to start
        // the program by hand first, and the reason is still worth reading then.
        // It leaves on Retry, on success, or when the connection goes.
        openNoticeTask = nil
        if retry == nil {
            openNoticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.openNotice = nil
                self?.openNoticeRetry = nil
                self?.setNeedsUpdateProperties()
            }
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Paste

    private var pasteLineCount: Int { SSHTerminalEngine.pasteLineCount(pendingPaste ?? "") }

    private func requestPaste(_ text: String?) {
        guard channel.connected else { channel.send(Data()); return }
        guard let text else {
            showPasteNotice("Nothing pasted \u{2014} the clipboard has no text, or paste access was not allowed.")
            return
        }
        guard text.utf8.count <= SSHTerminalEngine.maximumPasteBytes else {
            presentPasteFailure("Pastes are limited to 64 KiB.")
            return
        }
        if SSHTerminalEngine.pasteNeedsConfirmation(text) {
            pendingPaste = text
            Confirmation(
                title: "Paste \(pasteLineCount) \(pasteLineCount == 1 ? "line" : "lines")?",
                message: "This text contains a newline or terminal control sequence and may run commands. Paste only text you trust.",
                actionTitle: "Paste",
                style: .alert,
                isDestructive: false
            ).present(from: self, anchor: nil) { [weak self] in
                guard let self, let text = self.pendingPaste else { return }
                self.pendingPaste = nil
                do { try self.channel.paste(text, confirmed: true) }
                catch { self.presentPasteFailure("Paste was not sent. \(error.localizedDescription)") }
            } onCancel: { [weak self] in
                self?.pendingPaste = nil
            }
        } else {
            do { try channel.paste(text) }
            catch { presentPasteFailure("Paste was not sent. \(error.localizedDescription)") }
        }
    }

    /// Saves the image on the host like a chat-bar attachment, then pastes
    /// its path. Claude Code and pi read a pasted image path as the image.
    private func pasteImage(_ image: SSHTerminalPastedImage) {
        guard channel.connected else { channel.send(Data()); return }
        if let reason = channel.sideCommandsUnavailable {
            presentPasteFailure("The image was not pasted. \(reason)")
            return
        }
        let channel = channel
        showPasteNotice("Saving the image on the host\u{2026}")
        Task { [weak self] in
            do {
                let path = try await channel.upload(image.data, fileExtension: image.fileExtension)
                try channel.paste(path)
                self?.showPasteNotice("Pasted the image's path.")
            } catch {
                self?.presentPasteFailure("The image was not pasted. \(error.localizedDescription)")
            }
        }
    }

    private func presentPasteFailure(_ message: String) {
        errorAlerts.show(title: "Paste Not Sent", message: message)
    }

    private func showPasteNotice(_ text: String) {
        pasteNotice = text
        pasteNoticeTask?.cancel()
        pasteNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.pasteNotice = nil
            self?.setNeedsUpdateProperties()
        }
        setNeedsUpdateProperties()
    }

    private func showCopyNotice() {
        let count = channel.lastCopyLength
        copyNoticeText = "Copied \(count) \(count == 1 ? "character" : "characters")"
        copyNoticeTask?.cancel()
        copyNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copyNoticeText = nil
            self?.setNeedsUpdateProperties()
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Lifecycle

    /// "Open Terminal here" on a host whose Run on Connect command starts a
    /// multiplexer that opens folders inside its own terminal (Herdr): the
    /// folder is focused, or created, on this already-connected terminal, over
    /// its side exec channel. Nothing is typed into the program.
    ///
    /// One attempt per connection, and a failed one offers Retry: a Herdr that
    /// was not running yet can be started by hand in the terminal underneath and
    /// then opened without leaving it.
    private func openMultiplexerFolderIfNeeded() {
        guard let session, let target = session.multiplexerFolder, channel.connected,
              let kind = SSHTerminalMultiplexerKind.detected(in: session.connectedProfile?.commandOnConnect()),
              case .inHostTerminal(let run)? = kind.multiplexer.opening(target) else { return }
        session.multiplexerFolder = nil
        openFolderInMultiplexer(target, multiplexer: kind.multiplexer, run: run)
    }

    /// Runs, or re-runs from Retry, the multiplexer's folder open on this
    /// connection. A refusal shows over the terminal, which is where the person
    /// stays either way; the notice keeps its Retry until that is used, the open
    /// succeeds, or the connection goes away.
    private func openFolderInMultiplexer(
        _ target: SSHTerminalFolderTarget,
        multiplexer: any SSHTerminalMultiplexer,
        run: @escaping (SSHTerminalChannel) async throws -> Void
    ) {
        // Whatever this notice said is answered by this attempt, which reports
        // its own result when it finishes.
        openNotice = nil
        openNoticeRetry = nil
        openNoticeTask?.cancel()
        setNeedsUpdateProperties()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await run(channel)
                showOpenNotice("Opened \(target.folderLabel) in \(multiplexer.name).")
                await herdr.refresh(on: channel)
            } catch {
                // The reason leads, and the folder is its last name: a phone
                // notice has room for one line of each.
                showOpenNotice(
                    Self.failureNotice(target: target, multiplexer: multiplexer, error: error),
                    retry: { [weak self] in
                        guard let self, channel.connected else { return }
                        openFolderInMultiplexer(target, multiplexer: multiplexer, run: run)
                    }
                )
            }
        }
    }

    /// "Herdr is not running. oppi did not open in Herdr." — the reason first,
    /// then the folder by its own name and the program that refused it.
    private static func failureNotice(
        target: SSHTerminalFolderTarget,
        multiplexer: any SSHTerminalMultiplexer,
        error: any Error
    ) -> String {
        var reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty, !".!?".contains(reason.last ?? ".") { reason += "." }
        return "\(reason) \(target.folderName) did not open in \(multiplexer.name)."
    }

    /// The Experiments switch changed: the bar's Rex and Herdr buttons, the
    /// overview polls, and Customize Bar follow it now. A Rex terminal is a pane
    /// of a session Oppi may no longer read, and the registry ends it where it
    /// was the one that turned off.
    private func experimentChanged() {
        if !AppPreferenceStore.Experiments.rexEnabled { stopOverview(.rex) }
        if !AppPreferenceStore.Experiments.herdrEnabled { stopOverview(.herdr) }
        setNeedsUpdateProperties()
    }

    /// Stops one multiplexer's overview poll (its read), leaving the other alone.
    private func stopOverview(_ action: SSHTerminalBarAction) {
        overviewTasks.removeValue(forKey: action)?.cancel()
    }

    /// A terminal's Rex monitor tells the Terminal tab what it found on the
    /// host (`SSHTerminalRexHostStore`): a host Rex was read on gets a live Rex
    /// section there, and one with no `rex` loses it. It reaches the host's
    /// Rex over Tailscale when it can (`RexRoutePlan`).
    /// A Rex reached over Tailscale alone is no saved host: it is followed
    /// straight over Tailscale and nothing is recorded for it.
    static func makeRexMonitor(for profile: SSHTerminalProfile?, hosts: SSHTerminalRexHostStore?) -> RexMonitor {
        if profile?.rexTailnet != nil { return RexMonitor.forTerminal(of: profile) }
        let monitor = RexMonitor(directHost: profile.map(RexDirectHost.init))
        if let profile, let hosts {
            monitor.onFinding = { hosts.record($0, on: profile) }
        }
        return monitor
    }

    private func stopOverviewPolls() {
        overviewTasks.values.forEach { $0.cancel() }
        overviewTasks = [:]
    }

    private func updatePolling() {
        // Herdr, Rex, and keymaps load again when you return; they do not run off screen.
        guard isOnScreen else {
            stopOverviewPolls()
            keymapTask?.cancel()
            keymapTask = nil
            keymapToken = nil
            colorTask?.cancel()
            colorTask = nil
            colorToken = nil
            return
        }
        if channel.connected {
            openMultiplexerFolderIfNeeded()
            for action in SSHTerminalBarAction.overviews where overviewTasks[action] == nil {
                guard barContext.polls(action), let source = overview(action) else { continue }
                let channel = channel
                overviewTasks[action] = Task { await source.run(on: channel) }
            }
        } else {
            stopOverviewPolls()
        }
        let dark = appIsDark
        // The host's Ghostty colors are read with side commands; a terminal
        // without them keeps the colors it has (Oppi's theme, or the last read).
        let readsColors = channel.connected && colorChoice != .oppi && channel.sideCommandsUnavailable == nil
        let colorKey = readsColors ? "\(colorChoice)|\(dark)" : nil
        if colorToken != colorKey {
            colorToken = colorKey
            colorTask?.cancel()
            colorTask = nil
            if colorKey != nil {
                let channel = channel
                let choice = colorChoice
                colorTask = Task { [weak self] in
                    await self?.colorLoader.load(choice: choice, dark: dark) { try await channel.run($0) }
                }
            }
        }
        let token = channel.connected ? keymapProgram : nil
        if keymapToken != token {
            keymapToken = token
            keymapTask?.cancel()
            keymapTask = Task { [weak self] in
                guard let self else { return }
                await self.keymap.load(program: token, on: self.channel)
            }
        }
    }

    /// A fresh sign-in, with the same approval as Reconnect: no prompt when the
    /// person approved within the last few minutes. The flag stays set until
    /// App Lock no longer covers Oppi. A terminal you had already left is not
    /// reconnected: only a close that happened while this screen was showing.
    private func reconnectAfterReturn() {
        guard reconnectOnReturn, AppScenePhase.shared.phase == .active, !AppLockService.shared.requiresUnlock() else { return }
        reconnectOnReturn = false
        reconnect()
    }

    private func reduceMotionChanged() {
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        setNeedsUpdateProperties()
    }
}

/// Back swipe with the bar hidden. The navigation controller's own delegate
/// filters touches through a private event check that refuses every touch
/// while the bar is hidden, and this screen always hides it. While the
/// terminal is on top, this delegate answers with
/// the navigation controller's public decisions only: same edge, same Back
/// button exclusion, same begin rule.
private final class SSHTerminalBackSwipe: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private weak var original: (any UIGestureRecognizerDelegate)?

    init?(navigation: UINavigationController?) {
        guard let navigation, let gesture = navigation.interactivePopGestureRecognizer else { return nil }
        self.navigation = navigation
        original = gesture.delegate
        super.init()
        gesture.delegate = self
    }

    func uninstall() {
        guard let gesture = navigation?.interactivePopGestureRecognizer, gesture.delegate === self else { return }
        gesture.delegate = original
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        original?.gestureRecognizer?(gesture, shouldReceive: touch) ?? true
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.viewControllers.count > 1 else { return false }
        return original?.gestureRecognizerShouldBegin?(gesture) ?? true
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        original?.gestureRecognizer?(gesture, shouldRecognizeSimultaneouslyWith: other) ?? false
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        original?.gestureRecognizer?(gesture, shouldRequireFailureOf: other) ?? false
    }
}
