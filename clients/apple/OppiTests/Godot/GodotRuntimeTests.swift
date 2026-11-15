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
