import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
final class IconAssetCache {
    typealias Fetch = @Sendable (String) async throws -> Data
    typealias Decode = @MainActor (Data, CGFloat) throws -> (image: UIImage, retainedObject: AnyObject?)

    /// The value never leaves `IconAssetCache`'s main-actor isolation. The
    /// unchecked marker only permits it to be the result of the owned Task.
    private final class Entry: NSObject, @unchecked Sendable {
        let retainedObject: AnyObject?
        let image: UIImage
        let cost: Int

        init(retainedObject: AnyObject?, image: UIImage, cost: Int) {
            self.retainedObject = retainedObject
            self.image = image
            self.cost = cost
        }
    }

    private struct InFlight {
        let requestID: UUID
        let task: Task<Entry, Error>
        var waiters: [UUID: CheckedContinuation<UIImage, Error>]
    }

    private let entries = NSCache<NSString, Entry>()
    /// An imported image's fetched bytes, kept so an animated image can play
    /// without a second fetch. A Genmoji's bytes are never kept: they only draw.
    private let rawData = NSCache<NSString, NSData>()
    private let fetch: Fetch
    private let decode: Decode
    private var inFlight: [String: InFlight] = [:]
    /// One fetch per asset at a time, shared by every decode size and `data`.
    private var byteLoads: [String: Task<Data, Error>] = [:]
    /// Assets this cache could not load. Its fallback is what it draws for them
    /// until a new cache replaces it, so a failing icon never refetches in a loop.
    private var failed: Set<String> = []

    init(
        fetch: @escaping Fetch,
        decode: @escaping Decode = IconAssetCache.decodeRemoteIcon
    ) {
        self.fetch = fetch
        self.decode = decode
        entries.countLimit = 128
        entries.totalCostLimit = 16 * 1024 * 1024
        rawData.totalCostLimit = 8 * 1024 * 1024
    }

    convenience init(apiClient: APIClient) {
        self.init { assetId in
            try await apiClient.fetchIconAsset(assetId: assetId)
        }
    }

