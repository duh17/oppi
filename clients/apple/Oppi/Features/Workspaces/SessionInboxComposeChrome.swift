import SwiftUI

/// Session-list bottom chrome shared by All Sessions and workspace lists.
/// The leading capsule is folder only. Search lives in the navigation-bar
/// drawer and reveals by pulling the list. The trailing Quick Session control
/// is one toolbar capsule — placeholder plus an optional trailing mic — using
/// the same system glass. Tapping the capsule presents Quick Session; tapping
/// the mic starts dictation there. Workspace lists keep Incognito on a context menu.
enum SessionInboxComposeChrome {
    static let compactBarPlaceholder = "Message"
    static let compactBarMicWidth: CGFloat = 44
    static let compactBarHitHeight: CGFloat = 44

    /// Mic is a one-tap path into Quick Session. Hide it when now-playing
    /// already owns the bar.
    static func showsDictationShortcut(
        voiceInputEnabled: Bool,
        hasActivePlayback: Bool
    ) -> Bool {
        voiceInputEnabled && !hasActivePlayback
    }

    /// Folder stays in the leading capsule on both lists. Enabled whenever a
    /// server is connected. Workspace lists open workspace files; All Sessions
    /// opens the connected server's home directory.
    static func canOpenFiles(hasServer: Bool) -> Bool {
        hasServer
    }
}

/// All Sessions searches every workspace. A workspace list stays in that workspace.
enum SessionInboxSearchScope {
    static func workspaceId(scopedTo workspaceId: String?) -> String? {
        let trimmed = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Collapsed session-list compose launcher. Not a live text field — tap
/// presents Quick Session, which owns the real ChatInputBar.
struct SessionInboxCompactComposeBar: View {
    let showsDictation: Bool
    var onIncognito: (() -> Void)? = nil
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
        .modifier(SessionInboxIncognitoContextMenu(onIncognito: onIncognito))
    }
}

private struct SessionInboxIncognitoContextMenu: ViewModifier {
    let onIncognito: (() -> Void)?

    func body(content: Content) -> some View {
        if let onIncognito {
            content.contextMenu {
                Button(action: onIncognito) {
                    Label("Incognito Session", systemImage: "eye.slash")
                }
            }
        } else {
            content
        }
    }
}

/// Folder control for the leading bottom-bar capsule. Keep this a single
/// toolbar Button — do not wrap it in nested toolbar Buttons or a custom
/// glass effect.
struct SessionInboxFolderToolbarButton: View {
    let isEnabled: Bool
    let accessibilityLabel: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Image(systemName: "folder")
        }
        .foregroundStyle(isEnabled ? .themeFg : .themeFgDim)
        .disabled(!isEnabled)
        .accessibilityIdentifier("workspace.files.open")
        .accessibilityLabel(accessibilityLabel)
    }
}
