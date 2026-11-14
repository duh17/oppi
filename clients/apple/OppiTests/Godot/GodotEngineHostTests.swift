import Foundation
import Testing
import UIKit
@testable import Oppi

/// The app's one engine and what each Godot pane shows of it: the first game
/// played this launch starts the engine; a new build of it goes in by the
/// tier the policy picks; another game, or any game after the engine
/// stopped, waits for a relaunch; one pane holds the game's view, and a
/// second pane on the same game offers Play Here.
@MainActor
@Suite("GodotEngineHost")
struct GodotEngineHostTests {
    let tide = GodotSlot(serverId: "sha256:studio", project: "games~tide")
    let reef = GodotSlot(serverId: "sha256:studio", project: "games~reef")

    @Test func theFirstGameStartsTheEngineInItsPane() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let pane = FakeGodotPane(tide)
        let plan = await host.play(build(tide, ["project.binary": 1, "main.gd": 2]), in: pane)
        #expect(plan == .start)
        #expect(runtime.started.count == 1)
        #expect(host.engine == .running(tide))
        #expect(host.holdsSurface(pane))
        #expect(host.surface.superview === pane.surfaceSlot)
        #expect(phase(host, pane) == .running)
    }

    @Test func aNewBuildOfTheRunningGameReloadsItsScripts() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let pane = FakeGodotPane(tide)
        await host.play(build(tide, ["project.binary": 1, "main.gd": 2]), in: pane)
        let plan = await host.play(build(tide, ["project.binary": 1, "main.gd": 3], hint: .scripts), in: pane)
        #expect(plan == .scripts(["res://main.gd"]))
        #expect(runtime.reloadedScripts == [["res://main.gd"]])
        #expect(runtime.started.count == 1, "The engine starts once")
        #expect(host.loaded?.files["main.gd"] == Data(repeating: 3, count: 16))
    }

    @Test func aChangedSceneSwapsThePack() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let pane = FakeGodotPane(tide)
        await host.play(build(tide, ["project.binary": 1, "main.tscn": 2]), in: pane)
        let plan = await host.play(build(tide, ["project.binary": 1, "main.tscn": 5]), in: pane)
        #expect(plan == .scene)
        #expect(runtime.swaps.count == 1)
        #expect(runtime.started.count == 1)
    }

    @Test func anotherGameWaitsForARelaunchAndTakesNothing() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let playing = FakeGodotPane(tide)
        let other = FakeGodotPane(reef)
        await host.play(build(tide, ["project.binary": 1]), in: playing)
        let plan = await host.play(build(reef, ["project.binary": 7]), in: other)
        #expect(plan == .relaunch(.otherGame))
        #expect(host.holdsSurface(playing), "The game being played keeps its view")
        #expect(runtime.started.count == 1)
        #expect(phase(host, other) == .needsRelaunch(.otherGame))
    }

    @Test func aSecondPaneOnTheGameOffersPlayHereAndTakesTheView() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let first = FakeGodotPane(tide)
        let second = FakeGodotPane(tide)
        let files: [String: UInt8] = ["project.binary": 1, "main.gd": 2]
        await host.play(build(tide, files), in: first)
        #expect(phase(host, second) == .elsewhere)

        await host.play(build(tide, files), in: second)
        #expect(host.holdsSurface(second))
        #expect(host.surface.superview === second.surfaceSlot)
        #expect(first.leftCount == 1, "The first pane was told it lost the view")
        #expect(phase(host, first) == .elsewhere)
        #expect(runtime.started.count == 1)
    }

    @Test func aGameThatQuitsStopsTheEngineForTheLaunch() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let pane = FakeGodotPane(tide)
        await host.play(build(tide, ["project.binary": 1]), in: pane)
        runtime.quits = true
        // The display link's next frame finds the game gone.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(host.engine == .stopped)
        #expect(await host.play(build(tide, ["project.binary": 1]), in: pane) == .relaunch(.engineStopped))
        #expect(runtime.started.count == 1)
    }

    @Test func aFailedStartSaysSoAndNeedsARelaunch() async {
        let runtime = FakeGodotRuntime()
        runtime.startSucceeds = false
        let host = GodotEngineHost(runtime: runtime)
        let pane = FakeGodotPane(tide)
        await host.play(build(tide, ["project.binary": 1]), in: pane)
        #expect(host.engine == .stopped)
        guard case .failed = phase(host, pane) else {
            Issue.record("The pane that started it shows the failure")
            return
        }
        #expect(phase(host, FakeGodotPane(tide)) == .needsRelaunch(.engineStopped))
    }

    @Test func pausingFollowsThePersonAndThePanesVisibility() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let pane = FakeGodotPane(tide)
        await host.play(build(tide, ["project.binary": 1]), in: pane)
        host.setPausedByPerson(true)
        #expect(phase(host, pane) == .paused)
        #expect(host.inputRuntime == nil, "No input reaches a paused game")
        host.setPausedByPerson(false)
        host.setVisible(false, for: pane)
        #expect(phase(host, pane) == .running, "A hidden pane's game is paused, not paused by the person")
        #expect(host.inputRuntime == nil)
        host.setVisible(true, for: pane)
        #expect(host.inputRuntime != nil)
    }

    @Test func onlyTheGamesOwnErrorsShowOverIt() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        await host.play(build(tide, ["project.binary": 1]), in: FakeGodotPane(tide))
        runtime.onLog?(GodotEngineLog(
            kind: .error, message: "Mouse is not supported by this display server.", file: "platform/ios/display.mm",
            line: 12, function: "f", scriptFile: "", scriptLine: 0, backtrace: ""
        ))
        host.flushLog()
        #expect(host.gameError == nil)
        let scriptError = GodotEngineLog(
            kind: .script, message: "Invalid call. Nonexistent function 'explode'.", file: "core/variant.cpp", line: 3,
            function: "call", scriptFile: "res://probe.gd", scriptLine: 41, backtrace: "[0] _runtime_error (res://probe.gd:41)"
        )
        runtime.onLog?(scriptError)
        #expect(host.gameError == nil, "Lines reach the pane in batches")
        host.flushLog()
        #expect(host.gameError == scriptError)
        #expect(scriptError.location?.file == "res://probe.gd" && scriptError.location?.line == 41)
        #expect(host.log.count == 2)
    }

    @Test func aSecondPlayWhileTheEngineStartsNeverStartsItAgain() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let first = FakeGodotPane(tide)
        let second = FakeGodotPane(tide)
        let other = FakeGodotPane(reef)
        let files: [String: UInt8] = ["project.binary": 1, "main.gd": 2]
        // The first play yields a frame before setup; the others plan meanwhile.
        let firstBuild = build(tide, files)
        let starting = Task { await host.play(firstBuild, in: first) }
        while host.engine == .idle { await Task.yield() }
        #expect(host.engine == .starting(tide))
        #expect(await host.play(build(tide, files), in: second) == .unchanged)
        #expect(await host.play(build(reef, ["project.binary": 7]), in: other) == .relaunch(.otherGame))
        #expect(await starting.value == .start)
        #expect(runtime.started.count == 1)
        #expect(host.engine == .running(tide))
    }

    @Test func pausingLiftsTheFingersTheGameHolds() async {
        let runtime = FakeGodotRuntime()
        let host = GodotEngineHost(runtime: runtime)
        let pane = FakeGodotPane(tide)
        await host.play(build(tide, ["project.binary": 1]), in: pane)
        let finger = ObjectIdentifier(NSObject())
        host.surface.input.began(finger, at: CGPoint(x: 10, y: 20), pressure: 1, doubleTap: false)
        host.setPausedByPerson(true)
        #expect(runtime.touches.map(\.phase) == [.began, .cancelled], "The paused game hears the finger lift")
        host.surface.input.began(ObjectIdentifier(NSObject()), at: .zero, pressure: 1, doubleTap: false)
        host.surface.input.ended(finger, at: .zero, cancelled: false)
        #expect(runtime.touches.count == 2, "A paused game takes no new touch, and the lifted one ends once")
        host.setPausedByPerson(false)
        host.surface.input.began(ObjectIdentifier(NSObject()), at: .zero, pressure: 1, doubleTap: false)
        #expect(runtime.touches.last?.index == 0, "The lifted finger's number is free again")
    }

    @Test func aScriptErrorGoesToTheLinkWithItsSourceAndFrames() {
        let entry = GodotEngineLog(
            kind: .script, message: "Invalid call.", file: "core/variant.cpp", line: 3, function: "_runtime_error",
            scriptFile: "res://probe.gd", scriptLine: 41,
            backtrace: "[0] _runtime_error (res://probe.gd:41)\n[1] run (res://probe.gd:9)\n"
        )
        let input = entry.linkEntry
        #expect(input.level == .error)
        #expect(input.source == GodotSourceLocation(file: "res://probe.gd", line: 41, function: "_runtime_error"))
        #expect(input.backtrace == [
            GodotSourceLocation(file: "res://probe.gd", line: 41, function: "_runtime_error"),
            GodotSourceLocation(file: "res://probe.gd", line: 9, function: "run"),
        ])
        let note = GodotEngineLog(kind: .print, message: "ready", file: "", line: 0, function: "", scriptFile: "", scriptLine: 0, backtrace: "")
        #expect(note.linkEntry.level == .info && note.linkEntry.source == nil && note.linkEntry.backtrace == nil)
    }

    // MARK: Helpers

    private func build(_ slot: GodotSlot, _ files: [String: UInt8], hint: GodotReloadTier = .scene) -> GodotBuild {
        let index = GodotPackIndex(
            format: .pck, files: files.mapValues { Data(repeating: $0, count: 16) },
            engineVersion: GodotEngineVersion(major: 4, minor: 7)
        )
        return GodotBuild(
            slot: slot, packs: [URL(filePath: "/tmp/\(slot.project).pck")], indexes: [index],
            hint: hint, scene: nil, arguments: []
        )
    }

    private func phase(_ host: GodotEngineHost, _ pane: FakeGodotPane) -> GodotPanePhase {
        GodotPanePhase.resolve(
            slot: pane.gameSlot, project: .build, plan: nil, engine: host.engine,
            holdsSurface: host.holdsSurface(pane), loading: host.holdsSurface(pane) ? host.loading : nil,
            paused: host.isPausedByPerson, failure: host.holdsSurface(pane) ? host.failure : nil
        )
    }
}

