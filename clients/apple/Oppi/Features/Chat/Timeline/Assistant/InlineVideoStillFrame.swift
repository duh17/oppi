import AVFoundation
import UIKit

/// Where an inline video's pre-tap still frame comes from.
///
/// The frame is read through the same bearer-authenticated resource loader the
/// player uses, so no token enters a URL and no new auth path exists. The
/// generator builds an `AVURLAsset` only; no `AVPlayer` or playback session is
/// created until the user taps play.
enum InlineVideoStillFrameGenerator {
    /// Fraction of a short clip to sample; frame zero is often black.
    fileprivate static let sampleTimeLimitSeconds = 1.0
    /// Longest wait for the first frame (header + range reads) before the
    /// placeholder stays. A slow link retries on a later row entry.
    static let deadline: Duration = .seconds(6)

    /// One generation's AVFoundation objects. `AVAssetImageGenerator` and the asset
    /// are documented thread-safe for the calls made here (load, request, cancel).
    private final class Job: @unchecked Sendable {
        let loader: AuthenticatedMediaResourceLoader
        let asset: AVURLAsset
        let generator: AVAssetImageGenerator

        init(source: AuthenticatedMediaSource, maxPixelSize: CGSize) {
            loader = AuthenticatedMediaResourceLoader(source: source)
            asset = AVURLAsset(url: AuthenticatedMediaPlaybackSession.makeAssetURL())
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maxPixelSize
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
        }

        func cancel() {
            generator.cancelAllCGImageGeneration()
            loader.cancelAll()
        }

        func frame() async -> UIImage? {
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let seconds = duration.isFinite && duration > 0
                ? min(InlineVideoStillFrameGenerator.sampleTimeLimitSeconds, duration / 10)
                : 0
            guard let result = try? await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)
            ) else { return nil }
            return UIImage(cgImage: result.image)
        }
    }

    static func generate(source: AuthenticatedMediaSource, maxPixelSize: CGSize) async -> UIImage? {
        let job = Job(source: source, maxPixelSize: maxPixelSize)
        let image = await withTaskCancellationHandler {
            await withTaskGroup(of: UIImage?.self) { group in
                group.addTask { await job.frame() }
                group.addTask {
                    try? await Task.sleep(for: deadline)
                    return nil
                }
                // First finisher wins: a frame, a failure, or the deadline.
                let first = await group.next() ?? nil
                // On the deadline the frame task may still be mid-read; fail its
                // loading requests so the group can finish instead of waiting on it.
                job.cancel()
                group.cancelAll()
                return first
            }
        } onCancel: {
            job.cancel()
        }

        // AVAssetResourceLoader does not retain its delegate. Detach it, fail any
        // pending requests, then drain the delegate queue while the loader is still
        // retained so a queued `didCancel` never runs against a released loader.
        job.asset.resourceLoader.setDelegate(nil, queue: nil)
        job.cancel()
        await withCheckedContinuation { continuation in
            job.loader.delegateQueue.async { continuation.resume() }
        }
        withExtendedLifetime(job) {}
        return image
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
    /// Bumped by `removeAll()`. A generation that started before the bump never
    /// writes its result back, so a memory warning cannot be undone by work in flight.
    private var epoch = 0
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
            let startEpoch = epoch
            // Completion runs inside the shared task so the cache is populated
            // before any waiter resumes.
            task = Task { @MainActor [weak self] in
                let image = await generator(source, maxPixelSize)
                self?.finish(key: key, image: image, epoch: startEpoch)
                return image
            }
            inFlight[key] = task
        }
        return await task.value
    }

    private func finish(key: String, image: UIImage?, epoch startEpoch: Int) {
        guard startEpoch == epoch else { return }
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
        epoch += 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAllObjects()
        failedAt.removeAll()
    }

    #if DEBUG
    static func installForTesting(_ store: InlineVideoStillFrameStore) { shared = store }
    #endif
}
