import UIKit

/// The screen for a file on a server's host that a page links to by absolute path (a plugin
/// page's file row). The server names who edits the file (`resolveFileForEditing`): a Skill's
/// own file opens in the Skill file viewer, with its editor, review comments and Edit with
/// Session; any other host file opens in the shared file viewer, read-only or with the host
/// editor as the server allows.
@MainActor
enum HostFileScreen {
    static func make(path: String, connection: ServerConnection, root: AppRootEnvironment) async -> UIViewController? {
        guard let serverId = connection.currentServerId else { return nil }
        if let api = connection.apiClient,
           case .editable(let identity, _, _) = await api.resolveFileForEditing(
               FileEditLocation(serverId: serverId, origin: .host(controlSessionId: nil), path: path)
           ),
           case .skill(let skillId) = identity.owner {
            return ServerSkillFileViewController(
                target: ServerSkillFileNavTarget(serverId: serverId, resourceId: skillId, path: identity.path),
                root: root,
                connection: connection
            )
        }
        return WorkspaceLinkedFileViewController(
            target: .hostFile(serverId: serverId, workspaceId: "", path: path),
            placement: .pushed,
            root: root
        )
    }
}
