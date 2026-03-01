import SwiftUI

private struct AllowsFullScreenExpansionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether inline content views should expose nested "open full screen" controls.
    var allowsFullScreenExpansion: Bool {
        get { self[AllowsFullScreenExpansionKey.self] }
        set { self[AllowsFullScreenExpansionKey.self] = newValue }
    }
}

extension View {
    /// Enable/disable nested full-screen expansion affordances for descendants.
    func allowsFullScreenExpansion(_ allowed: Bool) -> some View {
        environment(\.allowsFullScreenExpansion, allowed)
    }
}
