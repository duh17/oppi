import Foundation
import Testing
import UIKit
@testable import Oppi

/// The real engine (`GodotRuntime`), in builds that include it; a build
/// without the engine has nothing to test here. The sample game
/// (`godot-sample.pck`) starts again after the engine stops, in the same
/// process, and a reload while a scene change is still pending (a paused
/// game runs no frame to finish a swap or an earlier reload) reloads that
/// scene instead of failing. The game draws over exactly its pane through a
/// divider's hold, a restart under it, a move and a rotation. One suite, run
/// in order: the engine is one per process.
@MainActor
@Suite("GodotRuntime", .serialized)
struct GodotRuntimeTests {
    @Test func theEngineStartsAgainAndReloadsWhileASceneChangeIsPending() throws {
        guard let runtime = GodotRuntimes.make() else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "godot-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pack = folder.appending(path: "sample.pck")
        try FileManager.default.copyItem(
            at: try #require(TestFixtures.bundle.url(forResource: "godot-sample", withExtension: "pck")), to: pack
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        runtime.attach(to: view.layer)
        runtime.resize(to: view.bounds.size, scale: 2)
        let config = GodotStartConfig(
            packs: [pack], userFolder: folder.appending(path: "user"), cacheFolder: folder.appending(path: "cache"),
            readableFolders: [], arguments: []
        )

        for round in 1...3 {
            #expect(runtime.start(config), "Start \(round)")
            var frames = 0
            while runtime.perf().framesDrawn < 1, frames < 300 {
                _ = runtime.iterate()
                frames += 1
            }
            #expect(runtime.perf().framesDrawn >= 1, "Start \(round) draws")
            // No frame runs between these, as in a paused pane.
            #expect(runtime.swap(to: pack, scene: nil))
            #expect(runtime.reloadScene(), "A reload right after a swap, start \(round)")
            #expect(runtime.reloadScene(), "A second reload in a row, start \(round)")
            #expect(runtime.iterate())
            #expect(runtime.iterate(), "The reloaded scene runs")
            runtime.stop()
        }
    }

    /// A game with 3D physics (the sample's `--bodies`) ends and starts again
    /// in the same process, as when its last pane closes and it is opened
    /// again: the first physics step of the next engine must not reach jobs
    /// the previous engine's Jolt freed. Before, a few rounds crashed in
    /// `JoltJobSystem::post_step`.
    @Test func aPhysicsGameStartsAgainManyTimes() throws {
        guard let runtime = GodotRuntimes.make() else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "godot-physics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pack = folder.appending(path: "sample.pck")
        try FileManager.default.copyItem(
            at: try #require(TestFixtures.bundle.url(forResource: "godot-sample", withExtension: "pck")), to: pack
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        runtime.attach(to: view.layer)
        runtime.resize(to: view.bounds.size, scale: 2)
        let config = GodotStartConfig(
            packs: [pack], userFolder: folder.appending(path: "user"), cacheFolder: folder.appending(path: "cache"),
            readableFolders: [], arguments: ["--", "--bodies"]
        )
        var dropped = 0
        runtime.onLog = { if $0.message == "sample dropped 400 bodies" { dropped += 1 } }
        defer { runtime.onLog = nil }
        // The freed jobs crash only when their memory no longer reads as one,
        // which took a few rounds on the old engine.
        for round in 1...40 {
            #expect(runtime.start(config), "Start \(round)")
            for _ in 0..<30 { #expect(runtime.iterate()) }
            runtime.stop()
        }
        #expect(dropped == 40, "Every round ran the physics scene")
    }

    /// A new build swaps in while the old scene still runs: its scripts reload
    /// in place, then the old scene leaves under the new code. The new build
    /// (`godot-sample-new-member.pck`, the sample plus a typed `trail` array
    /// its `_exit_tree` loops over) adds a member the old instance never
    /// initialized; it must read as an empty array, not crash the app.
    @Test func aSwapToABuildThatAddsATypedMemberLeavesTheOldScene() throws {
        guard let runtime = GodotRuntimes.make() else { return }
        defer { runtime.stop() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "godot-member-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func copy(_ name: String) throws -> URL {
            let url = folder.appending(path: "\(name).pck")
            try FileManager.default.copyItem(at: try #require(TestFixtures.bundle.url(forResource: name, withExtension: "pck")), to: url)
            return url
        }
        let old = try copy("godot-sample")
        let new = try copy("godot-sample-new-member")
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        runtime.attach(to: view.layer)
        runtime.resize(to: view.bounds.size, scale: 2)
        var lines: [String] = []
        runtime.onLog = { lines.append($0.message) }
        defer { runtime.onLog = nil }
        #expect(runtime.start(GodotStartConfig(
            packs: [old], userFolder: folder.appending(path: "user"), cacheFolder: folder.appending(path: "cache"),
            readableFolders: [], arguments: []
        )))
        #expect(runtime.iterate())

        #expect(runtime.swap(to: new, scene: nil))
        #expect(runtime.iterate(), "The new scene runs")
        #expect(lines.contains("sample left with trail of 0"))
    }

    @Test func theGameDrawsOverItsPaneThroughAHoldARestartAMoveAndARotation() async throws {
        guard let runtime = GodotRuntimes.make() else { return }
        defer { runtime.stop() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "godot-fit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pack = folder.appending(path: "sample.pck")
        try FileManager.default.copyItem(
            at: try #require(TestFixtures.bundle.url(forResource: "godot-sample", withExtension: "pck")), to: pack
        )
        let slot = GodotSlot(serverId: "sha256:fit", project: "games~fit-\(UUID().uuidString)")
        let build = GodotBuild(
            slot: slot, packs: [pack], indexes: [try GodotPackIndex(contentsOf: pack)], hint: .scene, scene: nil, arguments: []
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        window.isHidden = false
        let first = SizedGodotPane(slot, frame: CGRect(x: 0, y: 0, width: 375, height: 600), in: window)
        let second = SizedGodotPane(slot, frame: CGRect(x: 400, y: 0, width: 600, height: 300), in: window)
        let host = GodotEngineHost(runtime: runtime)
        let surface = host.surface

        #expect(await host.play(build, in: first) == .start)
        #expect(drawn(surface) == surface.bounds, "First start")

        // A divider moves: the engine keeps its size and is stretched to the pane.
        surface.holdSize()
        first.surfaceSlot.frame.size = CGSize(width: 750, height: 300)
        surface.layoutIfNeeded()
        #expect(drawn(surface) == surface.bounds, "Held and stretched")

        // The game starts again under the hold (a switch back, Play).
        await host.restart(build)
        #expect(drawn(surface) == surface.bounds, "Restarted while held")

        // It moves to another pane while still held.
        await host.play(build, in: second)
        #expect(surface.superview === second.surfaceSlot)
        #expect(surface.layer.sublayerTransform.m11 == 1 && surface.layer.sublayerTransform.m22 == 1, "No stretch left in the new pane")
        #expect(drawn(surface) == surface.bounds, "Moved to another pane")

        // A rotation turns the pane.
        second.surfaceSlot.frame.size = CGSize(width: 300, height: 600)
        surface.layoutIfNeeded()
        #expect(drawn(surface) == surface.bounds, "Rotated")
    }

    /// The game fills its pane through every way a pane changes size: a zoom
    /// and back (a jump, no hold), a live window resize (held, settled at
    /// each pause), a rotation, a pane out of the window with a hold left
    /// over and resized there, and a resize while the person paused the game,
    /// which draws again at the new size with the game's time standing
    /// still. A project that keeps its aspect gets its letterbox.
    @Test(arguments: [false, true])
    func theGameFillsItsPaneThroughEveryResize(keepsAspect: Bool) async throws {
        guard let runtime = GodotRuntimes.make() else { return }
        defer { runtime.stop() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "godot-resize-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pack = folder.appending(path: "sample.pck")
        try FileManager.default.copyItem(
            at: try #require(TestFixtures.bundle.url(forResource: "godot-sample", withExtension: "pck")), to: pack
        )
        let slot = GodotSlot(serverId: "sha256:resize", project: "games~resize-\(UUID().uuidString)")
        let build = GodotBuild(
            slot: slot, packs: [pack], indexes: [try GodotPackIndex(contentsOf: pack)], hint: .scene, scene: nil,
            arguments: keepsAspect ? ["--keep"] : []
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 1200))
        window.isHidden = false
        let pane = SizedGodotPane(slot, frame: CGRect(x: 0, y: 0, width: 375, height: 600), in: window)
        let host = GodotEngineHost(runtime: runtime)
        let surface = host.surface
        #expect(await host.play(build, in: pane) == .start)

        /// The engine's layer covers the pane unstretched, and the game's
        /// next frame is the pane's size in pixels (its letterbox's, keeping
        /// the sample's 375 × 600 aspect).
        func expectFills(_ step: String, paused: Bool = false) {
            let bounds = surface.bounds
            #expect(drawn(surface) == bounds, "\(step): the layer covers the pane")
            #expect(CATransform3DIsIdentity(surface.layer.sublayerTransform), "\(step): no stretch")
            #expect(surface.layer.sublayers?.first?.bounds.size == bounds.size, "\(step): the engine draws at the pane's size")
            // A paused game's frame is the one its resize drew.
            if !paused { #expect(runtime.iterate(), "\(step): a frame at this size") }
            let scale = surface.traitCollection.displayScale
            var expected = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if keepsAspect {
                let fit = min(expected.width / 375, expected.height / 600)
                expected = CGSize(width: 375 * fit, height: 600 * fit)
            }
            let frame = runtime.capturePNG().flatMap(UIImage.init(data:))?.size
            #expect(
                frame.map { abs($0.width - expected.width) <= 1 && abs($0.height - expected.height) <= 1 } == true,
                "\(step): the game's frame is \(String(describing: frame)), the pane's \(expected)"
            )
        }
        expectFills("Start")

        // Zoom and back: the pane jumps to its new size with no hold.
        pane.surfaceSlot.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        surface.layoutIfNeeded()
        expectFills("Zoomed")
        pane.surfaceSlot.frame = CGRect(x: 0, y: 0, width: 375, height: 600)
        surface.layoutIfNeeded()
        expectFills("Unzoomed")

        // A live window resize (Split View, Stage Manager): held while it
        // moves, settled at a pause and at the end.
        surface.holdSize()
        for width in stride(from: 400, through: 700, by: 50) {
            pane.surfaceSlot.frame.size.width = CGFloat(width)
            surface.layoutIfNeeded()
        }
        surface.settleSize()
        expectFills("Live resize, paused")
        surface.holdSize()
        pane.surfaceSlot.frame.size = CGSize(width: 520, height: 640)
        surface.layoutIfNeeded()
        surface.settleSize()
        expectFills("Live resize, ended")

        // A rotation turns the pane.
        pane.surfaceSlot.frame.size = CGSize(width: 640, height: 520)
        surface.layoutIfNeeded()
        expectFills("Rotated")

        // A hold left over when the pane leaves the window: its settle skips
        // a pane out of the window, and the pane comes back another size.
        surface.holdSize()
        pane.surfaceSlot.removeFromSuperview()
        pane.surfaceSlot.frame.size = CGSize(width: 450, height: 700)
        window.addSubview(pane.surfaceSlot)
        surface.layoutIfNeeded()
        expectFills("Back in the window")

        // Paused by the person, the pane resizes: the game draws once at the
        // new size and stays paused.
        host.setPausedByPerson(true)
        let paused = runtime.perf().framesDrawn
        pane.surfaceSlot.frame.size = CGSize(width: 700, height: 450)
        surface.layoutIfNeeded()
        #expect(runtime.perf().framesDrawn == paused + 1, "Paused: one frame at the new size")
        expectFills("Resized while paused", paused: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runtime.perf().framesDrawn == paused + 1, "Paused: no frame runs after it")
        host.setPausedByPerson(false)
    }

    /// Play Full Screen in a real pane host on the mini in landscape: the
    /// game's pane takes the whole window with no grip or strip, the engine
    /// resizes to it, and leaving puts the split back exactly as it was,
    /// the engine at the pane's size again. Without the engine the panes
    /// still do the same.
    @Test func fullScreenFillsTheWindowAndLeavingRestoresTheSplit() async throws {
        let runtime = GodotRuntimes.make()
        defer { runtime?.stop() }
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        defer { host.hide() }
        let slot = GodotSlot(serverId: "sha256:full", project: "games~full-\(UUID().uuidString)")
        let game = GameScreen(slot)
        // A pane right of the chat holding the game, as a placed Godot link opens one.
        host.act {
            let entry = PaneStackEntry(serverId: "s", route: .godot(project: "full"))
            guard let made = host.scenePanes.split(host.scenePanes.routedLeafID, edge: .right, showing: entry) else { return }
            host.panes.openingScreens[made] = game
            host.panes.syncSplitLeaves()
            host.panes.focus(cell: made)
        }
        let cell = try #require(host.panes.cell(holding: game))
        let engine = GodotEngineHost(runtime: runtime)
        let folder = FileManager.default.temporaryDirectory.appending(path: "godot-full-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        if runtime != nil {
            let pack = folder.appending(path: "sample.pck")
            try FileManager.default.copyItem(
                at: try #require(TestFixtures.bundle.url(forResource: "godot-sample", withExtension: "pck")), to: pack
            )
            let build = GodotBuild(slot: slot, packs: [pack], indexes: [try GodotPackIndex(contentsOf: pack)], hint: .scene, scene: nil, arguments: [])
            #expect(await engine.play(build, in: game) == .start)
        } else {
            engine.take(for: game)
        }
        host.act {}
        let surface = engine.surface
        let split = host.scenePanes.cellLayout
        let paneFrame = game.surfaceSlot.convert(game.surfaceSlot.bounds, to: host.window)
        #expect(paneFrame.width < host.window.bounds.width / 2 + 1, "The game shares the window")
        #expect(surface.bounds.size == paneFrame.size)
        #expect(game.additionalSafeAreaInsets.top > 0, "Its grip's strip sits under its bar")

        host.act { #expect(host.panes.enterFullScreen(cell)) }
        #expect(host.scenePanes.fullScreenCell == cell)
        #expect(game.surfaceSlot.convert(game.surfaceSlot.bounds, to: host.window) == host.window.bounds, "The game takes the window")
        #expect(game.additionalSafeAreaInsets.top == 0, "No grip strip")
        let gripsHidden = host.panes.grips.values.allSatisfy { $0.isHidden }
        #expect(gripsHidden, "No grip")
        #expect(surface.bounds == host.window.bounds)
        if runtime != nil {
            #expect(drawn(surface) == surface.bounds && surface.layer.sublayers?.first?.bounds.size == surface.bounds.size,
                    "The engine draws at the window's size")
        }

        host.act { host.panes.exitFullScreen() }
        #expect(host.scenePanes.fullScreenCell == nil)
        #expect(host.scenePanes.cellLayout == split, "The split comes back as it was")
        #expect(game.surfaceSlot.convert(game.surfaceSlot.bounds, to: host.window) == paneFrame, "The game is back in its pane")
        #expect(surface.bounds.size == paneFrame.size)
        if runtime != nil {
            #expect(drawn(surface) == surface.bounds && surface.layer.sublayers?.first?.bounds.size == surface.bounds.size,
                    "The engine draws at the pane's size again")
        }

        // A zoom of another pane ends full screen too, and a later zoom of
        // the game is only a zoom.
        host.act { #expect(host.panes.enterFullScreen(cell)) }
        host.act { host.panes.zoom(host.scenePanes.routedLeafID) }
        #expect(host.scenePanes.fullScreenCell == nil)
        host.act { host.panes.zoom(cell) }
        #expect(host.scenePanes.fullScreenCell == nil)
    }

    /// Where the engine's layer lands in the surface, its stretch included.
    private func drawn(_ surface: GodotSurfaceView) -> CGRect? {
        guard let layer = surface.layer.sublayers?.first else { return nil }
        let rect = surface.layer.convert(layer.bounds, from: layer)
        return CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }
}

@MainActor
private final class SizedGodotPane: GodotSurfaceOwner {
    let gameSlot: GodotSlot
    let surfaceSlot: UIView

    init(_ slot: GodotSlot, frame: CGRect, in window: UIWindow) {
        gameSlot = slot
        surfaceSlot = UIView(frame: frame)
        window.addSubview(surfaceSlot)
    }

    func surfaceDidLeave(lastFrame: UIImage?) {}
}

/// A split pane's screen that holds the game's view over all of itself.
@MainActor
private final class GameScreen: UIViewController, GodotSurfaceOwner {
    let gameSlot: GodotSlot
    let surfaceSlot = UIView()

    init(_ slot: GodotSlot) {
        gameSlot = slot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        surfaceSlot.frame = view.bounds
        surfaceSlot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(surfaceSlot)
    }

    func surfaceDidLeave(lastFrame: UIImage?) {}
}
