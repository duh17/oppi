import SwiftUI

/// Session-list bottom chrome shared by All Sessions and workspace lists.
/// Search lives in the navigation-bar drawer and reveals by pulling the list.
/// The leading Quick Session control is one toolbar capsule — optional leading
/// mic plus placeholder — matching the chat composer. Tapping the capsule
/// presents Quick Session; tapping the mic starts dictation there. The trailing
/// capsule is folder only so Files opens from the same side the browser pushes.
enum SessionInboxComposeChrome {
    static let compactBarPlaceholder = "Message"
    static let compactBarMicWidth: CGFloat = 44
    static let compactBarHitHeight: CGFloat = 44
    /// Trailing folder capsule plus bar gutters. The leading Message capsule
    /// uses the rest of the screen so it covers the session-row title.
    static let messageCapsuleFolderReserve: CGFloat = 120
    /// Bar gutters only, for a bottom bar with no trailing folder capsule.
    static let messageCapsuleSoloReserve: CGFloat = 40
    /// Narrowest expanded Message capsule on compact splits.
    static let messageCapsuleMinWidthFloor: CGFloat = 180

    /// Grow the Message capsule at compact width. Keep it intrinsic at regular
    /// width (iPad, the iPhone Duo inner display), and while now-playing shares
    /// the bottom bar.
    static func expandsMessageCapsule(
        horizontalSizeClass: UserInterfaceSizeClass?,
        hasActivePlayback: Bool
    ) -> Bool {
        guard !hasActivePlayback else { return false }
        return horizontalSizeClass != .regular
    }

    /// Finite min width so the leading capsule covers the title line without
    /// stretching regular iPad to the remaining bar width.
    static func messageCapsuleMinWidth(
        screenWidth: CGFloat,
        expands: Bool,
        reserve: CGFloat = messageCapsuleFolderReserve
    ) -> CGFloat? {
        guard expands else { return nil }
        guard screenWidth > 0 else { return messageCapsuleMinWidthFloor }
        return max(messageCapsuleMinWidthFloor, screenWidth - reserve)
    }

    /// Mic is a one-tap path into Quick Session. Hide it when now-playing
    /// already owns the bar.
    static func showsDictationShortcut(hasActivePlayback: Bool) -> Bool {
        !hasActivePlayback
    }

    /// Folder stays in the trailing capsule on both lists. Enabled whenever a
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
/// presents Quick Session, which owns the real composer.
struct SessionInboxCompactComposeBar: View {
    let showsDictation: Bool
    var hasActivePlayback: Bool = false
    var columnWidth: CGFloat = 0
    /// Width kept free beside the capsule: the folder capsule by default.
    var trailingReserve: CGFloat = SessionInboxComposeChrome.messageCapsuleFolderReserve
    var placeholder: String = SessionInboxComposeChrome.compactBarPlaceholder
    let onStart: () -> Void
    let onDictate: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let expands = SessionInboxComposeChrome.expandsMessageCapsule(
            horizontalSizeClass: horizontalSizeClass,
            hasActivePlayback: hasActivePlayback
        )
        let minWidth = SessionInboxComposeChrome.messageCapsuleMinWidth(
            screenWidth: columnWidth,
            expands: expands,
            reserve: trailingReserve
        )

        Button(action: onStart) {
            if let minWidth {
                // Keep every width finite. Spacer / max-infinity inside a
                // toolbar item reports an unbounded ideal size and the bar
                // drops the capsule.
                HStack(spacing: 0) {
                    if showsDictation {
                        dictationMic
                    }
                    placeholderLabel
                        .frame(
                            width: minWidth - (showsDictation ? SessionInboxComposeChrome.compactBarMicWidth : 0),
                            alignment: .leading
                        )
                }
                .frame(width: minWidth, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    if showsDictation {
                        dictationMic
                    }
                    placeholderLabel
                }
            }
        }
        .accessibilityLabel("Start Quick Session")
        .accessibilityIdentifier("workspace.quickSession.start")
        .accessibilityAction(named: "Dictate Quick Session", onDictate)
    }

