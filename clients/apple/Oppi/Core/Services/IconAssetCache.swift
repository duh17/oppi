import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A server's icon artwork on this device: decoded images in memory, and the
/// bytes behind them on disk so an icon draws on the first frame after a
/// relaunch or a reconnect instead of the fallback symbol.
///
/// The disk tier is the same cache's, not a second one: `removeAll()` drops the
/// decoded memory a new API client invalidates and leaves the device's bytes,
/// and every read takes the same size and decode checks the network does.
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
    /// Where fetched bytes are kept between launches, nil for a cache that has
    /// no server to key them by (a preview, a test).
    private let disk: DiskStore?
    /// The assets this device holds bytes for, read once from its folder. Only
    /// these are read from disk, so an icon the device never stored never
    /// touches the file system on the draw path.
    private var storedAssets: Set<String>
    private var inFlight: [String: InFlight] = [:]
    /// One fetch per asset at a time, shared by every decode size and `data`.
    private var byteLoads: [String: Task<Data, Error>] = [:]
    /// Assets this cache could not load. Its fallback is what it draws for them
    /// until a new cache replaces it, so a failing icon never refetches in a loop.
    private var failed: Set<String> = []

    init(
        fetch: @escaping Fetch,
        decode: @escaping Decode = IconAssetCache.decodeRemoteIcon,
        disk: DiskStore? = nil
    ) {
        self.fetch = fetch
        self.decode = decode
        self.disk = disk
        storedAssets = disk?.assetIds() ?? []
        entries.countLimit = 128
        entries.totalCostLimit = 16 * 1024 * 1024
        rawData.totalCostLimit = 8 * 1024 * 1024
    }

    convenience init(apiClient: APIClient, serverId: String?) {
        self.init(
            fetch: { assetId in
                try await apiClient.fetchIconAsset(assetId: assetId)
            },
            disk: serverId.map { DiskStore(serverId: $0) }
        )
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
        let stored = storedData(assetId)
        let load = Task { @MainActor [weak self, stored] in
            let data: Data
            if let stored {
                data = stored
            } else {
                data = try await fetch(assetId)
                guard Self.isAcceptableAssetSize(data) else {
                    throw APIError.server(status: 422, message: "Icon asset data is invalid")
                }
                self?.keep(data, assetId: assetId)
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
    ///
    /// The first draw after a launch or a reconnect finds nothing decoded and
    /// asks the device: a stored asset decodes here, in the frame its caller is
    /// configuring, so the row never shows the fallback symbol first. One small
    /// file read and a bounded decode is what replaces a fallback raster; an
    /// asset the device did not store is not read at all.
    func cachedImage(assetId: String, size: CGFloat) -> UIImage? {
        let key = Self.cacheKey(assetId: assetId, size: size)
        if let cached = entries.object(forKey: key as NSString) {
            return cached.image
        }
        guard let data = storedData(assetId) else { return nil }
        guard let entry = try? makeEntry(data: data, size: size) else {
            // Bytes that will not decode are worth less than a fetch.
            discard(assetId)
            return nil
        }
        remember(entry, data: data, assetId: assetId, key: key)
        return entry.image
    }

    private static func cacheKey(assetId: String, size: CGFloat) -> String {
        "\(assetId):\(Int(size.rounded(.up)))"
    }

    func hasFailedLoad(assetId: String) -> Bool {
        failed.contains(assetId)
    }

    /// Drops what this cache decoded and fetched, for a new API client. The
    /// device's bytes stay: they are what the next draw reads before it waits.
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
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            // A hub that renders a session list asks every size it draws: the
            // device's bytes answer those before any fetch does.
            if let stored = storedData(assetId) {
                if let entry = try? makeEntry(data: stored, size: size) {
                    return entry
                }
                discard(assetId)
            }
            let data = try await self.data(assetId: assetId)
            try Task.checkCancellation()
            return try makeEntry(data: data, size: size)
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

    /// Remote Agent/workspace bytes are untrusted however they arrived. Decode
    /// through ImageIO's failable boundary; never pass fetched bytes to
    /// NSAdaptiveImageGlyph, whose initializer requires conforming input as a
    /// precondition.
    private func makeEntry(data: Data, size: CGFloat) throws -> Entry {
        let decoded = try decode(data, size)
        return Entry(
            retainedObject: decoded.retainedObject,
            image: decoded.image,
            cost: Self.decodedByteCost(for: decoded.image)
        )
    }

    private func remember(_ entry: Entry, data: Data, assetId: String, key: String) {
        entries.setObject(entry, forKey: key as NSString, cost: entry.cost)
        if !Self.isHEIF(data) {
            rawData.setObject(data as NSData, forKey: assetId as NSString, cost: data.count)
        }
    }

    // MARK: - The bytes this device keeps

    /// The device's bytes for `assetId`, or nil when it holds none or holds one
    /// that fails a read's checks, which is deleted so the next load refetches it.
    private func storedData(_ assetId: String) -> Data? {
        guard let disk, storedAssets.contains(assetId) else { return nil }
        guard let data = disk.read(assetId), Self.isAcceptableAssetSize(data) else {
            discard(assetId)
            return nil
        }
        return data
    }

    /// Forgets stored bytes this cache cannot use, so the next load fetches them.
    private func discard(_ assetId: String) {
        disk?.remove(assetId)
        storedAssets.remove(assetId)
    }

    /// Keeps a fetched asset on the device for the next launch. The write lists
    /// the folder to stay inside its bound, so it runs off the main thread and
    /// nothing waits for it: a launch that ends first costs one refetch.
    private func keep(_ data: Data, assetId: String) {
        guard let disk, DiskStore.isStorableAssetId(assetId) else { return }
        storedAssets.insert(assetId)
        Task.detached(priority: .utility) {
            disk.write(assetId: assetId, data: data)
        }
    }

    /// The bytes kept on this device: one file per asset, under one folder per
    /// server, in the app's Caches. An asset id is the asset's own hash and
    /// never changes, so a stored entry never goes stale; the folder per server
    /// keeps two servers' artwork apart; and the bound keeps the whole device's
    /// copy small, oldest first. The system may evict it like any cache.
    ///
    /// `nonisolated`: it is plain file I/O, so a write and its folder listing run
    /// off the main thread, while the draw path reads it synchronously.
    nonisolated struct DiskStore: Sendable {
        /// What one server's entries may add up to before the oldest go.
        static let maximumBytes = 8 * 1024 * 1024

        let root: URL
        private let byteLimit: Int

        init(root: URL, maximumBytes: Int = Self.maximumBytes) {
            self.root = root
            byteLimit = maximumBytes
        }

        /// The store for `serverId`, under `<caches>/IconAssets/<key>`: a keyed
        /// folder name, so a server id that carries punctuation never reaches the
        /// file system.
        init(
            serverId: String,
            caches: URL = AppLibrary.caches(),
            maximumBytes: Int = Self.maximumBytes
        ) {
            self.init(
                root: Self.folder(in: caches)
                    .appendingPathComponent(Self.folderKey(serverId), isDirectory: true),
                maximumBytes: maximumBytes
            )
        }

        /// Every server's stored artwork on this device, in bytes: what Storage &
        /// About adds to its cache size.
        static func storedBytes(caches: URL = AppLibrary.caches()) -> Int64 {
            guard let files = FileManager.default.enumerator(
                at: Self.folder(in: caches),
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in files {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
            return total
        }

        /// Deletes a removed server's artwork. Its icons are fetched again if it
        /// is ever paired again.
        static func removeBytes(for serverId: String, caches: URL = AppLibrary.caches()) {
            try? FileManager.default.removeItem(
                at: Self.folder(in: caches).appendingPathComponent(folderKey(serverId), isDirectory: true)
            )
        }

        /// Deletes every server's artwork, for Clear Local Cache.
        static func removeAllBytes(caches: URL = AppLibrary.caches()) {
            try? FileManager.default.removeItem(at: Self.folder(in: caches))
        }

        /// Where every server's folder lives.
        private static func folder(in caches: URL) -> URL {
            caches.appendingPathComponent("IconAssets", isDirectory: true)
        }

        /// Every asset this folder holds.
        func assetIds() -> Set<String> {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
            return Set(names.filter(Self.isStorableAssetId))
        }

        func read(_ assetId: String) -> Data? {
            guard Self.isStorableAssetId(assetId) else { return nil }
            return FileManager.default.contents(atPath: fileURL(assetId).path)
        }

        func write(assetId: String, data: Data) {
            guard Self.isStorableAssetId(assetId) else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: fileURL(assetId), options: .atomic)
            trim()
        }

        func remove(_ assetId: String) {
            guard Self.isStorableAssetId(assetId) else { return }
            try? FileManager.default.removeItem(at: fileURL(assetId))
        }

        /// Keeps the folder within its bound, least recently written first.
        private func trim() {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys)
            ) else { return }
            var files: [(url: URL, bytes: Int, writtenAt: Date)] = []
            var total = 0
            for url in entries {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                let bytes = values.fileSize ?? 0
                files.append((url, bytes, values.contentModificationDate ?? .distantPast))
                total += bytes
            }
            guard total > byteLimit else { return }
            for file in files.sorted(by: { $0.writtenAt < $1.writtenAt }) where total > byteLimit {
                guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
                total -= file.bytes
            }
        }

        private func fileURL(_ assetId: String) -> URL {
            root.appendingPathComponent(assetId)
        }

        /// An asset id this store may name a file after: the ids the protocol
        /// carries (ASCII letters, digits, `-`, `_`). An id a server made up
        /// another way stays in memory, so it can never name a path.
        static func isStorableAssetId(_ assetId: String) -> Bool {
            guard !assetId.isEmpty, assetId.utf8.count <= 128 else { return false }
            return assetId.utf8.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"),
                     UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "-"), UInt8(ascii: "_"):
                    return true
                default:
                    return false
                }
            }
        }

        /// A deterministic, filesystem-safe folder name for a server id.
        private static func folderKey(_ serverId: String) -> String {
            SHA256.hash(data: Data(serverId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
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
