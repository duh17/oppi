import UIKit

/// Live SSH terminal: UIKit owns the screen, floating controls, grid,
/// notices, lists, and chat bar (`ComposerBarController` in a terminal
/// configuration). The navigation bar stays hidden while this screen is on
/// top; Back, status, Herdr, and the … menu sit in a glass bar at the bottom
/// edge, below the grid, so they never cover a terminal row.
@MainActor
final class SSHTerminalViewController: UIViewController, RouterHidesNavigationBar {
    private(set) var channel: SSHTerminalChannel
    private let reconnect: () -> Void
    private let editHost: () -> Void
    private let hostLabel: String
    private weak var session: SSHTerminalConnectSession?
    /// Screenshot preview only: a server-scoped connection so the hosted
    /// composer can claim dictation. The live app uses the window's root.
    private let composerConnection: ServerConnection?
    /// Screenshot preview only. A normal launch never sets this.
    var presentsStatusDetailOnAppear = false

    private(set) var gridView: SSHTerminalGridView?
    private let overlay = SSHTerminalPassthroughView()
    /// The bottom bar's container: Back at the leading edge, status, Herdr,
    /// and … at the trailing one. It ends at the keyboard layout guide, so
    /// with a docked keyboard up (and a broken connection, the one case that
    /// keeps the bar) it floats just above the keyboard.
    private let bottomBar = SSHTerminalPassthroughView()
    private var bottomBarHeight: NSLayoutConstraint?
    private let topStack = UIStackView()
    private let backPill = SSHTerminalBackPill()
    private let connectionBanner = SSHTerminalConnectionBannerView()
    private let inputBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.inputNotice")
    private let pasteBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.pasteNotice")
    private let openBanner = SSHTerminalTextBannerView(identifier: "sshTerminal.openNotice")
    private let noticeCard = SSHTerminalNoticeCardView()
    private let copyNotice = SSHTerminalCopyNoticeView()
    private let backToLive = SSHTerminalBackToLiveButton()
    private let statusGlyph = SSHTerminalStatusGlyphButton()
    private lazy var morePill = SSHTerminalMorePill(status: statusGlyph)
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
    private var detached = false
    /// The cursor shift was held for history or a touch on the last update.
    private var cursorShiftHeld = false
    private var rawKeyboard = false
    private var herdr = HerdrMonitor()
    private var keymap = SSHTerminalKeymapLoader()
    private var modeOverride: SSHTerminalInputMode?
    private var lastDetectedMode: SSHTerminalInputMode?
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
    private var herdrTask: Task<Void, Never>?
    private var keymapTask: Task<Void, Never>?
    private var keymapToken: String?
    /// The registry closed this terminal while this screen was showing.
    private var sawClosedForBackground = false
    private var isOnScreen = false
    private var presentingHerdr = false
    private var presentingStatusDetail = false
    private var reduceMotion = UIAccessibility.isReduceMotionEnabled
    private var lastThemeID: ThemeID?
    private var defaultsObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var keyboardObserver: NSObjectProtocol?

    init(
        channel: SSHTerminalChannel,
        reconnect: @escaping () -> Void,
        editHost: @escaping () -> Void,
        hostLabel: String = "",
        session: SSHTerminalConnectSession? = nil,
        composerConnection: ServerConnection? = nil
    ) {
        self.channel = channel
        self.reconnect = reconnect
        self.editHost = editHost
        self.hostLabel = hostLabel
        self.session = session
        self.composerConnection = composerConnection
        super.init(nibName: nil, bundle: nil)
        attention.glyphFrame.rect = .zero
        statusGlyph.glyphFrame.rect = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.experimentChanged()
        }
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reduceMotionChanged()
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
        // Back and the actions float over the grid instead.
        navigationController?.setNavigationBarHidden(true, animated: animated)
        applyControlsVisibility(animation: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        backSwipe?.uninstall()
        backSwipe = SSHTerminalBackSwipe(navigation: navigationController)
        // Remote clipboard writes apply only while this screen is in front.
        channel.isViewed = AppScenePhase.shared.phase == .active
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
        // The incoming screen needs its Back and title.
        navigationController?.setNavigationBarHidden(false, animated: animated)
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
        pasteNoticeTask?.cancel()
        copyNoticeTask?.cancel()
        openNoticeTask?.cancel()
        pairedHomeTask?.cancel()
        pairedHomeTask = nil
        openTask?.cancel()
        openTask = nil
        herdrTask?.cancel()
        herdrTask = nil
        keymapTask?.cancel()
        keymapTask = nil
        keymapToken = nil
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
    }

