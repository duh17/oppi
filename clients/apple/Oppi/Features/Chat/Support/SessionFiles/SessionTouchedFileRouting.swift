import Foundation

/// Chooses the host origin vs the session origin for a session-touched file.
///
/// Sandbox workspaces always use the session origin. Guest paths like
/// `/workspace/<slug>/…` are absolute POSIX strings, so treating them as
/// host paths would send a host-origin read and 404.
enum SessionTouchedFileLoadRoute: Equatable {
    case hostFile(path: String)
    case sessionRaw(path: String)

    var requestPath: String {
        switch self {
        case let .hostFile(path), let .sessionRaw(path):
            return path
        }
    }

    static func resolve(
        path: String,
        workspaceRuntime: WorkspaceRuntime?,
        hostMount: String?
    ) -> SessionTouchedFileLoadRoute {
        if workspaceRuntime == .sandbox {
            return .sessionRaw(path: path)
        }
        if MarkdownWikiLinkRewriter.resolvedHostPath(path) != nil {
            return .hostFile(path: path)
        }
        return .sessionRaw(path: path.workspaceRelativePath(hostMount: hostMount) ?? path)
    }

    static func navigationTitle(
        path: String,
        fileName: String,
        workspaceRuntime: WorkspaceRuntime?
    ) -> String {
        if workspaceRuntime == .sandbox {
            return fileName
        }
        if MarkdownWikiLinkRewriter.resolvedHostPath(path) != nil {
            return path
        }
        return fileName
    }
}

/// Session-origin markdown readers keep guest/worktree children on the session origin.
///
/// Sandbox and unknown runtime stay on the session origin even when wiki classification
/// labels an absolute guest path `hostFile`. Do not infer host ownership from a
/// leading `/` or missing workspace metadata. Confirmed host-workspace `/Users`
/// and `~/` links use the host origin.
enum SessionOriginLinkedFileRouting {
    static func routesThroughSessionRaw(
        kind: ResourceReferenceKind,
        workspaceRuntime: WorkspaceRuntime?,
        routesFileReferencesThroughSession: Bool
    ) -> Bool {
        guard routesFileReferencesThroughSession else { return false }
        if workspaceRuntime == .host {
            return kind != .hostFile
        }
        return true
    }
}