@MainActor
private final class FakeGodotPane: GodotSurfaceOwner {
    let gameSlot: GodotSlot
    let surfaceSlot = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
    private(set) var leftCount = 0
    /// Keeps the slot in a window, as a shown pane's is.
    private let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 600))

    init(_ slot: GodotSlot) {
        gameSlot = slot
        window.addSubview(surfaceSlot)
    }

    func surfaceDidLeave(lastFrame: UIImage?) {
        leftCount += 1
    }
}

@MainActor
private final class FakeGodotRuntime: GodotEngineRuntime {
    var onLog: ((GodotEngineLog) -> Void)?
    var startSucceeds = true
    var quits = false
    private(set) var started: [GodotStartConfig] = []
    private(set) var reloadedScripts: [[String]] = []
    private(set) var swaps: [URL] = []
    private var frames: Int64 = 0

    func attach(to layer: CALayer) {}
    func resize(to size: CGSize, scale: CGFloat) {}
    func start(_ config: GodotStartConfig) -> Bool {
        started.append(config)
        return startSucceeds
    }
    func iterate() -> Bool {
        frames += 1
        return !quits
    }
    func pause() {}
    func resume() {}
    func focus(_ focused: Bool) {}
    func setMuted(_ muted: Bool) {}
    func mount(_ pack: URL) -> Bool { true }
    func reloadScripts(_ resources: [String]) -> Int {
        reloadedScripts.append(resources)
        return resources.count
    }
    func swap(to pack: URL, scene: String?) -> Bool {
        swaps.append(pack)
        return true
    }
    func reloadScene() -> Bool { true }
    private(set) var touches: [(index: Int, phase: GodotTouchPhase)] = []
    func touch(index: Int, phase: GodotTouchPhase, at point: CGPoint, from previous: CGPoint, pressure: Float, doubleTap: Bool) {
        touches.append((index, phase))
    }
    func key(_ key: UIKey, pressed: Bool) {}
    func key(named name: String, pressed: Bool) -> Bool { true }
    func action(_ name: String, pressed: Bool, strength: Float) -> Bool { true }
    func capturePNG() -> Data? { nil }
    func perf() -> GodotPerf { GodotPerf(framesDrawn: frames) }
}
