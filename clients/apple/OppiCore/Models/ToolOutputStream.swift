import Foundation

/// Offsets refer to the producer's raw byte log, not the UTF-8 size of `output`.
struct ToolOutputStreamChunk: Codable, Sendable, Equatable {
    let epoch: Int
    let offset: Int
    let bytes: Int
}

struct ToolOutputStreamEnd: Codable, Sendable, Equatable {
    let epoch: Int
    let totalBytes: Int
}
