import Foundation

extension Notification.Name {
    static let inviteDeepLinkTapped = Notification.Name("\(AppIdentifiers.subsystem).inviteDeepLinkTapped")
    static let webLinkTapped = Notification.Name("\(AppIdentifiers.subsystem).webLinkTapped")
    static let fileLinkTapped = Notification.Name("\(AppIdentifiers.subsystem).fileLinkTapped")
}
