import Foundation

struct IconAssetRecord: Codable, Sendable, Equatable {
    let assetId: String
    let sha256: String
    let sizeBytes: Int
    let contentType: String
    let createdAt: Double
}

struct IconAssetUploadResponse: Decodable, Sendable, Equatable {
    let asset: IconAssetRecord
}
