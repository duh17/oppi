import SwiftUI

extension EnvironmentValues {
    /// Bumps when `FontPreferenceStore` changes (⌘+ / ⌘- / ⌘0, Settings).
    /// Views that read the font statics depend on this so SwiftUI re-renders
    /// them in place; nothing remounts, so scroll and fold state survive.
    @Entry var macTypographyRevision = 0
}

/// Installed once per window root.
struct MacTypographyRevisionHost: ViewModifier {
    @State private var revision = 0

    func body(content: Content) -> some View {
        content
            .environment(\.macTypographyRevision, revision)
            .onReceive(NotificationCenter.default.publisher(
                for: FontPreferenceStore.didChangeNotification
            )) { _ in
                revision &+= 1
            }
    }
}
