import Foundation

enum MessageQueueKind: String, Codable, Sendable {
    case steer
    case followUp = "follow_up"
}

struct MessageQueueItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var message: String
    var images: [ImageAttachment]?
    var createdAt: Int
}

struct MessageQueueState: Codable, Sendable, Equatable {
    var version: Int
    var steering: [MessageQueueItem]
    var followUp: [MessageQueueItem]

    static let empty = Self(version: 0, steering: [], followUp: [])
}

struct MessageQueueDraftItem: Codable, Sendable, Equatable, Identifiable {
    var id: String?
    var message: String
    var images: [ImageAttachment]?
    var createdAt: Int?
}
