import Foundation

extension Notification.Name {
    /// Owner → source-chat pre-navigation signal: a linked file is about to
    /// replace the visible route, so the chat freezes its scroll anchor first.
    /// This is not an entry point; every open is an `AppOpenRequest`.
    static let workspaceLinkedFileWillOpen = Notification.Name("\(AppIdentifiers.subsystem).workspaceLinkedFileWillOpen")
    static let workspaceLinkedFileSourceServerIDKey = "sourceServerID"
    static let pairingApprovalsDidChange = Notification.Name("\(AppIdentifiers.subsystem).pairingApprovalsDidChange")
}
