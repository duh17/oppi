import Foundation
import os
import Testing
import UIKit
@testable import Oppi

/// The bytes `IconAssetCache` keeps on this device: what a relaunch, a reconnect,
/// or a switch between a LAN and a tailnet endpoint draws from without waiting for
/// a fetch, and what a removed server takes with it.
///
/// Most tests here draw through `IconChoiceUIView`, a row's first configure, so the
/// artwork they expect is the artwork a person sees in the first frame.
@MainActor
@Suite("Icon assets kept on the device")
struct IconAssetDiskCacheTests {
    private static let studio = "sha256:studio"
    private static let laptop = "sha256:laptop"

    // MARK: - Fixtures

    /// A real PNG, so the production decoder is what accepts it.
    private func artworkPNG(_ colour: UIColor = .systemPink, side: CGFloat = 64) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.pngData() ?? Data()
    }

    private func temporaryCaches() throws -> URL {
        let caches = FileManager.default.temporaryDirectory
            .appending(path: "oppi-icon-disk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches
    }

    private func store(
        _ serverId: String = studio,
        in caches: URL,
        maximumBytes: Int = IconAssetCache.DiskStore.maximumBytes
    ) -> IconAssetCache.DiskStore {
        IconAssetCache.DiskStore(serverId: serverId, caches: caches, maximumBytes: maximumBytes)
    }

    private func cache(
        _ client: APIClient,
        _ disk: IconAssetCache.DiskStore?
    ) -> IconAssetCache {
        IconAssetCache(fetch: { try await client.fetchIconAsset(assetId: $0) }, disk: disk)
    }

    private var assetId: String { "ia_" + String(repeating: "A", count: 43) }

    /// Plans the icon route for this test, counting the requests that reach it.
    private func iconRoute(
        _ bytes: Data,
        requests: IconAssetRequests
    ) -> TestURLProtocol.RouteScope {
        TestURLProtocol.routeScope { request in
            let url = try #require(request.url)
            requests.record(url.path)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            ))
            return (bytes, response)
        }
    }

    /// Waits for the off-main write rather than guessing at it.
    private func waitUntilStored(
        _ assetId: String,
        in disk: IconAssetCache.DiskStore
    ) async throws {
        for _ in 0..<200 {
            if disk.read(assetId) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the fetched bytes never reached the device")
    }

    // MARK: - Relaunch

    @Test func aFetchedIconDrawsOnTheNextLaunchesFirstDrawWithoutAFetch() async throws {
        let caches = try temporaryCaches()
        defer { try? FileManager.default.removeItem(at: caches) }
        let requests = IconAssetRequests()
        let scope = iconRoute(artworkPNG(), requests: requests)
        defer { scope.end() }
        let client = makeTestURLProtocolClient()

        let first = cache(client, store(in: caches))
        let fetched = try await first.image(assetId: assetId, size: 32)
        #expect(fetched.size.width > 0)
        try await waitUntilStored(assetId, in: store(in: caches))
        #expect(requests.count == 1)

        // The next launch: new memory, this device's bytes, nothing asked of the server.
        let relaunched = cache(client, store(in: caches))
        let drawn = try #require(relaunched.cachedImage(assetId: assetId, size: 32))
        #expect(drawn.size.width > 0)
        #expect(requests.count == 1, "the device's copy answered the first draw")
    }

    /// The owner's report: a row showed the fallback person symbol until the fetch
    /// finished. After a relaunch the row's first configure has nowhere to wait, so
    /// the icon has to come from the device.
    @Test func aRowsFirstConfigureShowsTheStoredArtworkNotTheFallbackSymbol() async throws {
        let caches = try temporaryCaches()
        defer { try? FileManager.default.removeItem(at: caches) }
        store(in: caches).write(assetId: assetId, data: artworkPNG(.systemPink))
        // No route is planned: a request would fail the run rather than pass this.
        let scope = TestURLProtocol.routeScope { _ in
            throw TestURLProtocol.UnplannedRoute(route: "icon asset")
        }
        defer { scope.end() }
        let client = makeTestURLProtocolClient()
        // A size no other test draws, because `EntityIcon` keeps one process-wide
        // raster cache keyed by the cache's identity, the size, and the theme.
        let icon = IconChoiceUIView(frameSize: 41)

        icon.apply(
            .choice(.image(assetId: assetId), purpose: .agent, sandbox: false),
            assetCache: cache(client, store(in: caches))
        )

        #expect(try shows(icon, mostly: .systemPink), "the row drew the artwork, not the person symbol")
    }

    // MARK: - Damage and separation

    @Test func aStoredFileThatWillNotDecodeIsDeletedAndFetchedAgain() async throws {
        let caches = try temporaryCaches()
        defer { try? FileManager.default.removeItem(at: caches) }
        let disk = store(in: caches)
        disk.write(assetId: assetId, data: Data([0, 1, 2, 3]))
        let requests = IconAssetRequests()
        let scope = iconRoute(artworkPNG(), requests: requests)
        defer { scope.end() }
        let client = makeTestURLProtocolClient()
        let launched = cache(client, store(in: caches))

        #expect(launched.cachedImage(assetId: assetId, size: 32) == nil, "bytes that will not decode draw nothing")
        #expect(disk.read(assetId) == nil, "and they are gone, so the server is asked again")

        let refetched = try await launched.image(assetId: assetId, size: 32)
        #expect(refetched.size.width > 0)
        #expect(requests.count == 1)
        try await waitUntilStored(assetId, in: disk)
    }

    @Test func oneServersIconsAreNotAnotherServers() async throws {
        let caches = try temporaryCaches()
        defer { try? FileManager.default.removeItem(at: caches) }
        let requests = IconAssetRequests()
        let scope = iconRoute(artworkPNG(), requests: requests)
        defer { scope.end() }
        let client = makeTestURLProtocolClient()

        let studio = cache(client, store(Self.studio, in: caches))
        _ = try await studio.image(assetId: assetId, size: 32)
        try await waitUntilStored(assetId, in: store(Self.studio, in: caches))
        #expect(requests.count == 1)

        // Another server's cache holds nothing for the same id and asks its own server.
        let laptop = cache(client, store(Self.laptop, in: caches))
        #expect(laptop.cachedImage(assetId: assetId, size: 32) == nil)
        _ = try await laptop.image(assetId: assetId, size: 32)
        #expect(requests.count == 2)
    }

    @Test func removingAServerDeletesItsIconsAndKeepsAnotherServers() async throws {
        let caches = try temporaryCaches()
        defer { try? FileManager.default.removeItem(at: caches) }
        store(Self.studio, in: caches).write(assetId: assetId, data: artworkPNG())
        store(Self.laptop, in: caches).write(assetId: assetId, data: artworkPNG())

        IconAssetCache.DiskStore.removeBytes(for: Self.studio, caches: caches)

        #expect(store(Self.studio, in: caches).assetIds().isEmpty)
        #expect(store(Self.laptop, in: caches).assetIds() == [assetId])
    }

    // MARK: - Bound

    @Test func theStoreEvictsTheOldestBytesBeyondItsBound() async throws {
        let caches = try temporaryCaches()
        defer { try? FileManager.default.removeItem(at: caches) }
        let bound = 64 * 1024
        let disk = store(in: caches, maximumBytes: bound)
        let ids = ["A", "B", "C"].map { "ia_" + String(repeating: $0, count: 43) }

        for assetId in ids {
            disk.write(assetId: assetId, data: Data(repeating: 0, count: 30_000))
            // Distinct write times, so "oldest" is not a tie between two files.
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(disk.read(ids[0]) == nil, "the oldest bytes went to stay inside the bound")
        #expect(disk.assetIds() == [ids[1], ids[2]])
    }

    // MARK: - Drawing

    private func shownImage(_ icon: IconChoiceUIView) -> UIImage? {
        icon.subviews.compactMap { $0 as? UIImageView }.first?.image
    }

    private func shows(_ icon: IconChoiceUIView, mostly colour: UIColor) throws -> Bool {
        let shown = try #require(shownImage(icon))
        let average = try #require(averageColour(shown))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return average.a > 0.5
            && abs(average.r - red) < 0.12
            && abs(average.g - green) < 0.12
            && abs(average.b - blue) < 0.12
    }

    private func averageColour(_ image: UIImage) -> AverageColour? {
        var pixels = [UInt8](repeating: 0, count: 4)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = image.cgImage else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return AverageColour(
            r: CGFloat(pixels[0]) / 255,
            g: CGFloat(pixels[1]) / 255,
            b: CGFloat(pixels[2]) / 255,
            a: CGFloat(pixels[3]) / 255
        )
    }
}

/// The icon routes a test's transport answered, counted where URLSession runs them.
private final class IconAssetRequests: @unchecked Sendable {
    private let answered = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ path: String) {
        answered.withLock { $0.append(path) }
    }

    var count: Int {
        answered.withLock { $0.count }
    }
}
