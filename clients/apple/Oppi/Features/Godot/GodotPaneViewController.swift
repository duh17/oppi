import UIKit

/// A Godot game in a pane (`PaneRoute.godot`, design §9): the project's
/// newest build, running natively beside the chat, under the pane's own bar
/// (title, Play or Pause, Reload, Mute).
///
/// - The pane follows its project on the server: it reads the project, then
///   attaches as a player (`GodotPlayerLink`), which brings each new release
///   and the commands agents send (capture, input, pause, reload, perf),
///   and reports the pane's state and the game's log back. A new build
///   reaches the running game by itself, in the fastest way the engine can
///   take it (`GodotPackPolicy`); one that changes project settings or
///   autoloads starts the game again.
/// - One game runs app-wide (`GodotEngineHost`); one pane holds its view. A
///   pane opened on another game takes the engine from the game playing,
///   whose pane then offers Play to switch back. A second pane on the same
///   game shows the last frame it had and Play Here.
/// - A pane a relaunch restored waits for Play. A pane nobody sees pauses
///   the game; focus elsewhere keeps keys and controllers away from it.
/// - The newest error from the game's own code shows over it with its file
///   and line (`GodotErrorOverlayView`).
/// - The pane keeps its theme's background in every state; the game's view
///   is black only inside its own frame, and runs to the pane's bottom edge,
///   as the browser pane's page does. A heat notice takes its own row
///   between the bar and the game (`GodotNoticeBanner`); a paused game
///   dims under a Play button (`GodotPauseCover`).
final class GodotPaneViewController: UIViewController, GodotSurfaceOwner, PaneVisibilityObserving, PaneLiveResizing {
    let gameSlot: GodotSlot
    let surfaceSlot = UIView()

    private let host: GodotEngineHost
    private let root: AppRootEnvironment?
    /// Restored by a relaunch and not played yet: Play starts it.
    private var waitsForPlay: Bool
    /// Opened by the person and not played yet: its build plays as soon as
    /// it is here, taking the engine from any other game.
    private var opensToPlay: Bool
    private var project: GodotProjectStatus = .connecting
    private var summary: GodotProject?
    private var build: GodotBuild?
    private var buildRelease: GodotRelease?
    private var plan: GodotApplyPlan?
    /// The tier the last applied build went in by, for the player's state.
    private var appliedTier: GodotReloadTier?
    private var link: GodotLinkClient?
    private var player: GodotPlayerLink?
    private var commandTasks: [String: Task<Void, Never>] = [:]
    private var reportedState: GodotPlayerState?
    private var forwardedLogCount = 0
    private var fetching = false
    private var failure: String?
    private var followTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?

    private let stateView = UIContentUnavailableView(loadState: .loading(nil))
    private let lastFrameView = UIImageView()
    /// Over the last frame while another pane plays the game.
    private let lastFrameMaterial = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let errorOverlay = GodotErrorOverlayView()
    private let notice = GodotNoticeBanner()
    private let pauseCover = GodotPauseCover()
    /// The game's top: under the bar, or under the notice while it shows.
    private lazy var surfaceUnderBar = surfaceSlot.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
    private lazy var surfaceUnderNotice = surfaceSlot.topAnchor.constraint(equalTo: notice.bottomAnchor)

    private lazy var playItem = barItem("play.fill", String(localized: "Play"), "godot.play") { $0.playOrPause() }
    private lazy var reloadItem = barItem("arrow.clockwise", String(localized: "Reload"), "godot.reload") { $0.host.reloadScene() }
    private lazy var muteItem = barItem("speaker.wave.2.fill", String(localized: "Mute"), "godot.mute") {
        $0.host.setPersonMuted(!$0.host.isPersonMuted)
    }

