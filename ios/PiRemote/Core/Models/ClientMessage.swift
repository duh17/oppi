import Foundation

/// Messages sent from the iOS client to the server over WebSocket.
///
/// Manual Encodable to match server's `ClientMessage` union type with `type` discriminator.
enum ClientMessage: Sendable {
    case prompt(message: String, images: [ImageAttachment]? = nil, streamingBehavior: StreamingBehavior? = nil)
    case steer(message: String)
    case followUp(message: String)
    case stop
    case getState
    case permissionResponse(id: String, action: PermissionAction)
    case extensionUIResponse(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil)
}

struct ImageAttachment: Codable, Sendable {
    let data: String      // base64
    let mimeType: String  // image/jpeg, image/png, etc.
}

enum StreamingBehavior: String, Codable, Sendable {
    case steer
    case followUp
}

// MARK: - Manual Encodable

extension ClientMessage: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .prompt(let message, let images, let behavior):
            try c.encode("prompt", forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encodeIfPresent(behavior, forKey: .streamingBehavior)

        case .steer(let message):
            try c.encode("steer", forKey: .type)
            try c.encode(message, forKey: .message)

        case .followUp(let message):
            try c.encode("follow_up", forKey: .type)
            try c.encode(message, forKey: .message)

        case .stop:
            try c.encode("stop", forKey: .type)

        case .getState:
            try c.encode("get_state", forKey: .type)

        case .permissionResponse(let id, let action):
            try c.encode("permission_response", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(action, forKey: .action)

        case .extensionUIResponse(let id, let value, let confirmed, let cancelled):
            try c.encode("extension_ui_response", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(confirmed, forKey: .confirmed)
            try c.encodeIfPresent(cancelled, forKey: .cancelled)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, message, images, streamingBehavior
        case id, action, value, confirmed, cancelled
    }
}

extension ClientMessage {
    /// Encode to JSON data for WebSocket send.
    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Encode to JSON string for WebSocket send.
    func jsonString() throws -> String {
        let data = try jsonData()
        return String(data: data, encoding: .utf8)!
    }
}
