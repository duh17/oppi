import Foundation

enum MessageQueueKind: String, Codable, Sendable {
    case steer
    case followUp = "follow_up"
}

struct MessageQueueItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var message: String
    var attachments: [ChatAttachmentRef]?
    /// Local-only optimistic thumbnails for queued image uploads.
    /// Not encoded on the wire; server queue state carries attachment refs only.
    var optimisticImages: [ImageAttachment]? = nil
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, message, attachments, createdAt
    }

    init(
        id: String,
        message: String,
        attachments: [ChatAttachmentRef]? = nil,
        optimisticImages: [ImageAttachment]? = nil,
        createdAt: Int
    ) {
        self.id = id
        self.message = message
        self.attachments = attachments
        self.optimisticImages = optimisticImages
        self.createdAt = createdAt
    }
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
    var attachments: [ChatAttachmentRef]?
    var createdAt: Int?

    init(
        id: String?,
        message: String,
        attachments: [ChatAttachmentRef]? = nil,
        createdAt: Int?
    ) {
        self.id = id
        self.message = message
        self.attachments = attachments
        self.createdAt = createdAt
    }
}
