import CryptoKit
import Observation
import os
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "GodotEngine")

/// A Godot pane that can hold the game's view.
@MainActor
protocol GodotSurfaceOwner: AnyObject {
    var gameSlot: GodotSlot { get }
    /// Where the surface goes while this pane holds it.
    var surfaceSlot: UIView { get }
    /// The surface moved to another pane; `lastFrame` is what it showed here.
    func surfaceDidLeave(lastFrame: UIImage?)
}

/// A release on disk, ready for the engine.
struct GodotBuild {
    let slot: GodotSlot
    /// Base first, patches after.
    let packs: [URL]
    let indexes: [GodotPackIndex]
    let hint: GodotReloadTier
    /// The scene to open, else the project's main scene.
    let scene: String?
    /// The game's own arguments (after `--`).
    let arguments: [String]
}

/// Why the engine is not drawing.
enum GodotPauseReason: Hashable, Sendable {
    /// The pause button.
    case person
    /// No pane shows the game, or its pane is covered or parked.
    case hidden
    /// The app left the foreground.
    case background
    /// The device is critically hot.
    case thermal
}

/// The app's one game engine (design §5, §9). Godot 4.7 starts once per
/// process, so the host starts it for the first game played this launch and
/// keeps it: a new build of that game swaps packs or reloads scripts
/// (`GodotPackPolicy`), and another game waits for a relaunch. One pane holds
/// the engine's view at a time (`GodotSurfaceView`, moved, never rebuilt); a
/// publish never takes it from the pane being played.
///
/// - The display link drives `iterate` at the display's rate (30–120 Hz),
///   30 Hz at most when the device is seriously hot, and stops while any
///   `GodotPauseReason` holds.
/// - Audio follows `GodotAudioPolicy`; the error overlay shows the latest
///   error the game's own code raised (`GodotEngineLog.isGameError`).
/// - A memory warning keeps the engine: it cannot start again, and stopping
///   it would lose the game until the app relaunches.
@MainActor @Observable
final class GodotEngineHost {
    static let shared = GodotEngineHost(runtime: GodotRuntimes.make())

    private(set) var engine: GodotEngineState = .idle
    private(set) var loaded: GodotLoadedBuild?
    private(set) var pauseReasons: Set<GodotPauseReason> = [.hidden]
    private(set) var loading: GodotLoadStep?
    private(set) var failure: String?
    /// The newest error the game raised, until dismissed or the next build.
    private(set) var gameError: GodotEngineLog?
    private(set) var isThrottled = false
    /// The pane's mute button; the game is also silent while the microphone is held.
    private(set) var isPersonMuted = false
    /// How long the last start took to the first drawn frame.
    private(set) var startMilliseconds: Double?
    /// Recent engine log lines, oldest first, published at most four times a
    /// second (`logBatchInterval`) so a chatty game never redraws its pane
    /// or floods its link once a line.
    private(set) var log: [GodotEngineLog] = []
    /// Lines published since launch, so a reader knows which in `log` are new.
    private(set) var logCount = 0
    static let logBatchInterval: Duration = .milliseconds(250)
    @ObservationIgnored private var pendingLog: [GodotEngineLog] = []
    @ObservationIgnored private var logFlush: Task<Void, Never>?
    /// The mean time of one engine frame over the last report window.
    @ObservationIgnored private(set) var frameMilliseconds: Double?
    static let logLimit = 500

    @ObservationIgnored private let runtime: (any GodotEngineRuntime)?
    @ObservationIgnored private weak var owner: (any GodotSurfaceOwner)?
    /// Bumped whenever another pane takes the surface, so panes re-read.
    private(set) var ownerGeneration = 0
    @ObservationIgnored let audio = GodotAudioPolicy()
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var startedAt: CFTimeInterval?
    @ObservationIgnored private var frameTimes = GodotFrameTimes()
    @ObservationIgnored private var engineSize: (CGSize, CGFloat)?

    @ObservationIgnored private(set) lazy var surface: GodotSurfaceView = {
        let surface = GodotSurfaceView()
        surface.input.host = self
        surface.onSettledSize = { [weak self] size, scale in self?.resize(size, scale: scale) }
        surface.onWindowChange = { [weak self, weak surface] in
            guard let self, let surface else { return }
            if surface.window == nil { surface.input.cancelAll() }
            setPaused(.hidden, surface.window == nil)
        }
        runtime?.attach(to: surface.layer)
        return surface
    }()

