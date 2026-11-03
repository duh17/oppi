import CoreImage
import Testing
import UIKit
@testable import Oppi

/// The chat timeline's media caches keep decoded bitmaps and image source
/// bytes for the whole process, so each one has to be bounded by what its
/// entries cost and has to give the memory back when a chat closes.
@Suite("Chat timeline media cache bounds")
@MainActor
struct ChatMediaCacheBoundsTests {
    /// A scale-1 bitmap of exactly `width * height * 4` bytes: an 8-bit
    /// sRGB context has one row of four-byte pixels per pixel column.
    private func makeRaster(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func mediaURL(_ name: String) throws -> URL {
        try #require(URL(string: "https://example.com/media/\(name)"))
    }

    private func imageOfSize(_ size: CGSize) -> UIImage {
        makeRaster(width: Int(size.width), height: Int(size.height))
    }

    /// How many of `urls` the image cache still holds, polled because `NSCache`
    /// evicts on its own schedule.
    private func cachedRasterCount(_ urls: [URL], timeout: Duration) async -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var survivors = urls.count
        while ContinuousClock.now < deadline {
            survivors = urls.count { MarkdownMediaCaches.cachedRaster(for: $0) != nil }
            if survivors < urls.count { return survivors }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return survivors
    }

    @Test func aDecodedImageCostsItsPixelBuffer() throws {
        let image = makeRaster(width: 1_200, height: 800)
        let raster = try #require(image.cgImage)

        #expect(raster.bytesPerRow == 1_200 * 4)
        #expect(
            MarkdownMediaCaches.decodedByteCost(of: image) == 1_200 * 800 * 4,
            "An inserted image must cost the bytes its decoded pixels hold"
        )
    }

    @Test func anImageWithoutACoreGraphicsImageCostsItsPixelsToo() {
        let image = UIImage(ciImage: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))

        #expect(image.cgImage == nil)
        #expect(
            MarkdownMediaCaches.decodedByteCost(of: image) == 200 * 100 * 4,
            "A backing store Core Graphics cannot describe still occupies pixels"
        )
    }

    @Test func theImageCacheEvictsPastItsCostLimit() async throws {
        _ = MarkdownMediaCaches.trim()
        defer { _ = MarkdownMediaCaches.trim() }

        let limit = MarkdownMediaCaches.imageTotalCostLimit
        let size = CGSize(width: 2_000, height: 1_000)
        let cost = MarkdownMediaCaches.decodedByteCost(of: makeRaster(width: 2_000, height: 1_000))
        let urls = try (0..<10).map { try mediaURL("over-limit-\($0).png") }
        #expect(cost * urls.count > limit, "The fixture must cross the limit to prove eviction")
        #expect(urls.count <= MarkdownMediaCaches.imageCountLimit, "Only cost can evict these")

        for url in urls {
            MarkdownMediaCaches.cacheRaster(imageOfSize(size), for: url)
        }

        // `NSCache` evicts on its own schedule and picks its own victims, so the
        // proof is that the limit drops entries at all: a cache whose inserts
        // carried no cost keeps every one of them.
        let survivors = await cachedRasterCount(urls, timeout: .seconds(10))
        #expect(
            survivors < urls.count,
            "The image cache kept all \(urls.count) images of \(cost) bytes each, over its \(limit)-byte limit"
        )
    }

    @Test func theImageDataSourceCacheEvictsPastItsCostLimit() async throws {
        _ = MarkdownMediaCaches.trim()
        defer { _ = MarkdownMediaCaches.trim() }

        let limit = MarkdownMediaCaches.dataTotalCostLimit
        let bytes = 4 * 1024 * 1024
        let data = Data(count: bytes)
        let urls = try (0..<6).map { try mediaURL("over-limit-\($0).svg") }
        #expect(bytes * urls.count > limit)

        for url in urls {
            MarkdownMediaCaches.cacheImageData(data, kind: .svg, for: url)
        }

        let withinLimit = await waitForMainActorCondition(timeout: .seconds(5)) {
            urls.count { MarkdownMediaCaches.cachedImageData(.svg, for: $0) != nil } * bytes <= limit
        }
        #expect(withinLimit, "The image source cache kept more bytes than its total cost limit")
    }

    /// A chat close reports what it dropped, so the shipped `Cache` log line
    /// can show the memory that leaving a chat gave back.
    @Test func aTrimReportsAndDropsWhatTheCachesWereGiven() throws {
        _ = MarkdownMediaCaches.trim()
        defer { _ = MarkdownMediaCaches.trim() }

        let image = makeRaster(width: 400, height: 300)
        let imageURL = try mediaURL("reported.png")
        let svgURL = try mediaURL("reported.svg")
        MarkdownMediaCaches.cacheRaster(image, for: imageURL)
        MarkdownMediaCaches.cacheImageData(Data(count: 4_096), kind: .svg, for: svgURL)

        let trimmed = MarkdownMediaCaches.trim()

        #expect(trimmed.images == CacheFootprint(entries: 1, bytes: 400 * 300 * 4))
        #expect(trimmed.data == CacheFootprint(entries: 1, bytes: 4_096))
        #expect(MarkdownMediaCaches.cachedRaster(for: imageURL) == nil)
        #expect(MarkdownMediaCaches.cachedImageData(.svg, for: svgURL) == nil)
        #expect(MarkdownMediaCaches.trim().images.isEmpty, "A second trim has nothing left to drop")
    }

    /// Showing one image again is a cache hit, not new memory, so the report a
    /// chat close logs must not grow with every re-render.
    @Test func showingTheSameMediaAgainDoesNotGrowTheReportedBytes() throws {
        _ = MarkdownMediaCaches.trim()
        defer { _ = MarkdownMediaCaches.trim() }

        let image = makeRaster(width: 400, height: 300)
        let imageURL = try mediaURL("reinserted.png")
        let svgURL = try mediaURL("reinserted.svg")
        for _ in 0..<3 {
            MarkdownMediaCaches.cacheRaster(image, for: imageURL)
            MarkdownMediaCaches.cacheImageData(Data(count: 4_096), kind: .svg, for: svgURL)
        }

        let trimmed = MarkdownMediaCaches.trim()

        #expect(
            trimmed.images == CacheFootprint(entries: 1, bytes: 400 * 300 * 4),
            "Re-inserting one image must report one image's bytes, not three"
        )
        #expect(
            trimmed.data == CacheFootprint(entries: 1, bytes: 4_096),
            "Re-inserting one source must report one source's bytes, not three"
        )
    }

    @Test func stillFrameTrimReportsTheFramesItDrops() async throws {
        let store = InlineVideoStillFrameStore(generator: { _, _ in
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32)).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            }
        })
        let size = CGSize(width: 64, height: 32)
        let source = AuthenticatedMediaSource(
            url: try mediaURL("clips/trim.mp4"),
            authorizationHeaderValue: "Bearer token",
            tlsCertFingerprint: nil,
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )

        let frame = try #require(await store.image(for: source, maxPixelSize: size))
        #expect(store.cachedImage(for: source, maxPixelSize: size) === frame)

        let trimmed = store.removeAll()

        #expect(trimmed.entries == 1)
        #expect(trimmed.bytes > 0)
        #expect(store.cachedImage(for: source, maxPixelSize: size) == nil)
    }
}
