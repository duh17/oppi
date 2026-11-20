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
    /// A file the session reported touching that Git cannot diff (the Git
    /// panel's This session): each path reads from the host or the session's copy, as
    /// `SessionTouchedFileLoadRoute` decides, and so do its resources.
    case sessionTouched(SessionTouchedFileOrigin)

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
    /// A pushed viewer's reader draws its own bar and Back; a tree pane's or a
    /// host file's reader is content only, under the screen's bar.
    static func readerDrawsChrome(
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
        switch source {
        case .hostFile:
            path
        case .sessionTouched(let origin):
            SessionTouchedFileLoadRoute.navigationTitle(
                path: path,
                fileName: fileName,
                workspaceRuntime: origin.workspaceRuntime
            )
        case .workspaceFile, .sessionFile:
            fileName
        }
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
}

/// Shared previous/next file transition. Directional travel and the 220 ms
/// ease-in-out are one policy for every UIKit viewer's slide. Reduce Motion
/// drops the travel.
enum FileBrowserPushTransitionPolicy {
    static let duration: Double = 0.22

    static func directionalSpec(
        for direction: FileBrowserNavigationDirection,
        reduceMotion: Bool
    ) -> FileBrowserPushTransitionSpec? {
        reduceMotion ? nil : FileBrowserPushTransitionSpec.spec(for: direction)
    }
}