    init(serverId: String, project: String, restored: Bool, root: AppRootEnvironment?) {
        gameSlot = GodotSlot(serverId: serverId, project: project)
        waitsForPlay = restored
        opensToPlay = !restored
        self.root = root
        host = root?.godot ?? .shared
        super.init(nibName: nil, bundle: nil)
        title = project
        navigationItem.largeTitleDisplayMode = .never
        // Rightmost first: Reload, Mute, Play from the leading side.
        navigationItem.rightBarButtonItems = [playItem, muteItem, reloadItem]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        followTask?.cancel()
        fetchTask?.cancel()
        player?.stop()
        for task in commandTasks.values { task.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "godot.pane"
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
        for subview in [surfaceSlot, lastFrameView, lastFrameMaterial, pauseCover, stateView, errorOverlay, notice] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Clear: the game's view is black in its own frame (`GodotSurfaceView`).
        surfaceSlot.backgroundColor = .clear
        lastFrameView.contentMode = .scaleToFill
        lastFrameView.clipsToBounds = true
        stateView.accessibilityIdentifier = "godot.state"
        // Its content's height never pulls the game's top edge (the notice row).
        stateView.setContentHuggingPriority(.defaultLow, for: .vertical)
        stateView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        errorOverlay.onDismiss = { [weak self] in self?.host.dismissGameError() }
        pauseCover.onPlay = { [weak self] in self?.playOrPause() }
        let guide = view.safeAreaLayoutGuide
        func fill(_ subview: UIView) -> [NSLayoutConstraint] {
            [
                subview.topAnchor.constraint(equalTo: surfaceSlot.topAnchor),
                subview.bottomAnchor.constraint(equalTo: surfaceSlot.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: surfaceSlot.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: surfaceSlot.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: guide.topAnchor),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surfaceUnderBar,
            // To the pane's bottom edge, under the home indicator, as the
            // browser's page; the states keep to the safe area.
            surfaceSlot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surfaceSlot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surfaceSlot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: surfaceSlot.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: surfaceSlot.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: surfaceSlot.trailingAnchor),
            errorOverlay.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            errorOverlay.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            errorOverlay.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            errorOverlay.heightAnchor.constraint(lessThanOrEqualTo: surfaceSlot.heightAnchor, multiplier: 0.4),
        ] + fill(lastFrameView) + fill(lastFrameMaterial) + fill(pauseCover))
        follow()
    }

    override func updateProperties() {
        super.updateProperties()
        // Observation tracking re-runs this when the host, the theme, or the server's switch changes.
        guard GodotPaneAvailability.isOn, serverOffersGodot else { return showOff() }
        let phase = currentPhase
        let holds = host.holdsSurface(self)
        _ = host.ownerGeneration
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
        // The release this pane plays, as the player reports it.
        view.accessibilityValue = holds ? buildRelease.map { "release \($0.seq)" } : nil
        updateState(phase)
        updateBar(phase)
        let frozen = phase == .elsewhere && lastFrameView.image != nil
        lastFrameView.isHidden = !frozen
        lastFrameMaterial.isHidden = !frozen
        updatePauseCover(phase, holds: holds)
        if holds, let error = host.gameError, phase == .running || phase == .paused {
            errorOverlay.show(error)
            errorOverlay.isHidden = false
        } else {
            errorOverlay.isHidden = true
        }
        showNotice(holds && host.isTooHot ? Self.tooHotMessage : nil)
        report(phase)
        if holds { forwardLog() }
    }

    /// Whether the game's server offers the Godot pane (its switch, and games to serve).
    private var serverOffersGodot: Bool {
        root?.coordinator.server(gameSlot.serverId, offers: .godotPane) ?? true
    }

