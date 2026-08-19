import Foundation

/// Chooses host-browse vs session-raw for a session-touched file.
///
/// Sandbox workspaces always use session-raw. Guest paths like
/// `/workspace/<slug>/…` are absolute POSIX strings, so treating them as
/// host paths would send `GET /files/raw` and 404.
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
