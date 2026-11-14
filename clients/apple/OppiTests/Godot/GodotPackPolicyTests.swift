import Foundation
import Testing
@testable import Oppi

/// How a new build reaches the one engine: the first game starts it; a new
/// build of that game reloads scripts in place only when nothing but existing
/// scripts changed; anything that the engine would have to start again for
/// (another game, project settings, autoloads, global classes, a game that
/// quit) waits for a relaunch; native code and newer exports are refused.
@Suite("GodotPackPolicy")
struct GodotPackPolicyTests {
    let slot = GodotSlot(serverId: "sha256:studio", project: "games~tide")

    private func digest(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

    private func pack(_ files: [String: UInt8?], version: GodotEngineVersion? = GodotEngineVersion(major: 4, minor: 7)) -> GodotPackIndex {
        GodotPackIndex(format: .pck, files: files.mapValues { $0.map(digest) }, engineVersion: version)
    }

    private var base: GodotPackIndex {
        pack(["project.binary": 1, "main.gd": 2, "main.tscn": 3, "player.gd": 4])
    }

    private func loaded(_ packs: [GodotPackIndex]) -> GodotLoadedBuild {
        GodotLoadedBuild(slot: slot, files: GodotPackPolicy.merged(packs))
    }

    private func plan(_ packs: [GodotPackIndex], hint: GodotReloadTier = .scripts, loaded: GodotLoadedBuild?, engine: GodotEngineState) -> GodotApplyPlan {
        GodotPackPolicy.plan(slot: slot, packs: packs, hint: hint, loaded: loaded, engine: engine)
    }

    @Test func theFirstGameStartsTheEngine() {
        #expect(plan([base], loaded: nil, engine: .idle) == .start)
    }

    @Test func aChangedScriptReloadsInPlace() {
        let next = pack(["project.binary": 1, "main.gd": 9, "main.tscn": 3, "player.gd": 4])
        #expect(plan([next], loaded: loaded([base]), engine: .running(slot)) == .scripts(["res://main.gd"]))
    }

    @Test func anExportedScriptReloadsAsItsSource() {
        let compiled = pack(["project.binary": 1, "main.gdc": 2])
        let next = pack(["project.binary": 1, "main.gdc": 5])
        #expect(plan([next], loaded: loaded([compiled]), engine: .running(slot)) == .scripts(["res://main.gd"]))
    }

    @Test func aPatchPackOverTheBaseReloadsOnlyWhatItChanges() {
        let patch = GodotPackIndex(format: .zip, files: ["player.gd": digest(7)], engineVersion: nil)
        #expect(plan([base, patch], loaded: loaded([base]), engine: .running(slot)) == .scripts(["res://player.gd"]))
    }

    @Test func aRestartHintRulesOutTheScriptTier() {
        let next = pack(["project.binary": 1, "main.gd": 9, "main.tscn": 3, "player.gd": 4])
        #expect(plan([next], hint: .restart, loaded: loaded([base]), engine: .running(slot)) == .scene)
    }

    @Test(arguments: [
        ["project.binary": 1, "main.gd": 2, "main.tscn": 8, "player.gd": 4] as [String: UInt8?],
        ["project.binary": 1, "main.gd": 2, "main.tscn": 3, "player.gd": 4, "enemy.gd": 5],
        ["project.binary": 1, "main.gd": 2, "main.tscn": 3],
    ])
    func aSceneOrANewOrRemovedScriptReloadsTheScene(_ files: [String: UInt8?]) {
        #expect(plan([pack(files)], loaded: loaded([base]), engine: .running(slot)) == .scene)
    }

    @Test func aPatchRemovingAFileReloadsTheScene() {
        let patch = pack(["player.gd": nil])
        #expect(plan([base, patch], loaded: loaded([base]), engine: .running(slot)) == .scene)
    }

    @Test func theSameFilesChangeNothing() {
        #expect(plan([base], loaded: loaded([base]), engine: .running(slot)) == .unchanged)
    }

    @Test(arguments: ["project.binary", ".godot/global_script_class_cache.cfg"])
    func projectSettingsOrGlobalClassesNeedARelaunch(_ path: String) {
        var files: [String: UInt8?] = ["project.binary": 1, "main.gd": 2, "main.tscn": 3, "player.gd": 4]
        files[path] = 42
        #expect(plan([pack(files)], loaded: loaded([base]), engine: .running(slot)) == .relaunch(.projectSettings))
    }

    @Test func anotherGameWaitsForARelaunch() {
        let other = GodotSlot(serverId: "sha256:studio", project: "games~other")
        #expect(plan([base], loaded: GodotLoadedBuild(slot: other, files: [:]), engine: .running(other)) == .relaunch(.otherGame))
    }

    @Test func aStoppedEngineWaitsForARelaunch() {
        #expect(plan([base], loaded: loaded([base]), engine: .stopped) == .relaunch(.engineStopped))
    }

    @Test(arguments: [
        "bin/libgame.dylib", "addons/x/x.gdextension", ".godot/extension_list.cfg",
        "bin/Game.dll", "ios/Plugin.framework/Plugin", "ios/libplugin.a",
    ])
    func nativeCodeIsRefusedWhateverTheEngineRuns(_ path: String) {
        let native = pack(["project.binary": 1, path: 9])
        #expect(plan([native], loaded: nil, engine: .idle) == .refuse(.nativeCode(path: path)))
        #expect(plan([base, native], loaded: loaded([base]), engine: .running(slot)) == .refuse(.nativeCode(path: path)))
    }

    @Test func aPackFromANewerGodotIsRefused() {
        let newer = pack(["project.binary": 1], version: GodotEngineVersion(major: 4, minor: 8))
        #expect(plan([newer], loaded: nil, engine: .idle) == .refuse(.newerEngine(GodotEngineVersion(major: 4, minor: 8))))
        let older = pack(["project.binary": 1], version: GodotEngineVersion(major: 4, minor: 5))
        #expect(plan([older], loaded: nil, engine: .idle) == .start)
    }
}
