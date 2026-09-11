import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    /// Leading folder capsule plus bar gutters. The trailing Message capsule
    /// uses the rest of the screen so it covers the last session-row title.
    static let trailingCapsuleFolderReserve: CGFloat = 120
    /// Narrowest expanded Message capsule on compact splits.
    static let trailingCapsuleMinWidthFloor: CGFloat = 180

    /// Grow the trailing capsule on iPhone and compact iPad. Keep it intrinsic
    /// on regular-width iPad, and while now-playing shares the bottom bar.
    static func expandsTrailingCapsule(
        horizontalSizeClass: UserInterfaceSizeClass?,
        idiom: UIUserInterfaceIdiom,
        hasActivePlayback: Bool
    ) -> Bool {
        guard !hasActivePlayback else { return false }
        if horizontalSizeClass == .regular && idiom == .pad { return false }
        return true
    }

    /// Finite min width so the capsule grows left over the title line without
    /// stretching regular iPad to the remaining bar width.
    static func trailingCapsuleMinWidth(
        screenWidth: CGFloat,
        expands: Bool
    ) -> CGFloat? {
        guard expands else { return nil }
        guard screenWidth > 0 else { return trailingCapsuleMinWidthFloor }
        return max(trailingCapsuleMinWidthFloor, screenWidth - trailingCapsuleFolderReserve)
    }

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
    var hasActivePlayback: Bool = false
    var columnWidth: CGFloat = 0
    var onIncognito: (() -> Void)? = nil
    let onStart: () -> Void
    let onDictate: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let expands = SessionInboxComposeChrome.expandsTrailingCapsule(
            horizontalSizeClass: horizontalSizeClass,
            idiom: UIDevice.current.userInterfaceIdiom,
            hasActivePlayback: hasActivePlayback
        )
        let minWidth = SessionInboxComposeChrome.trailingCapsuleMinWidth(
            screenWidth: columnWidth,
            expands: expands
        )

        Button(action: onStart) {
            if let minWidth {
                // Keep every width finite. Spacer / max-infinity inside a
                // toolbar item reports an unbounded ideal size and the bar
                // drops the capsule.
                HStack(spacing: 0) {
                    placeholderLabel
                        .frame(
                            width: minWidth - (showsDictation ? SessionInboxComposeChrome.compactBarMicWidth : 0),
                            alignment: .leading
                        )
                    if showsDictation {
                        dictationMic
                    }
                }
                .frame(width: minWidth, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    placeholderLabel
                    if showsDictation {
                        dictationMic
                    }
                }
            }
        }
        .accessibilityLabel("Start Quick Session")
        .accessibilityIdentifier("workspace.quickSession.start")
        .accessibilityAction(named: "Dictate Quick Session", onDictate)
        .modifier(SessionInboxIncognitoContextMenu(onIncognito: onIncognito))
    }

    private var placeholderLabel: some View {
        Text(SessionInboxComposeChrome.compactBarPlaceholder)
            .font(.subheadline)
            .foregroundStyle(.themeFgDim)
            .lineLimit(1)
            .padding(.leading, 16)
            .padding(.trailing, showsDictation ? 0 : 16)
    }

    private var dictationMic: some View {
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