    init(runtime: (any GodotEngineRuntime)?) {
        self.runtime = runtime
        runtime?.onLog = { [weak self] entry in self?.record(entry) }
        audio.onChange = { [weak self] muted in self?.runtime?.setMuted(muted) }
        observeSystem()
    }

    isolated deinit {
        link?.invalidate()
        logFlush?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The running engine, paused or not: captures, commands, and the ends
    /// of touches and keys (a finger lifted or a key released while paused
    /// must still reach the game, or it stays held).
    var liveRuntime: (any GodotEngineRuntime)? {
        guard case .running = engine else { return nil }
        return runtime
    }

    /// The runtime new input goes to: a running, unpaused game.
    var inputRuntime: (any GodotEngineRuntime)? {
        pauseReasons.isEmpty ? liveRuntime : nil
    }

    /// Whether `owner` has the game's view now.
    func holdsSurface(_ owner: any GodotSurfaceOwner) -> Bool {
        self.owner === owner
    }

    var isPausedByPerson: Bool { pauseReasons.contains(.person) || pauseReasons.contains(.thermal) }

    /// The device is critically hot: the game waits for it to cool, whatever Play says.
    var isTooHot: Bool { pauseReasons.contains(.thermal) }

    // MARK: Builds

    /// How `build` would reach the engine now.
    func plan(for build: GodotBuild) -> GodotApplyPlan {
        GodotPackPolicy.plan(slot: build.slot, packs: build.indexes, hint: build.hint, loaded: loaded, engine: engine)
    }

    /// Plays `build` in `owner`'s pane: starts the engine on the first game
    /// this launch, or applies a new build of the running game. The pane
    /// takes the surface; nothing happens for a build that needs a relaunch.
    @discardableResult
    func play(_ build: GodotBuild, in owner: any GodotSurfaceOwner) async -> GodotApplyPlan {
        guard let runtime else { return .relaunch(.engineStopped) }
        let plan = plan(for: build)
        switch plan {
        case .relaunch, .refuse:
            return plan
        case .start:
            // Starting from now: a second play while setup runs plans against
            // it, never a second start.
            engine = .starting(build.slot)
            take(for: owner)
            failure = nil
            gameError = nil
            loading = .starting
            // The pane draws "Starting…" before setup blocks the main thread.
            await Self.nextFrame()
            runtime.attach(to: surface.layer)
            if let (size, scale) = engineSize { runtime.resize(to: size, scale: scale) }
            startedAt = CACurrentMediaTime()
            let started = runtime.start(GodotStartConfig(
                packs: build.packs,
                userFolder: GodotFolders.user(for: build.slot),
                cacheFolder: GodotFolders.engineCache(for: build.slot),
                readableFolders: [URL(filePath: "/System/Library/Fonts")],
                arguments: (build.scene.map { [$0] } ?? []) + (build.arguments.isEmpty ? [] : ["--"] + build.arguments)
            ))
            loading = nil
            guard started else {
                engine = .stopped
                failure = String(localized: "The game didn’t start. Its log says why.")
                logger.error("Godot start failed for \(build.slot.project, privacy: .public)")
                return plan
            }
            engine = .running(build.slot)
            GodotPackCache.pin(build.packs)
            loaded = GodotLoadedBuild(slot: build.slot, files: GodotPackPolicy.merged(build.indexes))
            runtime.setMuted(audio.isMuted)
            audio.gameDidStart()
            startLink()
            applyPause()
        case .unchanged:
            take(for: owner)
        case .scripts(let resources):
            take(for: owner)
            gameError = nil
            GodotPackCache.pin(build.packs)
            for pack in build.packs where !runtime.mount(pack) {
                failure = String(localized: "The new build didn’t load.")
                return plan
            }
            let reloaded = runtime.reloadScripts(resources)
            failure = nil
            loaded = GodotLoadedBuild(slot: build.slot, files: GodotPackPolicy.merged(build.indexes))
            logger.info("Reloaded \(reloaded) scripts")
        case .scene:
            take(for: owner)
            gameError = nil
            loading = .starting
            GodotPackCache.pin(build.packs)
            await Self.nextFrame()
            let swapped = build.packs.dropLast().allSatisfy(runtime.mount)
                && build.packs.last.map { runtime.swap(to: $0, scene: build.scene) } == true
            loading = nil
            failure = swapped ? nil : String(localized: "The new build didn’t load.")
            loaded = GodotLoadedBuild(slot: build.slot, files: GodotPackPolicy.merged(build.indexes))
        }
        return plan
    }

    /// Reloads the running game's scene from its packs (the pane's Reload).
    func reloadScene() {
        guard case .running = engine, let runtime else { return }
        gameError = nil
        if !runtime.reloadScene() { failure = String(localized: "The scene didn’t reload.") }
    }

    func dismissGameError() {
        gameError = nil
    }

    // MARK: Panes

    /// Moves the game's view into `owner`'s pane. The pane that had it keeps
    /// the last frame it showed.
    func take(for owner: any GodotSurfaceOwner) {
        guard self.owner !== owner else {
            if surface.superview !== owner.surfaceSlot { mount(in: owner.surfaceSlot) }
            return
        }
        let previous = self.owner
        let lastFrame = previous == nil ? nil : GodotFrameCapture.image(from: self)
        surface.input.cancelAll()
        self.owner = owner
        ownerGeneration += 1
        mount(in: owner.surfaceSlot)
        previous?.surfaceDidLeave(lastFrame: lastFrame)
    }

    /// The holding pane is seen, or covered or parked.
    func setVisible(_ visible: Bool, for owner: any GodotSurfaceOwner) {
        guard self.owner === owner else { return }
        setPaused(.hidden, !visible || surface.window == nil)
    }

    /// The holding pane took or lost the window's focus: a controller and
    /// keys drive the game only while its pane has focus.
    func setFocused(_ focused: Bool, for owner: any GodotSurfaceOwner) {
        guard self.owner === owner else { return }
        surface.wantsKeyboard = focused
        guard case .running = engine else { return }
        runtime?.focus(focused)
    }

    func setPausedByPerson(_ paused: Bool) {
        setPaused(.person, paused)
    }

    func setPersonMuted(_ muted: Bool) {
        isPersonMuted = muted
        audio.personMuted = muted
    }

    private func mount(in slot: UIView) {
        surface.removeFromSuperview()
        surface.frame = slot.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        slot.addSubview(surface)
        setPaused(.hidden, surface.window == nil)
    }

    private func resize(_ size: CGSize, scale: CGFloat) {
        engineSize = (size, scale)
        runtime?.resize(to: size, scale: scale)
    }

    // MARK: Frames

    private func setPaused(_ reason: GodotPauseReason, _ paused: Bool) {
        let before = pauseReasons
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        guard pauseReasons.isEmpty != before.isEmpty else { return }
        applyPause()
    }

    private func applyPause() {
        guard case .running = engine, let runtime else { return }
        let paused = !pauseReasons.isEmpty
        link?.isPaused = paused
        if paused {
            surface.input.cancelAll()
            frameTimes = GodotFrameTimes()
            runtime.pause()
        } else {
            runtime.resume()
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: LinkTarget(host: self), selector: #selector(LinkTarget.tick))
        applyFrameRate(to: link)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func applyFrameRate(to link: CADisplayLink) {
        let maximum: Float = isThrottled ? 30 : 120
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
    }

    fileprivate func tick() {
        guard case .running = engine, let runtime else { return }
        let began = CACurrentMediaTime()
        let alive = runtime.iterate()
        if let report = frameTimes.add(CACurrentMediaTime() - began, at: began) {
            frameMilliseconds = report.meanMilliseconds
            logger.info("Godot frames: \(report.description, privacy: .public)")
        }
        guard alive else {
            // The game quit. The engine cannot start again this launch.
            engine = .stopped
            link?.invalidate()
            link = nil
            record(GodotEngineLog(
                kind: .print, message: "The game quit.", file: "", line: 0, function: "",
                scriptFile: "", scriptLine: 0, backtrace: ""
            ))
            return
        }
        if let startedAt, runtime.perf().framesDrawn > 0 {
            self.startedAt = nil
            let elapsed = (CACurrentMediaTime() - startedAt) * 1000
            startMilliseconds = elapsed
            logger.info("Godot first frame after \(Int(elapsed)) ms")
        }
    }

    /// The display link retains its target; the host must not be. The link
    /// runs on the main run loop, so it ticks on the main actor.
    @MainActor
    private final class LinkTarget: NSObject {
        weak var host: GodotEngineHost?
        init(host: GodotEngineHost) { self.host = host }
        @objc func tick() { host?.tick() }
    }

    private static func nextFrame() async {
        try? await Task.sleep(for: .milliseconds(16))
    }

    // MARK: Log and system

    private func record(_ entry: GodotEngineLog) {
        pendingLog.append(entry)
        guard logFlush == nil else { return }
        logFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.logBatchInterval)
            self?.flushLog()
        }
    }

    /// Publishes the lines recorded since the last batch.
    func flushLog() {
        logFlush?.cancel()
        logFlush = nil
        guard !pendingLog.isEmpty else { return }
        let batch = pendingLog
        pendingLog.removeAll()
        for entry in batch {
            logger.debug("Godot log: \(entry.message, privacy: .public)")
        }
        logCount += batch.count
        log.append(contentsOf: batch)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        if let error = batch.last(where: \.isGameError) { gameError = error }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(.background, true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(.background, false) }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyThermalState() }
            },
        ]
        applyThermalState()
    }

    #if DEBUG
    /// Stands in for the device's thermal state (the debug harness's hot
    /// device); post `thermalStateDidChangeNotification` after setting it.
    static var _thermalStateForTesting: ProcessInfo.ThermalState?
    #endif

    /// Seriously hot: 30 fps at most. Critically: paused until it cools.
    private func applyThermalState() {
        var state = ProcessInfo.processInfo.thermalState
        #if DEBUG
        if let forced = Self._thermalStateForTesting { state = forced }
        #endif
        isThrottled = state == .serious || state == .critical
        if let link { applyFrameRate(to: link) }
        setPaused(.thermal, state == .critical)
    }
}

