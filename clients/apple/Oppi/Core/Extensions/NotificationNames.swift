import Foundation

extension Notification.Name {
    static let assistantAvatarDidChange = Notification.Name("\(AppIdentifiers.subsystem).assistantAvatarDidChange")
    static let inviteDeepLinkTapped = Notification.Name("\(AppIdentifiers.subsystem).inviteDeepLinkTapped")
    static let webLinkTapped = Notification.Name("\(AppIdentifiers.subsystem).webLinkTapped")
    static let resourceReferenceTapped = Notification.Name("\(AppIdentifiers.subsystem).resourceReferenceTapped")
    static let fileLinkTapped = Notification.Name("\(AppIdentifiers.subsystem).fileLinkTapped")
}