    private var placeholderLabel: some View {
        Text(placeholder)
            .font(.subheadline)
            .foregroundStyle(.themeFgDim)
            .lineLimit(1)
            .padding(.leading, showsDictation ? 0 : 16)
            .padding(.trailing, 16)
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

/// Whether the SwiftUI thread detail still has a destination pushed over it,
/// so its Message launcher stays out of the toolbar. (The UIKit session lists
/// keep their launcher installed: their bar items never show over a chat.)
///
/// Depth is the route that owns the screen, evaluated every time. A size-class
/// change rebuilds `[thread, chat]` in one shot; a path
/// count captured on appear would treat that covered count as the surface.
///
/// A thread is the index of its `SessionThreadNavTarget` in the active path
/// (`workspaceStackRouteElements`, or the split detail path) plus one.
///
/// A missing owner is covered. Falling back to the live path count would report
/// `count > count` and install Message on a composer.
enum QuickSessionLauncherCoverage {
    static func isCovered(
        presentation: WorkspaceNavigationPresentation,
        thread target: SessionThreadNavTarget,
        workspaceStack: [WorkspaceStackRouteElement],
        splitDetailElements: [WorkspaceSplitDetailPathElement]
    ) -> Bool {
        switch presentation {
        case .split:
            guard let index = index(of: target, in: splitDetailElements) else { return true }
            return splitDetailElements.count > index + 1
        case .stack:
            guard let index = index(of: target, in: workspaceStack) else { return true }
            return workspaceStack.count > index + 1
        }
    }

    private static func index(
        of target: SessionThreadNavTarget,
        in stack: [WorkspaceStackRouteElement]
    ) -> Int? {
        stack.lastIndex { element in
            if case .sessionThread(let stacked) = element { return stacked == target }
            return false
        }
    }

    private static func index(
        of target: SessionThreadNavTarget,
        in path: [WorkspaceSplitDetailPathElement]
    ) -> Int? {
        path.lastIndex { element in
            if case .sessionThread(let stacked) = element { return stacked == target }
            return false
        }
    }
}

/// The hosted Message capsule and the now-playing player for UIKit session
/// lists. The capsule stays SwiftUI while the SwiftUI thread detail shares it;
/// it returns its host so `SessionListBottomBar` updates it in place
/// (`updating`) instead of rebuilding the bar item.
@MainActor
enum SessionListHostedChrome {
    /// The bottom bar's Message capsule.
    static func composeCapsule(
        updating host: HostedContentController?,
        root: AppRootEnvironment,
        showsDictation: Bool,
        hasActivePlayback: Bool,
        columnWidth: CGFloat,
        onStart: @escaping () -> Void,
        onDictate: @escaping () -> Void
    ) -> HostedContentController {
        let content = SessionInboxCompactComposeBar(
            showsDictation: showsDictation,
            hasActivePlayback: hasActivePlayback,
            columnWidth: columnWidth,
            trailingReserve: SessionInboxComposeChrome.messageCapsuleFolderReserve,
            onStart: onStart,
            onDictate: onDictate
        )
        return barHost(host, content: content, root: root)
    }

    /// The full-screen player over the list.
    static func presentNowPlayingPlayer(_ audioPlayer: AudioPlayerService, from presenter: UIViewController) {
        Router.present(presentation: .fullScreen, from: presenter) {
            InAppNowPlayingPlayerScreen(audioPlayer: audioPlayer)
        }
    }

    private static func barHost(
        _ host: HostedContentController?,
        content: SessionInboxCompactComposeBar,
        root: AppRootEnvironment
    ) -> HostedContentController {
        if let host {
            host.setContent(content)
            return host
        }
        let host = HostFactory.content(content, root: root)
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        return host
    }
}
