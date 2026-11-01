import Foundation
@testable import Oppi

/// Rex and Herdr are off by default (Settings → Experiments); the suites that
/// exercise what they add need both on for the whole run.
///
/// A load-time constructor (`OppiTestExperimentsAtLoad.m`) reaches this before any
/// test runs. The bundle's principal class would do it too, but that needs an
/// Info.plist entry, and the plist is gitignored and regenerated from a template
/// (`clients/apple/scripts/sim-pool-ops.ts`), so the constructor is used instead: it
/// depends on no generated file. A registration domain is process-wide and stores
/// nothing — unlike `set`, it never reaches the app container. The off contract
/// passes an explicit `SSHTerminalExperimentAccess` and never reads it.
@_cdecl("OppiSeedTestExperiments")
public func OppiSeedTestExperiments() {
    UserDefaults.standard.register(defaults: [
        AppPreferenceStore.Experiments.rexKey: true,
        AppPreferenceStore.Experiments.herdrKey: true,
    ])
}
