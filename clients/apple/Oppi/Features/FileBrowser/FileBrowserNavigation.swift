import UIKit

// Navigation values and policy for the workspace file browser
// (`FileBrowserViewController`). Routes carry `FileBrowserNavTarget`.

/// Workspace file browser or the connected server's home directory.
enum FileBrowserScope: Hashable, Sendable {
    case workspace(workspaceId: String, worktreeId: String?)
    case hostHome

    var breadcrumbRootLabel: String {
        switch self {
        case .workspace:
            return "Files"
        case .hostHome:
            return "Home"
        }
    }
}

enum FileBrowserDirectoryRequest: Equatable, Sendable {
    case workspace(workspaceId: String, path: String, worktreeId: String?)
    case hostHome(path: String)

    static func make(scope: FileBrowserScope, path: String) -> Self {
        switch scope {
        case .workspace(let workspaceId, let worktreeId):
            return .workspace(workspaceId: workspaceId, path: path, worktreeId: worktreeId)
        case .hostHome:
            return .hostHome(path: path)
        }
    }
}

enum FileBrowserHostHomePath {
    static func rawPath(relativePath: String) -> String {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty || trimmed == "~" { return "~" }
        if trimmed.hasPrefix("~/") { return trimmed }
        return "~/\(trimmed)"
    }
}

/// Value-based navigation target for the file browser.
///
/// Pushed as a workspace route so each directory level is a real stack
/// entry, preserving swipe-back between directories. The breadcrumb bar pops
/// the routes above an ancestor to jump to it without intermediate pop
/// animations.
struct FileBrowserNavTarget: Hashable {
    let serverId: String
    let scope: FileBrowserScope
    let path: String
    /// Column folder written while this destination is open. Identity stays
    /// `path`, so updating it does not remount the browser. A stack/split
    /// swap reads it back.
    var columnDirectoryPath: String?
    var columnSelectedFile: FileBrowserSelection?

    init(
        serverId: String,
        scope: FileBrowserScope,
        path: String,
        columnDirectoryPath: String? = nil,
        columnSelectedFile: FileBrowserSelection? = nil
    ) {
        self.serverId = serverId
        self.scope = scope
        self.path = path
        self.columnDirectoryPath = columnDirectoryPath
        self.columnSelectedFile = columnSelectedFile
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.serverId == rhs.serverId && lhs.scope == rhs.scope && lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(serverId)
        hasher.combine(scope)
        hasher.combine(path)
    }

    init(serverId: String, workspaceId: String, worktreeId: String? = nil, path: String) {
        self.init(
            serverId: serverId,
            scope: .workspace(workspaceId: workspaceId, worktreeId: worktreeId),
            path: path
        )
    }

    static func hostHome(serverId: String, path: String = "") -> Self {
        Self(serverId: serverId, scope: .hostHome, path: path)
    }

    var workspaceId: String? {
        if case .workspace(let workspaceId, _) = scope { return workspaceId }
        return nil
    }

    var worktreeId: String? {
        if case .workspace(_, let worktreeId) = scope { return worktreeId }
        return nil
    }

    /// Number of directory levels deep from the file browser root.
    /// Root ("" or "/") is depth 0, "src/" is 1, "src/components/" is 2, etc.
    var depth: Int {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed.isEmpty { return 0 }
        return trimmed.split(separator: "/").count
    }

    /// Path segments for breadcrumb display.
    /// Returns [(label, depth)] pairs where depth 0 = root.
    var breadcrumbSegments: [(label: String, depth: Int)] {
        var segments: [(String, Int)] = [(scope.breadcrumbRootLabel, 0)]
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/")
        for (i, part) in parts.enumerated() {
            segments.append((String(part), i + 1))
        }
        return segments
    }
}

struct FileBrowserSelection: Hashable, Identifiable, Sendable {
    let path: String
    let name: String
    let size: Int?

    var id: String { path }
}

struct FileBrowserNavigationContext: Hashable, Sendable {
    let files: [FileBrowserSelection]

    init(files: [FileBrowserSelection]) {
        var seen: Set<String> = []
        self.files = files.filter { file in
            let normalizedPath = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPath.isEmpty else { return false }
            return seen.insert(normalizedPath).inserted
        }
    }

