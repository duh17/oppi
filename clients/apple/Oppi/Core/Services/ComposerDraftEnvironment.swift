import SwiftUI

private struct ComposerDraftStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: ComposerDraftStore? = nil
}

private struct ComposerMediaImportGateEnvironmentKey: EnvironmentKey {
    static let defaultValue: ComposerMediaImportGate? = nil
}

/// Generation token so delayed Photo Library imports cannot attach to a
/// different session or an already-sent draft.
@MainActor
final class ComposerMediaImportGate {
    private(set) var epoch: UInt64 = 0

    func invalidate() {
        epoch &+= 1
    }

    func isCurrent(_ captured: UInt64) -> Bool {
        captured == epoch
    }
}

extension EnvironmentValues {
    var composerDraftStore: ComposerDraftStore? {
        get { self[ComposerDraftStoreEnvironmentKey.self] }
        set { self[ComposerDraftStoreEnvironmentKey.self] = newValue }
    }

    var composerMediaImportGate: ComposerMediaImportGate? {
        get { self[ComposerMediaImportGateEnvironmentKey.self] }
        set { self[ComposerMediaImportGateEnvironmentKey.self] = newValue }
    }
}