/// The engine's time per frame (`iterate`), reported every 5 s to the log as
/// frames per second and mean and 95th-percentile milliseconds: the device
/// measure for choosing the engine's `optimize=size` build (design D5).
struct GodotFrameTimes {
    static let window: CFTimeInterval = 5
    private var samples: [CFTimeInterval] = []
    private var windowStart: CFTimeInterval?

    struct Report {
        let fps: Double
        let meanMilliseconds: Double
        let p95Milliseconds: Double

        var description: String {
            String(format: "%.1f fps, iterate mean %.2f ms, p95 %.2f ms", fps, meanMilliseconds, p95Milliseconds)
        }
    }

    /// Adds one frame's time; the window's report once it is full.
    mutating func add(_ duration: CFTimeInterval, at time: CFTimeInterval) -> Report? {
        let start = windowStart ?? time
        windowStart = start
        samples.append(duration)
        let elapsed = time - start
        guard elapsed >= Self.window, !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count) * 1000
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
        let fps = Double(sorted.count) / elapsed
        samples.removeAll(keepingCapacity: true)
        windowStart = nil
        return Report(fps: fps, meanMilliseconds: mean, p95Milliseconds: p95)
    }
}

/// Where a game's files live on this device.
enum GodotFolders {
    /// `user://` for one project on one server.
    static func user(for slot: GodotSlot) -> URL {
        AppLibrary.applicationSupport().appending(path: "Godot/\(key(for: slot))/user", directoryHint: .isDirectory)
    }

    /// One project's packs. The game may read only its own.
    static func packs(for slot: GodotSlot) -> URL {
        AppLibrary.caches().appending(path: "Godot/packs/\(key(for: slot))", directoryHint: .isDirectory)
    }

    /// The engine's cache (compiled shaders) for one project: a game writes
    /// there, so no game shares it with another.
    static func engineCache(for slot: GodotSlot) -> URL {
        AppLibrary.caches().appending(path: "Godot/engine/\(key(for: slot))", directoryHint: .isDirectory)
    }

    /// A folder name for a server's project: its ids may hold any character.
    static func key(for slot: GodotSlot) -> String {
        let digest = SHA256.hash(data: Data("\(slot.serverId)\u{0}\(slot.project)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
