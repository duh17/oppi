import SwiftUI

/// All Sessions bottom-bar compose cluster. Search stays leading. The trailing
/// Quick Session control is one toolbar capsule — placeholder plus an optional
/// trailing mic — using the same system glass as search. Tapping the capsule
/// presents Quick Session; tapping the mic starts dictation there.
/// Workspace-scoped lists keep a pencil that creates a session immediately.
enum SessionInboxComposeChrome {
    static let compactBarPlaceholder = "Message"
    static let compactBarMicWidth: CGFloat = 44
    static let compactBarHitHeight: CGFloat = 44

    /// Mic is a one-tap path into Quick Session. Hide it when compose creates
    /// a workspace session instead, or when now-playing already owns the bar.
    static func showsDictationShortcut(
        voiceInputEnabled: Bool,
        hasSelectedWorkspace: Bool,
        hasActivePlayback: Bool
    ) -> Bool {
        voiceInputEnabled && !hasSelectedWorkspace && !hasActivePlayback
    }

    static func usesCompactQuickSessionBar(hasSelectedWorkspace: Bool) -> Bool {
        !hasSelectedWorkspace
    }
}

/// Collapsed All Sessions compose launcher. Not a live text field — tap
/// presents Quick Session, which owns the real ChatInputBar.
struct SessionInboxCompactComposeBar: View {
    let showsDictation: Bool
    let onStart: () -> Void
    let onDictate: () -> Void

    var body: some View {
        Button(action: onStart) {
            HStack(spacing: 8) {
                Text(SessionInboxComposeChrome.compactBarPlaceholder)
                    .font(.subheadline)
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(1)
                    .padding(.leading, 16)
                    .padding(.trailing, showsDictation ? 0 : 16)

                if showsDictation {
                    Image(systemName: "mic")
                        .font(.body)
                        .foregroundStyle(.themeFg)
                        .frame(
                            width: SessionInboxComposeChrome.compactBarMicWidth,
                            height: SessionInboxComposeChrome.compactBarHitHeight
                        )
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded(onDictate))
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("workspace.quickSession.dictate")
                }
            }
        }
        .accessibilityLabel("Start Quick Session")
        .accessibilityIdentifier("workspace.quickSession.start")
        .accessibilityAction(named: "Dictate Quick Session", onDictate)
    }
}