    /// The experiment or the server's switch turned off (or a build without the engine
    /// restored this pane): nothing plays, and the pane says why.
    private func showOff() {
        view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
        for item in [playItem, reloadItem, muteItem] { item.isEnabled = false }
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        let message = !PlatformCapabilities.godotPane
            ? String(localized: "This build of Oppi has no game engine.")
            : GodotPaneAvailability.isOn
                ? String(localized: "Godot Pane is turned off on this server. Turn it on in Server Settings › Features.")
                : String(localized: "Turn on Godot Pane in Settings › Experiments to play Godot games here.")
        stateView.configuration = UIContentUnavailableConfiguration.loadState(
            .empty(title: String(localized: "Godot Pane Is Off"), systemImage: "gamecontroller", message: message),
            palette: palette, background: .clear
        )
        stateView.accessibilityValue = "off"
        stateView.isHidden = false
        errorOverlay.isHidden = true
        pauseCover.isHidden = true
        showNotice(nil)
    }

    /// The notice row between the bar and the game, or none.
    private func showNotice(_ text: String?) {
        notice.text = text
        notice.isHidden = text == nil
        surfaceUnderNotice.isActive = text != nil
        surfaceUnderBar.isActive = text == nil
    }

    /// Dims the held game while it is paused: Play for the person's pause,
    /// the reason for the others, which end by themselves.
    private func updatePauseCover(_ phase: GodotPanePhase, holds: Bool) {
        guard holds, phase == .running || phase == .paused else {
            pauseCover.isHidden = true
            return
        }
        if host.isTooHot {
            // The notice row says it in words.
            pauseCover.show(.reason(systemImage: "thermometer.high", label: String(localized: "Too hot to play"), text: nil))
        } else if phase == .paused {
            pauseCover.show(.play)
        } else if host.pauseReasons.contains(.hidden) {
            let text = String(localized: "Paused While Covered")
            pauseCover.show(.reason(systemImage: "pause.fill", label: text, text: text))
        } else {
            pauseCover.isHidden = true
        }
    }

    private var currentPhase: GodotPanePhase {
        let holds = host.holdsSurface(self)
        return GodotPanePhase.resolve(
            slot: gameSlot,
            project: project,
            plan: plan,
            engine: host.engine,
            holdsSurface: holds,
            loading: fetching ? .fetching : (holds ? host.loading : nil),
            paused: host.isPausedByPerson,
            failure: failure ?? (holds ? host.failure : nil)
        )
    }

    // MARK: Following the project

    /// Follows the project on its server; each new release is fetched and,
    /// unless the pane waits for Play or another pane plays this game,
    /// applied.
    private func follow() {
        guard GodotPaneAvailability.isOn, serverOffersGodot else { return }
        followTask?.cancel()
        failure = nil
        project = .connecting
        view.setNeedsUpdateProperties()
        let id = gameSlot.project
        followTask = Task { [weak self] in
            guard let link = await self?.waitForLink(), let self else { return }
            self.link = link
            do {
                self.received(try await link.project(id))
            } catch {
                guard !Task.isCancelled else { return }
                self.failure = String(localized: "Oppi couldn’t reach the server’s Godot projects: \(error.localizedDescription)")
                self.view.setNeedsUpdateProperties()
            }
            self.attachPlayer(link)
        }
    }

    /// Attaches this pane as the project's player; the link keeps trying
    /// while the pane lives.
    private func attachPlayer(_ link: GodotLinkClient) {
        guard player == nil, let player = link.playerLink(project: gameSlot.project) else { return }
        player.attachment = { [weak self] in
            GodotLinkPlayerMessage.Attach(
                capabilities: [ClientCapability.godotPane],
                device: UIDevice.current.name,
                runtimes: [GodotRuntimeInfo(engine: GodotEngine.godotName, version: GodotPackPolicy.engineVersion.description, formats: [.pck, .zip])],
                state: self?.reportedState
            )
        }
        player.onEvent = { [weak self] event in self?.handle(event) }
        self.player = player
        player.start()
    }

