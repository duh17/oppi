import SwiftUI

private struct ComposerDraftStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: ComposerDraftStore? = nil
}

extension EnvironmentValues {
    var composerDraftStore: ComposerDraftStore? {
        get { self[ComposerDraftStoreEnvironmentKey.self] }
        set { self[ComposerDraftStoreEnvironmentKey.self] = newValue }
    }
}
