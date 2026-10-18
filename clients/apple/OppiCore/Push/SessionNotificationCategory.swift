/// Category identifiers of Oppi's session notifications, shared by the app's local banners,
/// tap routing, and the Notification Service Extension's decrypted pushes.
enum SessionNotificationCategory {
    static let ask = "ASK_REQUEST"
    static let sessionBlocked = "SESSION_BLOCKED"
    static let sessionFailed = "SESSION_FAILED"
    static let agentMessage = "AGENT_MESSAGE"
    static let pairingApproval = "PAIRING_APPROVAL"
    static let deviceEnrolled = "DEVICE_ENROLLED"
}