    override func updateProperties() {
        super.updateProperties()
        if let session, let next = session.channel, next !== channel {
            replaceChannel(next)
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
        _ = channel.workingDirectory
        _ = channel.alerts.notification
        _ = channel.alerts.bell
        _ = herdr.snapshot
        _ = herdr.failure
        _ = herdr.available
        _ = keymap.actions
        _ = keymap.profile
        _ = keymap.userFile
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
        let themeID = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        _ = HostFactory.root(near: self)?.themeStore.appTheme

        if lastThemeID != themeID {
            lastThemeID = themeID
            applyTheme(themeID)
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
        if let session, !session.showsTerminal, isOnScreen, !isMovingFromParent {
            Router.finish(self)
        }

        let detected = detectedMode
        if detected != lastDetectedMode {
            lastDetectedMode = detected
            modeOverride = nil
            if detected == .chat && rawKeyboard {
                focusComposerAfterRaw = true
                _ = gridView?.resignFirstResponder()
            }
        }

        navigationItem.title = channel.title.isEmpty ? "SSH Terminal" : channel.title
        updatePolling()
        refreshPairedHome()
        updateFloatingControls(themeID: themeID)
        updateBanners(connecting: connecting, connected: connected, networkChanged: networkChanged, themeID: themeID)
        updateNotice(themeID: themeID)
        updateCopyAndLive(themeID: themeID)
        updateComposer()
        if let gridView {
            gridView.tapTypesInTerminal = inputMode == .terminal
            gridView.setKeyActions(keymap.actions)
            gridView.showModifiers()
            gridView.applyTheme(themeID)
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
        morePill.herdr.addAction(UIAction { [weak self] _ in self?.showHerdr() }, for: .touchUpInside)
        connectionBanner.onReconnect = { [weak self] in self?.reconnect() }
        noticeCard.onDismiss = { [weak self] key in
            self?.attention.dismiss(key)
            self?.setNeedsUpdateProperties()
        }
        noticeCard.onFrameChange = { [weak self] in self?.attention.cardFrame = $0 }
        backToLive.addAction(UIAction { [weak self] _ in
            self?.gridView?.backToLive()
        }, for: .touchUpInside)
        statusGlyph.onOpen = { [weak self] in self?.showStatusDetail() }

        connectionBanner.isHidden = true
        inputBanner.isHidden = true
        pasteBanner.isHidden = true
        openBanner.isHidden = true
        noticeCard.isHidden = true
        copyNotice.isHidden = true
        backToLive.isHidden = true
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

        overlay.addSubview(topStack)
        overlay.addSubview(copyNotice)
        overlay.addSubview(backToLive)
        copyNotice.translatesAutoresizingMaskIntoConstraints = false
        backToLive.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Notices float at the grid's top edge and keep the bar's place
            // out of the way: they never change the grid's size.
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
        bottomBar.addSubview(morePill)

        gridClip.translatesAutoresizingMaskIntoConstraints = false
        gridClip.clipsToBounds = true
        view.addSubview(gridClip)
        view.addSubview(overlay)
        view.addSubview(bottomBar)
        let controlsInset: CGFloat = 12
        let barHeight = bottomBar.heightAnchor.constraint(equalToConstant: SSHTerminalBottomBar.shownHeight)
        bottomBarHeight = barHeight
        NSLayoutConstraint.activate([
            // Clear of a landscape notch: the grid runs edge to edge, the
            // controls stay inside the safe area.
            backPill.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: controlsInset),
            backPill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
            morePill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -controlsInset),
            morePill.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: SSHTerminalBottomBar.topInset),
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
        grid.focusComposer = { [weak self] in
            guard let self else { return }
            self.manualInputChoice()
            self.composerFocusRequest += 1
            self.setNeedsUpdateProperties()
        }
        grid.useChatBar = { [weak self] in self?.showChatBar() }
        grid.keyboardDismissed = { [weak self] in self?.keyboardWasHidden() }
        grid.secureInputChanged = { [weak self] in self?.secureInputChanged($0) }
        grid.pasteImage = { [weak self] in self?.pasteImage($0) }
        grid.openTargetForHeldCell = { [weak self] held in self?.heldOpenTarget(held) }
        grid.open = { [weak self] target in self?.open(target) }
        return grid
    }

    private func replaceChannel(_ next: SSHTerminalChannel) {
        herdrTask?.cancel()
        keymapTask?.cancel()
        herdrTask = nil
        keymapTask = nil
        keymapToken = nil
        herdr = HerdrMonitor()
        keymap = SSHTerminalKeymapLoader()
        modeOverride = nil
        lastDetectedMode = nil
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
        cursorShiftHeld = false
        rawKeyboard = false
        automaticTerminalTyping = false
        modeOverrideBeforeSecurePrompt = nil
        refocusAfterSecurePrompt = true
        sawClosedForBackground = false
        reconnectOnReturn = false
        channel = next
        channel.isViewed = isOnScreen && AppScenePhase.shared.phase == .active
        destroyComposer()
        gridView?.removeFromSuperview()
        installGrid(makeGrid())
    }

    private func applyTheme(_ themeID: ThemeID) {
        let theme = themeID.appTheme
        view.backgroundColor = UIColor(theme.bg.primary)
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
    }

    // MARK: - Floating controls

    /// The … menu's header names the screen: the shell's title when it
    /// set one, else the host, followed by the shell's folder when it reported
    /// one (OSC 7). The navigation bar that showed it is hidden.
    private func installMenu(title: String, folder: String) {
        let header = SSHTerminalMenuHeader.text(title: title, folder: folder)
        guard header != menuTitle else { return }
        menuTitle = header
        morePill.more.menu = UIMenu(
            title: header,
            children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.overflowElements() ?? [])
            }]
        )
    }

    private func overflowElements() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if inputMode == .chat {
            items.append(UIAction(title: "Type in Terminal", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                self?.showTerminalKeyboard()
            })
        } else {
            items.append(UIAction(title: "Use Chat Bar", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.showChatBar()
            })
        }
        // The Files browser over this terminal's folder, when the host reports
        // one and is also a paired Oppi server.
        if !channel.workingDirectory.isEmpty, pairedServer != nil {
            items.append(UIAction(
                title: "Browse Files Here",
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.browseFilesHere()
            })
        }
        items.append(UIAction(title: "Edit Host", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.editHost()
        })
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
        return items
    }

    private func updateFloatingControls(themeID: ThemeID) {
        let rollup = programRollup
        if let rollup, let headline = rollup.headline {
            statusGlyph.apply(
                status: headline,
                summary: rollup.summaryText,
                themeID: themeID,
                reduceMotion: reduceMotion,
                root: channel.programStatus.root.map { .init(state: $0.state, revision: $0.revision) }
            )
            attention.glyphFrame.rect = statusGlyph.glyphFrame.rect
        }
        morePill.apply(
            themeID: themeID,
            herdrAvailable: herdr.available,
            herdrWaiting: herdr.snapshot?.needsAttention,
            showsStatus: rollup?.headline != nil
        )
        backPill.apply(themeID: themeID, attentionPending: attentionPending())
        let shellTitle = channel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        installMenu(
            title: shellTitle.isEmpty ? (hostLabel.isEmpty ? "SSH Terminal" : hostLabel) : shellTitle,
            folder: channel.workingDirectory
        )
        applyControlsVisibility(animation: .init(duration: 0.2, options: [.curveEaseInOut, .beginFromCurrentState]))
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
        for pill in [backPill, morePill] as [UIView] {
            pill.isUserInteractionEnabled = visible
            pill.accessibilityElementsHidden = !visible
        }
        let apply = {
            self.backPill.alpha = visible ? 1 : 0
            self.morePill.alpha = visible ? 1 : 0
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
            herdrWaiting: herdr.snapshot?.needsAttention ?? 0,
            blockedProgram: SSHTerminalProgramStatusPresentation.blockedNotice(
                store: channel.programStatus,
                isStopped: programIsStopped,
                seenAt: SSHTerminalProgramStatusPresentation.seenAt
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
            inputBanner.apply(text: input, color: UIColor(themeID.palette.orange))
        }
        pasteBanner.isHidden = pasteNotice == nil
        if let pasteNotice {
            pasteBanner.apply(text: pasteNotice, color: UIColor(themeID.palette.orange))
        }
        openBanner.isHidden = openNotice == nil
        if let openNotice {
            openBanner.apply(
                text: openNotice,
                color: UIColor(themeID.palette.fg),
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
        backToLive.isHidden = !detached
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
        composerConnection ?? HostFactory.root(near: self)?.coordinator.activeConnection
    }

    private func makeComposer() {
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        let session = SSHTerminalComposerHost(
            channel: channel,
            connection: serverConnection(),
            draftStore: HostFactory.root(near: self)?.composerDraftStore,
            themeID: themeID,
            showRawKeyboard: { [weak self] in self?.showTerminalKeyboard() }
        )
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
                showRawKeyboard: { [weak self] in self?.showTerminalKeyboard() }
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
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        composerSession?.connection = serverConnection()
        composerSession?.draftStore = HostFactory.root(near: self)?.composerDraftStore
        composerSession?.refreshChrome(
            themeID: themeID,
            reduceMotion: reduceMotion,
            connected: channel.connected
        )
        let colors = ComposerThemeColors(palette: themeID.palette)
        composerKeyStrip?.handlers.sendStrokes = { [weak self] strokes in self?.channel.keys(strokes) }
        composerKeyStrip?.handlers.sendKey = { [weak self] key in _ = self?.channel.key(key) }
        composerKeyStrip?.handlers.sendArrow = { [weak self] key in self?.channel.key(key) ?? false }
        composerKeyStrip?.handlers.showRawKeyboard = { [weak self] in self?.showTerminalKeyboard() }
        composerKeyStrip?.apply(
            profile: keymap.profile,
            userFile: keymap.userFile,
            colors: colors,
            foreground: colors.fg,
            background: colors.bg
        )
        applySendFailure(composerSession?.sendFailure)
        applyDictationFailure()
        composerBar?.apply()
        updateComposerHeight()
    }

    private func applySendFailure(_ message: String?) {
        guard let label = sendFailureLabel else { return }
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        let colors = ComposerThemeColors(palette: themeID.palette)
        label.text = message
        label.textColor = colors.red
        let hidden = message == nil || message?.isEmpty == true
        label.isHidden = hidden
        label.superview?.isHidden = hidden
        updateComposerHeight()
    }

    private func applyDictationFailure() {
        guard let banner = dictationFailureView else { return }
        let themeID = lastThemeID ?? ThemeRuntimeState.currentThemeID()
        let colors = ComposerThemeColors(palette: themeID.palette)
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

    private var herdrAttached: Bool { SSHTerminalAgentDetection.isHerdrCommand(channel.command) }
    private var detectedMode: SSHTerminalInputMode? {
        SSHTerminalAgentDetection.mode(
            root: channel.programStatus.liveRoot, app: channel.programStatus.app(of: ""),
            herdrAttached: herdrAttached, herdr: herdr.snapshot
        )
    }
    private var inputMode: SSHTerminalInputMode { modeOverride ?? detectedMode ?? .terminal }
    private var keymapProgram: String {
        SSHTerminalAgentDetection.keymapProgram(
            root: channel.programStatus.liveRoot, app: channel.programStatus.app(of: ""),
            herdrAttached: herdrAttached, herdr: herdr.snapshot
        )
    }

    private var programIsStopped: Bool { !channel.connected && !channel.connecting }
    private var programRollup: SessionStatusRollup? {
        SSHTerminalProgramStatusPresentation.rollup(
            store: channel.programStatus,
            isStopped: programIsStopped,
            seenAt: SSHTerminalProgramStatusPresentation.seenAt
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
            isStopped: programIsStopped,
            seenAt: SSHTerminalProgramStatusPresentation.seenAt
        )
    }
    private var statusText: String {
        if channel.networkChanged { return "Network changed \u{2014} checking the connection\u{2026}" }
        return channel.connecting ? channel.reason : "Disconnected \u{00b7} \(channel.reason)"
    }

    private func showTerminalKeyboard() {
        manualInputChoice()
        modeOverride = .terminal
        DispatchQueue.main.async { [weak self] in
            _ = self?.gridView?.becomeFirstResponder()
        }
        setNeedsUpdateProperties()
    }

    private func showChatBar() {
        manualInputChoice()
        modeOverride = detectedMode == .chat ? nil : .chat
        focusComposerAfterRaw = true
        _ = gridView?.resignFirstResponder()
        setNeedsUpdateProperties()
    }

    /// Typing moved off the chat bar automatically for a password prompt; the
    /// input bar comes back when that prompt ends. Any choice the user makes
    /// in the meantime (a tap on the bar or the grid, **Use Chat Bar**, **Type
    /// in Terminal**) wins over the automatic switch back.
    private var automaticTerminalTyping = false
    private var modeOverrideBeforeSecurePrompt: SSHTerminalInputMode?
    /// Whether ending the automatic switch focuses the chat bar it puts back.
    /// Hiding the keyboard during the prompt keeps the bar, not the keyboard.
    private var refocusAfterSecurePrompt = true

    private func manualInputChoice() {
        automaticTerminalTyping = false
        modeOverrideBeforeSecurePrompt = nil
    }

    /// The user sent the keyboard away. During an automatic switch for a
    /// password prompt that only keeps the keyboard down when the prompt ends;
    /// the chat bar still comes back there. Any other hide changes nothing.
    private func keyboardWasHidden() {
        guard automaticTerminalTyping else { return }
        refocusAfterSecurePrompt = false
    }

    /// A password prompt appeared or ended. Oppi never types a secret into the
    /// chat bar: the bar is a draft the user can read, save, and dictate into,
    /// so the input moves to the terminal while the prompt is up.
    private func secureInputChanged(_ secure: Bool) {
        if secure {
            guard !automaticTerminalTyping, inputMode == .chat, !rawKeyboard else { return }
            automaticTerminalTyping = true
            modeOverrideBeforeSecurePrompt = modeOverride
            refocusAfterSecurePrompt = true
            modeOverride = .terminal
            DispatchQueue.main.async { [weak self] in
                _ = self?.gridView?.becomeFirstResponder()
            }
        } else {
            guard automaticTerminalTyping else { return }
            automaticTerminalTyping = false
            modeOverride = modeOverrideBeforeSecurePrompt
            modeOverrideBeforeSecurePrompt = nil
            if refocusAfterSecurePrompt { focusComposerAfterRaw = true }
            // The bar comes back either way; a keyboard the user hid stays down.
            composerSession?.setSuppressKeyboard(!refocusAfterSecurePrompt)
            refocusAfterSecurePrompt = true
            _ = gridView?.resignFirstResponder()
        }
        setNeedsUpdateProperties()
    }

    // MARK: - Presentations

    private func showHerdr() {
        guard !presentingHerdr else { return }
        presentingHerdr = true
        herdr.watching = true
        Router.present(
            HerdrAgentsViewController(monitor: herdr, channel: channel),
            presentation: .sheet.detents([.medium(), .large()]).inNavigation(),
            from: self,
            onDismiss: { [weak self] in
                self?.presentingHerdr = false
                self?.herdr.watching = false
            }
        )
    }

    private func showStatusDetail() {
        guard !presentingStatusDetail else { return }
        presentingStatusDetail = true
        Router.present(
            SSHTerminalStatusDetailController(
                hostLabel: hostLabel,
                rows: programStatusRows,
                themeID: lastThemeID ?? ThemeRuntimeState.currentThemeID()
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
        guard let root = HostFactory.root(near: self), !sshHost.isEmpty else { return nil }
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
            HostFactory.root(near: self)?.opener.open(.webLink(url))
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
        guard let server = pairedServer, let root = HostFactory.root(near: self),
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
        guard let server = pairedServer, let root = HostFactory.root(near: self),
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
              let api = HostFactory.root(near: self)?.coordinator.apiClient(for: server.id) else { return }
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
            let alert = UIAlertController(
                title: "Paste \(pasteLineCount) \(pasteLineCount == 1 ? "line" : "lines")?",
                message: "This text contains a newline or terminal control sequence and may run commands. Paste only text you trust.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.pendingPaste = nil
            })
            alert.addAction(UIAlertAction(title: "Paste", style: .default) { [weak self] _ in
                guard let self, let text = self.pendingPaste else { return }
                self.pendingPaste = nil
                do { try self.channel.paste(text, confirmed: true) }
                catch { self.presentPasteFailure("Paste was not sent. \(error.localizedDescription)") }
            })
            present(alert, animated: true)
        } else {
            do { try channel.paste(text) }
            catch { presentPasteFailure("Paste was not sent. \(error.localizedDescription)") }
        }
    }

    /// Saves the image on the host like a chat-bar attachment, then pastes
    /// its path. Claude Code and pi read a pasted image path as the image.
    private func pasteImage(_ image: SSHTerminalPastedImage) {
        guard channel.connected else { channel.send(Data()); return }
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
        let alert = UIAlertController(title: "Paste Not Sent", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
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
              let kind = SSHTerminalMultiplexerKind.detected(in: session.connectedProfile?.startupCommand),
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

    private func updatePolling() {
        // Herdr and keymaps load again when you return; they do not run off screen.
        guard isOnScreen else {
            herdrTask?.cancel()
            herdrTask = nil
            keymapTask?.cancel()
            keymapTask = nil
            keymapToken = nil
            return
        }
        if channel.connected {
            openMultiplexerFolderIfNeeded()
            if herdrTask == nil {
                herdr.attached = herdrAttached
                herdrTask = Task { [weak self] in
                    guard let self else { return }
                    await self.herdr.run(on: self.channel)
                }
            }
        } else {
            herdrTask?.cancel()
            herdrTask = nil
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

    private func experimentChanged() {
        guard let session, !AppPreferences.Experiments.sshTerminalEnabled else { return }
        session.handleExperimentDisabled()
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
