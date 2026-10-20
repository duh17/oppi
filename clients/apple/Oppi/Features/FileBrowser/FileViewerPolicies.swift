import Foundation

/// Where the file viewer sits: a screen of its own with the reader's chrome,
/// or a pane beside a file list or under a review header.
enum FileBrowserContentChromeMode {
    case pushed
    case treePane
}

enum FileBrowserContentSource: Equatable {
    case workspaceFile
    case sessionFile(sessionId: String)
    case hostFile

    var routesFileReferencesThroughSession: Bool {
        if case .sessionFile = self { return true }
        return false
    }
}

/// A host file that is one of an editable Skill's own files: the editor reads
/// and writes it through `/files/current?origin=skill`.
struct SkillFileEditTarget: Equatable {
    let skillId: String
    /// Skill-relative path.
    let path: String
}

enum FileBrowserContentRenderingPolicy {
    static func showsNavigationChrome(
        for chromeMode: FileBrowserContentChromeMode,
        source: FileBrowserContentSource = .workspaceFile
    ) -> Bool {
        chromeMode == .pushed && source != .hostFile
    }

    static func navigationTitle(
        source: FileBrowserContentSource,
        path: String,
        fileName: String
    ) -> String {
        source == .hostFile ? path : fileName
    }

    /// The file viewer already owns the filename in navigation chrome.
    static let audioPlayerTitlePresentation: AudioLyricsPlayerTitlePresentation = .hostOwnsTitle

    enum EditPlacement: Equatable {
        /// The embedded UIKit reader shows its own navigation bar; Edit is one of its actions.
        case readerNavigationAction
        /// The reader's bar is hidden (tree pane, host files); Edit is a bar item of the screen.
        case toolbar
    }

    static func editPlacement(
        for chromeMode: FileBrowserContentChromeMode,
        source: FileBrowserContentSource
    ) -> EditPlacement {
        showsNavigationChrome(for: chromeMode, source: source) ? .readerNavigationAction : .toolbar
    }

    /// Which checkout an edit writes to. A worktree is always named; main is
    /// named only when the owning chat session runs on a worktree, so the
    /// difference is visible before typing.
    static func checkoutSubtitle(
        source: FileBrowserContentSource,
        worktreeId: String?,
        sessionWorktreeId: String?
    ) -> String? {
        guard source == .workspaceFile else { return nil }
        if let worktreeId, !worktreeId.isEmpty {
            return String(localized: "Worktree \(worktreeId)")
        }
        if let sessionWorktreeId, !sessionWorktreeId.isEmpty {
            return String(localized: "Main checkout")
        }
        return nil
    }

    /// The viewer's own swipe back is for content that has none: text, PDF,
    /// and 3D scenes handle the swipe themselves.
    static func shouldInstallHorizontalBackSwipe(
        allowsHorizontalBackSwipe: Bool,
        parentOwnsBackSwipe: Bool
    ) -> Bool {
        allowsHorizontalBackSwipe && parentOwnsBackSwipe
    }
}

enum FileBrowserMediaLoadPolicy {
    enum Existing: Equatable {
        case none
        case video(path: String)
        case audio(path: String)
    }

    static func shouldReload(
        existing: Existing,
        requestedPath: String,
        force: Bool
    ) -> Bool {
        if force { return true }
        switch existing {
        case .video(let path), .audio(let path):
            return path != requestedPath
        case .none:
            return true
        }
    }
}

/// Previous file stays in the leading bottom corner; next file stays trailing.
/// When Viewing Options / Reader is also present, it stacks above next.
/// A missing direction omits that button instead of recentering the other one.
enum AdjacentFileNavigatorLayout {
    enum Corner: Equatable {
        case leading
        case trailing
    }

    struct Slot: Equatable {
        var corner: Corner
        var systemImage: String
        var accessibilityLabel: String
    }

    static func slots(canGoPrevious: Bool, canGoNext: Bool) -> [Slot] {
        var slots: [Slot] = []
        if canGoPrevious {
            slots.append(Slot(
                corner: .leading,
                systemImage: "chevron.left",
                accessibilityLabel: "Previous file"
            ))
        }
        if canGoNext {
            slots.append(Slot(
                corner: .trailing,
                systemImage: "chevron.right",
                accessibilityLabel: "Next file"
            ))
        }
        return slots
    }

    static func leadingAccessoryCount(canGoPrevious: Bool, canGoNext: Bool) -> Int {
        canGoPrevious ? 1 : 0
    }

    static func trailingAccessoryCount(canGoPrevious: Bool, canGoNext: Bool) -> Int {
        canGoNext ? 1 : 0
    }
}

/// The Markdown viewport of each file a viewer showed, kept by the screen that
/// outlives the reader: a linked file rebuilt after a lock, or a file the
/// viewer comes back to through previous/next.
@MainActor
final class FileViewerViewportRestore {
    var state = FullScreenMarkdownViewportRestoreState()
}