    private func handle(_ event: GodotPlayerLink.Event) {
        switch event {
        case .attached(_, let project):
            if failure != nil, buildRelease == nil { failure = nil }
            // Sent again whole, so the server's view of this player is current.
            reportedState = nil
            received(project)
            view.setNeedsUpdateProperties()
        case .release(let release):
            project = .build
            receivedRelease(release)
        case .command(let command):
            commandTasks[command.id] = Task { [weak self] in
                guard let self else { return }
                let result = await self.run(command)
                self.commandTasks[command.id] = nil
                guard !Task.isCancelled else { return }
                self.player?.send(.result(result))
            }
        case .cancel(let id):
            commandTasks.removeValue(forKey: id)?.cancel()
        }
    }

    /// The server's link once it is connected.
    private func waitForLink() async -> GodotLinkClient? {
        while !Task.isCancelled {
            if let root, let link = PaneEntries.godotLink(gameSlot.serverId, coordinator: root.coordinator) {
                return link
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func received(_ summary: GodotProject?) {
        self.summary = summary
        title = summary?.name ?? gameSlot.project
        PaneHostController.containing(self)?.view.setNeedsLayout()
        guard let summary else {
            project = .missing
            return view.setNeedsUpdateProperties()
        }
        guard let release = summary.release else {
            project = .noBuild
            return view.setNeedsUpdateProperties()
        }
        project = .build
        receivedRelease(release)
    }

    private func receivedRelease(_ release: GodotRelease) {
        guard let link, release.seq != buildRelease?.seq || build == nil else { return view.setNeedsUpdateProperties() }
        fetch(release, link: link)
    }

    private func fetch(_ release: GodotRelease, link: GodotLinkClient) {
        fetchTask?.cancel()
        fetching = true
        failure = nil
        view.setNeedsUpdateProperties()
        fetchTask = Task { [weak self] in
            guard let slot = self?.gameSlot else { return }
            do {
                let packs = try await GodotPackCache.packs(of: release, slot: slot, link: link)
                guard let self, !Task.isCancelled else { return }
                let build = GodotBuild(
                    slot: slot, packs: packs.map(\.url), indexes: packs.map(\.index),
                    hint: release.reload,
                    scene: release.entry?.scene, arguments: release.entry?.args ?? []
                )
                self.fetching = false
                self.build = build
                self.buildRelease = release
                self.plan = self.host.plan(for: build)
                self.view.setNeedsUpdateProperties()
                await self.applyIfPlaying()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fetching = false
                self.failure = error.localizedDescription
                self.view.setNeedsUpdateProperties()
            }
        }
    }

    /// Applies the newest build when this pane plays the game: it holds the
    /// view, no game runs and it does not wait for Play, or the person just
    /// opened it on another game than the one playing. A pane never takes its
    /// game from the pane that plays it, and a later build never takes the
    /// engine from another game.
    private func applyIfPlaying() async {
        guard let build, !waitsForPlay else { return }
        let plays = switch host.engine {
        case .idle: true
        case .running(let slot): slot == gameSlot ? host.holdsSurface(self) : opensToPlay
        case .starting(let slot): slot != gameSlot && opensToPlay
        }
        guard plays else { return }
        await play(build)
    }

    /// Plays `build` here.
    private func play(_ build: GodotBuild) async {
        opensToPlay = false
        let applied = await host.play(build, in: self)
        if applied.tier != nil || applied == .start { appliedTier = applied.tier }
        // A newer build that arrived while this one went in goes in next.
        if let newest = self.build, newest.packs != build.packs, host.holdsSurface(self) {
            return await play(newest)
        }
        plan = host.plan(for: self.build ?? build)
        view.setNeedsUpdateProperties()
    }

    // MARK: Actions

    /// The failed state's Retry: follows the project again when reaching it
    /// failed, else has the engine try the build again (`GodotEngineHost.retry`).
    private func retry() {
        guard failure == nil, let build else { return follow() }
        Task { [weak self] in
            guard let self else { return }
            opensToPlay = false
            await host.retry(build, in: self)
            view.setNeedsUpdateProperties()
        }
    }

    private func playOrPause() {
        switch currentPhase {
        case .running:
            host.setPausedByPerson(true)
        case .paused:
            host.setPausedByPerson(false)
        case .ready, .elsewhere:
            waitsForPlay = false
            guard let build else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.play(build)
                self.host.setPausedByPerson(false)
                self.view.setNeedsUpdateProperties()
            }
        default:
            break
        }
    }

    // MARK: The player link

    /// Sends the pane's state when it changed (`protocol/godot.json`).
    private func report(_ phase: GodotPanePhase) {
        guard let player else { return }
        let state = playerState(phase)
        guard state != reportedState else { return }
        reportedState = state
        player.send(.state(state))
    }

    private var playerState: GodotPlayerState { playerState(currentPhase) }

    private func playerState(_ phase: GodotPanePhase) -> GodotPlayerState {
        let holds = host.holdsSurface(self)
        let size = host.surface.bounds.size
        let gamePhase: GodotPhase = switch phase {
        case .running: .running
        case .paused: .paused
        case .loading: .loading
        case .failed, .refused: .error
        case .connecting, .missing, .noBuild, .ready, .elsewhere: .idle
        }
        let message: String? = switch phase {
        case .failed(let text): text
        case .refused(.nativeCode(let path)): "Refused: native code (\(path))"
        case .refused(.newerEngine(let version)): "Refused: made with Godot \(version.description)"
        case .elsewhere: "Playing in another pane"
        default: nil
        }
        return GodotPlayerState(
            phase: gamePhase,
            release: holds ? buildRelease?.seq : nil,
            tier: holds ? appliedTier : nil,
            fps: phase == .running ? host.liveRuntime?.perf().fps : nil,
            viewport: holds && size.width > 0
                ? GodotViewport(width: size.width, height: size.height, scale: host.surface.traitCollection.displayScale)
                : nil,
            message: message
        )
    }

    /// Sends the game's log lines recorded since the last send.
    private func forwardLog() {
        let fresh = min(host.logCount - forwardedLogCount, host.log.count)
        forwardedLogCount = host.logCount
        guard let player, fresh > 0 else { return }
        player.send(.log(host.log.suffix(fresh).map(\.linkEntry)))
    }

    /// One command from a controller (`GodotCommand`). The server sends it to
    /// the player that reported last, which may be a second pane on the game:
    /// commands act on the running game whichever pane holds its view.
    private func run(_ command: GodotLinkServerMessage.Command) async -> GodotLinkPlayerMessage.Result {
        func ok(_ output: some Encodable) -> GodotLinkPlayerMessage.Result {
            let value = (try? JSONEncoder().encode(output)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            return .init(id: command.id, ok: true, output: value, error: nil)
        }
        func fail(_ code: GodotErrorCode, _ message: String) -> GodotLinkPlayerMessage.Result {
            .init(id: command.id, ok: false, output: nil, error: GodotError(code: code, message: message))
        }
        let started = ContinuousClock.now
        func elapsed() -> Double {
            let duration = ContinuousClock.now - started
            return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        switch command.command {
        case .run(let release):
            guard let build, release == nil || release == buildRelease?.seq else {
                return fail(.failed, "Only the current release can run.")
            }
            waitsForPlay = false
            // A game already running only resumes: its view stays in the
            // pane the person put it in, whichever pane took the command.
            if host.engine != .running(gameSlot) { await play(build) }
            host.setPausedByPerson(false)
            return ok(GodotStateOutput(state: playerState))
        case .stop, .step, .pick, .tree, .node:
            return fail(.unsupported, "This player does not do \(command.command.name) yet.")
        case .unsupported(let name):
            return fail(.unsupported, "Unknown command \(name).")
        default:
            break
        }
        guard case .running(let slot) = host.engine, slot == gameSlot, let runtime = host.liveRuntime else {
            return fail(.failed, "The game is not running.")
        }
        switch command.command {
        case .pause:
            host.setPausedByPerson(true)
            return ok(GodotStateOutput(state: playerState))
        case .resume:
            host.setPausedByPerson(false)
            return ok(GodotStateOutput(state: playerState))
        case .reload(let tier):
            switch tier {
            case .scripts?:
                guard runtime.reloadScripts([]) >= 0 else { return fail(.failed, "This engine cannot reload scripts.") }
            case .restart?:
                guard let build else { return fail(.failed, "Only the current release can restart.") }
                await host.restart(build)
            default:
                host.reloadScene()
            }
            return ok(GodotReloadOutput(release: buildRelease?.seq ?? 0, tier: tier ?? .scene, ms: elapsed()))
        case .capture(let captureId, let maxSize):
            guard let captureId, let link else { return fail(.invalid, "A capture needs its id.") }
            guard let png = GodotFrameCapture.png(from: host), let shot = GodotFrameCapture.fitted(png, maxSize: maxSize) else {
                return fail(.failed, "Nothing to capture yet.")
            }
            guard shot.data.count <= GodotLinkClient.captureLimit else { return fail(.failed, "The capture is over 20 MB.") }
            do {
                try await link.uploadCapture(shot.data, mimeType: "image/png", project: gameSlot.project, captureId: captureId)
            } catch {
                return fail(.failed, "The capture didn’t upload: \(error.localizedDescription)")
            }
            return ok(GodotCaptureOutput(captureId: captureId, mimeType: "image/png", width: shot.width, height: shot.height))
        case .input(let steps):
            switch await GodotInputSteps.run(steps, on: runtime, size: host.surface.bounds.size) {
            case .success(let count): return ok(GodotInputOutput(steps: count, ms: elapsed()))
            case .failure(let error): return fail(error.code, error.message)
            }
        case .perf:
            let perf = runtime.perf()
            return ok(GodotPerfOutput(
                fps: perf.fps, frameMs: host.frameMilliseconds, processMs: perf.processMilliseconds, physicsMs: nil,
                drawCalls: perf.drawCalls, nodes: perf.nodes, memoryMB: GodotFrameCapture.footprintMegabytes()
            ))
        default:
            return fail(.unsupported, "Unknown command \(command.command.name).")
        }
    }

    // MARK: GodotSurfaceOwner

    func surfaceDidLeave(lastFrame: UIImage?) {
        lastFrameView.image = lastFrame
        view.setNeedsUpdateProperties()
    }

    // MARK: Pane

    func paneVisibilityDidChange(_ visibility: PaneVisibility) {
        switch visibility {
        case .visible(let focused):
            host.setVisible(true, for: self)
            host.setFocused(focused, for: self)
        case .covered, .parked:
            host.setVisible(false, for: self)
            host.setFocused(false, for: self)
        }
    }

    func paneWillBeginLiveResize() {
        if host.holdsSurface(self) { host.surface.holdSize() }
    }

    func paneSettleLiveResize(to size: CGSize, final: Bool) {
        if final, host.holdsSurface(self) { host.surface.settleSize() }
    }

    // MARK: Bar and state

    private func barItem(
        _ symbol: String, _ title: String, _ identifier: String, action: @escaping (GodotPaneViewController) -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, image: UIImage(systemName: symbol), primaryAction: UIAction(title: title) { [weak self] _ in
            guard let self else { return }
            action(self)
        })
        item.accessibilityIdentifier = identifier
        return item
    }

    private func updateBar(_ phase: GodotPanePhase) {
        let running = phase == .running
        playItem.image = UIImage(systemName: running ? "pause.fill" : "play.fill")
        playItem.title = running ? String(localized: "Pause") : String(localized: "Play")
        playItem.accessibilityValue = running ? "running" : "\(phase.kind)"
        // Waiting and elsewhere have one action, the state's own button.
        // Heat resumes the game by itself; the notice row says when.
        playItem.isEnabled = (phase == .running || phase == .paused) && build != nil && !host.isTooHot
        reloadItem.isEnabled = phase == .running || phase == .paused
        // Nothing here can play: no Play or Reload to offer.
        let unplayable = switch phase {
        case .noBuild, .refused, .missing: true
        default: false
        }
        playItem.isHidden = unplayable
        reloadItem.isHidden = unplayable
        muteItem.isHidden = unplayable
        let muted = host.isPersonMuted
        muteItem.image = UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        muteItem.title = muted ? String(localized: "Unmute") : String(localized: "Mute")
        muteItem.accessibilityValue = muted ? "muted" : "sound"
        muteItem.isEnabled = true
    }

    private func updateState(_ phase: GodotPanePhase) {
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        let name = summary?.name ?? gameSlot.project
        var state: LoadState?
        var button: (title: String, action: @MainActor () -> Void)?
        switch phase {
        case .running, .paused:
            state = nil
        case .connecting:
            state = .connecting
        case .missing:
            state = .missing(
                title: String(localized: "Game Not Found"), systemImage: "gamecontroller",
                message: String(localized: "The server no longer finds this Godot project."),
                retry: RetryAction { [weak self] in self?.follow() }
            )
        case .noBuild:
            state = .empty(
                title: String(localized: "No Build Yet"), systemImage: "shippingbox",
                message: String(localized: "Export \(name) as a .pck next to its project.godot, and it opens here.")
            )
        case .loading(.fetching):
            state = .loading(String(localized: "Downloading the build…"))
        case .loading(.starting):
            state = .loading(String(localized: "Starting \(name)…"))
        case .ready:
            let another = host.engine != .idle
            state = .empty(
                title: String(localized: "Ready to Play"), systemImage: "play.circle",
                message: another
                    ? String(localized: "Another game is playing. Play ends it and starts this one.")
                    : String(localized: "The game starts when you tap Play.")
            )
            button = (String(localized: "Play"), { [weak self] in self?.playOrPause() })
        case .elsewhere:
            state = .empty(
                title: String(localized: "Playing in Another Pane"), systemImage: "rectangle.on.rectangle",
                message: String(localized: "Play Here moves the game to this pane.")
            )
            button = (String(localized: "Play Here"), { [weak self] in self?.playOrPause() })
        case .refused(.nativeCode(let path)):
            state = .failed(
                title: String(localized: "Oppi Won’t Run This Build"),
                message: String(localized: "It contains native code (\(path)). Oppi runs GDScript games only."),
                retry: nil
            )
        case .refused(.newerEngine(let version)):
            state = .failed(
                title: String(localized: "Made With a Newer Godot"),
                message: String(localized: "This build needs Godot \(version.description). Oppi plays games made with Godot \(GodotPackPolicy.engineVersion.description)."),
                retry: nil
            )
        case .failed(let message):
            state = .failed(
                title: String(localized: "The Game Didn’t Load"), message: message,
                retry: RetryAction { [weak self] in self?.retry() }
            )
        }
        stateView.accessibilityValue = phase.kind
        stateView.isHidden = state == nil
        // Over the frozen frame's material while elsewhere; the theme hides
        // a starting game's black view behind the other states.
        stateView.backgroundColor = phase == .elsewhere ? .clear : view.backgroundColor
        guard let state else { return }
        var config = UIContentUnavailableConfiguration.loadState(state, palette: palette, background: .clear)
        if let button { config.setProminentButton(button.title, action: button.action) }
        stateView.configuration = config
    }

    static var tooHotMessage: String {
        String(localized: "This device is too hot, so Oppi paused the game. It plays again once the device cools down.")
    }
}

extension GodotPanePhase {
    /// The phase's name for `godot.state`'s accessibility value.
    var kind: String {
        switch self {
        case .connecting: "connecting"
        case .missing: "missing"
        case .noBuild: "noBuild"
        case .loading: "loading"
        case .ready: "ready"
        case .running: "running"
        case .paused: "paused"
        case .elsewhere: "elsewhere"
        case .refused: "refused"
        case .failed: "failed"
        }
    }
}
