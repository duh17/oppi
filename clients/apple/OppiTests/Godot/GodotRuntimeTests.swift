import Foundation
import Testing
import UIKit
@testable import Oppi

/// The real engine (`GodotRuntime`), in builds that include it; a build
/// without the engine has nothing to test here. The sample game
/// (`godot-sample.pck`) starts again after the engine stops, in the same
/// process, and a reload while a scene change is still pending (a paused
/// game runs no frame to finish a swap or an earlier reload) reloads that
/// scene instead of failing.
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
}
