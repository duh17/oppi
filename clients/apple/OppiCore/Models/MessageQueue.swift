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

    /// Server queue snapshots omit local-only optimistic thumbnails, and a
    /// `get_queue` refresh can also drop attachment refs. Keep both when the
    /// same queued item id is still present.
    func preservingLocalMedia(from previous: MessageQueueState?) -> MessageQueueState {
        guard let previous else { return self }
        let previousByID = Dictionary(
            (previous.steering + previous.followUp).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func merge(_ item: MessageQueueItem) -> MessageQueueItem {
            guard let prior = previousByID[item.id] else { return item }
            var next = item
            if Self.isMissingOrEmpty(next.attachments),
               let attachments = prior.attachments,
               !attachments.isEmpty {
                next.attachments = attachments
            }
            if Self.isMissingOrEmpty(next.optimisticImages),
               let images = prior.optimisticImages,
               !images.isEmpty {
                next.optimisticImages = images
            }
            return next
        }

        return MessageQueueState(
            version: version,
            steering: steering.map(merge),
            followUp: followUp.map(merge)
        )
    }

    private static func isMissingOrEmpty<T>(_ values: [T]?) -> Bool {
        values == nil || values?.isEmpty == true
    }
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

enum MessageQueueVisibleAttachment: Equatable, Identifiable, Sendable {
    case photo(id: String, name: String, image: ImageAttachment?)
    case file(id: String, name: String)

    var id: String {
        switch self {
        case .photo(let id, _, _), .file(let id, _):
            return id
        }
    }

    var name: String {
        switch self {
        case .photo(_, let name, _), .file(_, let name):
            return name
        }
    }
}

enum MessageQueueAttachmentPresentation {
    static func visibleAttachments(for item: MessageQueueItem) -> [MessageQueueVisibleAttachment] {
        let attachments = item.attachments ?? []
        let optimisticImages = item.optimisticImages ?? []
        var usedImageIndex = 0
        var result: [MessageQueueVisibleAttachment] = []

        for attachment in attachments {
            if attachment.mimeType.hasPrefix("image/") {
                let image: ImageAttachment?
                if usedImageIndex < optimisticImages.count {
                    image = optimisticImages[usedImageIndex]
                    usedImageIndex += 1
                } else {
                    image = nil
                }
                result.append(
                    .photo(
                        id: attachment.id,
                        name: attachment.name,
                        image: image
                    )
                )
            } else {
                result.append(.file(id: attachment.id, name: attachment.name))
            }
        }

        while usedImageIndex < optimisticImages.count {
            result.append(
                .photo(
                    id: "optimistic-\(item.id)-\(usedImageIndex)",
                    name: "Photo",
                    image: optimisticImages[usedImageIndex]
                )
            )
            usedImageIndex += 1
        }

        return result
    }

    static func mediaCounts(in queue: MessageQueueState) -> (photos: Int, files: Int) {
        var photos = 0
        var files = 0
        for item in queue.steering + queue.followUp {
            for attachment in visibleAttachments(for: item) {
                switch attachment {
                case .photo:
                    photos += 1
                case .file:
                    files += 1
                }
            }
        }
        return (photos, files)
    }

    static func countSubtitle(steeringCount: Int, followUpCount: Int) -> String {
        "\(steeringCount) steering • \(followUpCount) follow-up"
    }

    static func mediaHint(photoCount: Int, fileCount: Int) -> String? {
        var parts: [String] = []
        if photoCount == 1 {
            parts.append("1 photo")
        } else if photoCount > 1 {
            parts.append("\(photoCount) photos")
        }
        if fileCount == 1 {
            parts.append("1 file")
        } else if fileCount > 1 {
            parts.append("\(fileCount) files")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    static func widgetSubtitle(
        steeringCount: Int,
        followUpCount: Int,
        photoCount: Int,
        fileCount: Int
    ) -> String {
        let counts = countSubtitle(steeringCount: steeringCount, followUpCount: followUpCount)
        guard let media = mediaHint(photoCount: photoCount, fileCount: fileCount) else {
            return counts
        }
        return "\(counts) • \(media)"
    }
}