    func image(assetId: String, size: CGFloat) async throws -> UIImage {
        let key = Self.cacheKey(assetId: assetId, size: size)
        if let cached = entries.object(forKey: key as NSString) {
            return cached.image
        }
        try Task.checkCancellation()

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                registerWaiter(
                    continuation,
                    waiterID: waiterID,
                    key: key,
                    assetId: assetId,
                    size: size
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID, key: key)
            }
        }
    }

    /// An image asset's bytes as the server stores them, for a view that plays
    /// an animated image and for every draw: the kept copy of an image's, or one
    /// fetch however many callers ask at the same time, so a second draw size
    /// fetches nothing. A failure throws and is not kept.
    func data(assetId: String) async throws -> Data {
        if let cached = rawData.object(forKey: assetId as NSString) {
            return cached as Data
        }
        if let load = byteLoads[assetId] {
            return try await load.value
        }
        let fetch = self.fetch
        let rawData = self.rawData
        let load = Task { @MainActor in
            let data = try await fetch(assetId)
            guard Self.isAcceptableAssetSize(data) else {
                throw APIError.server(status: 422, message: "Icon asset data is invalid")
            }
            if !Self.isHEIF(data) {
                rawData.setObject(data as NSData, forKey: assetId as NSString, cost: data.count)
            }
            return data
        }
        byteLoads[assetId] = load
        defer { if byteLoads[assetId] == load { byteLoads[assetId] = nil } }
        return try await load.value
    }

    private static func isHEIF(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else { return false }
        return type.conforms(to: .heif) || type.conforms(to: .heic)
    }

    private static func isAcceptableAssetSize(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= 2 * 1024 * 1024
    }

    /// The artwork if it is already decoded at `size`, for a caller that draws
    /// once and cannot await: a menu's action image, a list row's icon.
    func cachedImage(assetId: String, size: CGFloat) -> UIImage? {
        entries.object(forKey: Self.cacheKey(assetId: assetId, size: size) as NSString)?.image
    }

    private static func cacheKey(assetId: String, size: CGFloat) -> String {
        "\(assetId):\(Int(size.rounded(.up)))"
    }

    func hasFailedLoad(assetId: String) -> Bool {
        failed.contains(assetId)
    }

    func removeAll() {
        entries.removeAllObjects()
        rawData.removeAllObjects()
        failed.removeAll()
        byteLoads.values.forEach { $0.cancel() }
        byteLoads.removeAll()
        let pending = inFlight.values
        inFlight.removeAll()
        for request in pending {
            request.task.cancel()
            request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<UIImage, Error>,
        waiterID: UUID,
        key: String,
        assetId: String,
        size: CGFloat
    ) {
        if var request = inFlight[key] {
            request.waiters[waiterID] = continuation
            inFlight[key] = request
            return
        }

        let requestID = UUID()
        let decode = self.decode
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let data = try await self.data(assetId: assetId)
            try Task.checkCancellation()

            // Remote Agent/workspace bytes are untrusted even after the
            // authenticated fetch. Decode through ImageIO's failable boundary;
            // never pass fetched bytes to NSAdaptiveImageGlyph, whose initializer
            // requires conforming input as a precondition.
            let decoded = try decode(data, size)
            try Task.checkCancellation()
            return Entry(
                retainedObject: decoded.retainedObject,
                image: decoded.image,
                cost: Self.decodedByteCost(for: decoded.image)
            )
        }
        inFlight[key] = InFlight(
            requestID: requestID,
            task: task,
            waiters: [waiterID: continuation]
        )

        Task { @MainActor [weak self] in
            do {
                let entry = try await task.value
                self?.finish(key: key, assetId: assetId, requestID: requestID, result: .success(entry))
            } catch {
                self?.finish(key: key, assetId: assetId, requestID: requestID, result: .failure(error))
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, key: String) {
        guard var request = inFlight[key],
              let continuation = request.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            request.task.cancel()
        } else {
            inFlight[key] = request
        }
    }

    private func finish(key: String, assetId: String, requestID: UUID, result: Result<Entry, Error>) {
        guard let request = inFlight[key], request.requestID == requestID else { return }
        inFlight.removeValue(forKey: key)

        switch result {
        case .success(let entry):
            entries.setObject(entry, forKey: key as NSString, cost: entry.cost)
            request.waiters.values.forEach { $0.resume(returning: entry.image) }
        case .failure(let error):
            // A cancel (a reconnect clears the cache) says nothing about the
            // asset; anything else means this cache cannot draw it.
            if !(error is CancellationError) {
                failed.insert(assetId)
            }
            request.waiters.values.forEach { $0.resume(throwing: error) }
        }
    }

    static func decodedByteCost(bytesPerRow: Int, height: Int) -> Int {
        guard bytesPerRow > 0, height > 0 else { return 0 }
        let (cost, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return overflow ? .max : cost
    }

    private static func decodedByteCost(for image: UIImage) -> Int {
        guard let raster = image.cgImage else {
            // An unknown backing store must not be treated as free cache memory.
            return .max
        }
        return decodedByteCost(bytesPerRow: raster.bytesPerRow, height: raster.height)
    }

    /// The formats an icon asset may be: a Genmoji's HEIF, or an imported
    /// PNG (APNG), GIF, or WebP.
    static let assetTypes: [UTType] = [.heic, .heif, .png, .gif, .webP]

    // Internal for focused malformed-input tests. This validates only a bounded,
    // decodable image in one of `assetTypes` and draws its first frame. Apple
    // adaptive-image semantics are supplied by the official iOS/iPadOS picker as
    // NSAdaptiveImageGlyph.imageContent and are not authenticated by either this
    // decoder or the server parser.
    /// The most frames an icon may hold: a HEIF's few representations, or an
    /// animated image's frames, bounded like the server's 600.
    static let maxFrameCount = 600

    static func decodeRemoteIcon(
        data: Data,
        size: CGFloat
    ) throws -> (image: UIImage, retainedObject: AnyObject?) {
        guard size.isFinite, size > 0, size <= 512 else {
            throw APIError.server(status: 422, message: "Icon render size is invalid")
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let sourceIdentifier = CGImageSourceGetType(source),
              let sourceType = UTType(sourceIdentifier as String),
              assetTypes.contains(where: { sourceType.conforms(to: $0) }) else {
            throw APIError.server(status: 422, message: "Icon asset is not a decodable icon image")
        }

        let representationCount = CGImageSourceGetCount(source)
        guard (1...maxFrameCount).contains(representationCount),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...4_096).contains(width),
              (1...4_096).contains(height),
              width * height <= 8_388_608 else {
            throw APIError.server(status: 422, message: "Icon asset dimensions are invalid")
        }

        let maximumPixelSize = min(512, max(1, Int(size.rounded(.up))))
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              image.width > 0,
              image.height > 0,
              hasVisiblePixel(image) else {
            throw APIError.server(status: 422, message: "Icon asset has no visible image output")
        }

        return (UIImage(cgImage: image), nil)
    }

    private static func hasVisiblePixel(_ image: CGImage) -> Bool {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 4 }
    }
}
