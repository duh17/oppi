import AVFoundation
import UIKit

/// Where an inline video's pre-tap still frame comes from.
///
/// The frame is read through the same bearer-authenticated resource loader the
/// player uses, so no token enters a URL and no new auth path exists. The
/// generator builds an `AVURLAsset` only; no `AVPlayer` or playback session is
/// created until the user taps play.
enum InlineVideoStillFrameGenerator {
    /// Longest wait for the first frame before the placeholder stays.
    private static let frameTimeLimitSeconds = 1.0

    static func generate(source: AuthenticatedMediaSource, maxPixelSize: CGSize) async -> UIImage? {
        let loader = AuthenticatedMediaResourceLoader(source: source)
        let asset = AVURLAsset(url: AuthenticatedMediaPlaybackSession.makeAssetURL())
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        defer {
            asset.resourceLoader.setDelegate(nil, queue: nil)
            loader.cancelAll()
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxPixelSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // Frame zero is often black; a tenth of a short clip is not.
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let seconds = duration.isFinite && duration > 0 ? min(frameTimeLimitSeconds, duration / 10) : 0
        guard let result = try? await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600)
        ) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

/// Memory-bounded still-frame owner keyed by source identity and target size.
///
/// A row that scrolls back in finds its frame here instead of refetching or
/// re-decoding. Concurrent requests for one key share one generation, and a
/// waiter that goes away (row recycled) never cancels the shared work, so the
/// result still lands in the cache. A failed key is not retried for a short
/// window so a missing file does not refetch on every scroll-in.
@MainActor
final class InlineVideoStillFrameStore {
    typealias Generator = @Sendable (AuthenticatedMediaSource, CGSize) async -> UIImage?

    static let countLimit = 48
    static let totalCostLimit = 48 * 1024 * 1024
    static let failureRetryInterval: TimeInterval = 30

    private(set) static var shared = InlineVideoStillFrameStore()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private let generator: Generator
    #if DEBUG
    private(set) var debugGenerationCountForTesting = 0
    #endif

    init(
        generator: @escaping Generator = { source, size in
            await InlineVideoStillFrameGenerator.generate(source: source, maxPixelSize: size)
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.generator = generator
        cache.countLimit = Self.countLimit
        cache.totalCostLimit = Self.totalCostLimit
        // The shared store lives for the process. Test stores leave a weak-self
        // observer behind, which is inert once the store is gone.
        notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    private static func key(_ source: AuthenticatedMediaSource, _ size: CGSize) -> String {
        "\(source.identity)|\(Int(size.width))x\(Int(size.height))"
    }

    func cachedImage(for source: AuthenticatedMediaSource, maxPixelSize: CGSize) -> UIImage? {
        cache.object(forKey: Self.key(source, maxPixelSize) as NSString)
    }

    func image(for source: AuthenticatedMediaSource, maxPixelSize: CGSize) async -> UIImage? {
        let key = Self.key(source, maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < Self.failureRetryInterval {
            return nil
        }

        let task: Task<UIImage?, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            #if DEBUG
            debugGenerationCountForTesting += 1
            #endif
            let generator = generator
            // Completion runs inside the shared task so the cache is populated
            // before any waiter resumes.
            task = Task { @MainActor [weak self] in
                let image = await generator(source, maxPixelSize)
                self?.finish(key: key, image: image)
                return image
            }
            inFlight[key] = task
        }
        return await task.value
    }

    private func finish(key: String, image: UIImage?) {
        inFlight[key] = nil
        guard let image else {
            failedAt[key] = Date()
            return
        }
        failedAt[key] = nil
        let cost = max(1, Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
        failedAt.removeAll()
    }

    #if DEBUG
    static func installForTesting(_ store: InlineVideoStillFrameStore) { shared = store }
    #endif
}