    func selection(adjacentTo currentPath: String, direction: FileBrowserNavigationDirection) -> FileBrowserSelection? {
        guard let currentIndex = files.firstIndex(where: { $0.path == currentPath }) else { return nil }
        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = currentIndex - 1
        case .next:
            targetIndex = currentIndex + 1
        }
        guard files.indices.contains(targetIndex) else { return nil }
        return files[targetIndex]
    }
}

enum FileBrowserNavigationDirection: Equatable, Sendable {
    case previous
    case next
}

/// The edge a previous/next file slides from. SwiftUI's `Edge` for it is in
/// `WorkspaceHomeView.swift`, beside the file viewer factory.
enum FileBrowserPushTransitionEdge: Equatable, Sendable {
    case leading
    case trailing
}

struct FileBrowserPushTransitionSpec: Equatable, Sendable {
    let insertion: FileBrowserPushTransitionEdge
    let removal: FileBrowserPushTransitionEdge

    static func spec(for direction: FileBrowserNavigationDirection) -> Self {
        switch direction {
        case .previous:
            return .init(insertion: .leading, removal: .trailing)
        case .next:
            return .init(insertion: .trailing, removal: .leading)
        }
    }
}

struct FileBrowserTreeNavigationMutation: Equatable {
    let treeDirectoryPath: String
    let selectedFile: FileBrowserSelection?
}

enum FileBrowserColumnBackAction: Equatable {
    case clearSelectedFile
    case popToDirectory(String)
    case useStackBack
}

enum FileBrowserTreeNavigationReducer {
    static func openDirectory(path: String, selectedFile: FileBrowserSelection?) -> FileBrowserTreeNavigationMutation {
        FileBrowserTreeNavigationMutation(treeDirectoryPath: path, selectedFile: nil)
    }

    static func popToBreadcrumb(path: String, selectedFile: FileBrowserSelection?) -> FileBrowserTreeNavigationMutation {
        FileBrowserTreeNavigationMutation(treeDirectoryPath: path, selectedFile: nil)
    }

    /// Column drills stay in this destination after a fold. A compact drill
    /// that never set `treeDirectoryPath` still pushes the workspace stack.
    static func usesInPlaceDirectoryNavigation(
        showsColumn: Bool,
        treeDirectoryPathIsSet: Bool,
        usesInlineCompactNavigation: Bool
    ) -> Bool {
        showsColumn || treeDirectoryPathIsSet || usesInlineCompactNavigation
    }

    static func columnBackAction(
        selectedFile: FileBrowserSelection?,
        treeDirectoryPath: String?,
        initialPath: String,
        currentDirectoryPath: String
    ) -> FileBrowserColumnBackAction {
        if selectedFile != nil { return .clearSelectedFile }
        guard treeDirectoryPath != nil else { return .useStackBack }
        guard directoryDepth(currentDirectoryPath) > directoryDepth(initialPath) else {
            return .useStackBack
        }
        return .popToDirectory(parentDirectory(of: currentDirectoryPath))
    }

    static func directoryDepth(_ path: String) -> Int {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed.isEmpty { return 0 }
        return trimmed.split(separator: "/").count
    }

    static func parentDirectory(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/").dropLast()
        if parts.isEmpty { return "" }
        return parts.joined(separator: "/") + "/"
    }

    /// Workspace-linked file routes exist only on the workspace shell's stacks.
    /// The chat file panel pushes the reader through its own screen navigator.
    static func shouldUseWorkspaceLinkedFileDestination(
        usesInlineCompactNavigation: Bool,
        serverId: String?
    ) -> Bool {
        guard !usesInlineCompactNavigation, let serverId, !serverId.isEmpty else {
            return false
        }
        return true
    }
}

enum FileBrowserLayoutMode: Equatable {
    case adaptive
    /// Chat file panel: one compact list. Directories open inline because the
    /// panel's stack has no workspace destinations; files push the full reader.
    case compactOnly
}

enum FileBrowserColumnPolicy {
    /// The file tree is primary navigation, like Mail's list. Regular width
    /// shows it as a system column; compact keeps the push stack. Aspect
    /// ratio is not a third layout.
    static func showsColumn(
        layoutMode: FileBrowserLayoutMode,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) -> Bool {
        layoutMode == .adaptive && TrailingSidePanelPolicy.usesTrailingColumn(horizontalSizeClass: horizontalSizeClass)
    }
}
