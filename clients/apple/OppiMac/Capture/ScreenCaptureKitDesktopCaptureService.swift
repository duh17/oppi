import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.chenda.OppiMac",
    category: "ScreenCapture"
)

/// ScreenCaptureKit stills and explicit local SCStream preview.
/// Stills stay one-shot in-memory `CGImage` via `SCScreenshotManager`.
/// Preview uses one SCStream with latest-frame buffering; no disk, encode, or share-gate publish.
/// Debug tests must inject a fake; they must not instantiate this type.
@MainActor
final class ScreenCaptureKitDesktopCaptureService: NSObject, DesktopCaptureServicing {
    weak var delegate: DesktopCaptureServiceDelegate?

    private var selectedFilter: SCContentFilter?
    private var selectedSurface: CaptureSurface?
    private var didAddObserver = false
    private var previewProducer: DesktopSCStreamPreviewProducer?
    /// Retained until stopCapture completes so a new SCStream cannot overlap a retiring one.
    private var retiringProducer: DesktopSCStreamPreviewProducer?

    func presentWindowPicker() {
        let picker = SCContentSharingPicker.shared
        if !didAddObserver {
            picker.add(self)
            didAddObserver = true
        }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.configuration = configuration
        picker.isActive = true
        picker.present(using: .window)
    }

    func captureStill(
        surface: CaptureSurface,
        completion: @escaping @MainActor (Result<CapturedStill, DesktopCaptureFailure>) -> Void
    ) {
        guard
            let filter = selectedFilter,
            let selected = selectedSurface,
            selected.surfaceID == surface.surfaceID
        else {
            completion(.failure(.unavailable))
            return
        }

        let windows = filter.includedWindows
        guard windows.count == 1, let window = windows.first else {
            completion(.failure(.unavailable))
            return
        }
        guard window.windowID == surface.surfaceID.windowID else {
            completion(.failure(.surfaceSubstitutionRejected))
            return
        }

        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int((filter.contentRect.width * scale).rounded(.up))
        let height = Int((filter.contentRect.height * scale).rounded(.up))
        if width > 0 {
            configuration.width = width
        }
        if height > 0 {
            configuration.height = height
        }
        configuration.showsCursor = false
        configuration.capturesAudio = false

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            Task { @MainActor in
                if let error {
                    completion(.failure(Self.mapError(error)))
                    return
                }
                guard let image else {
                    completion(.failure(.captureFailed))
                    return
                }
                completion(
                    .success(
                        CapturedStill(
                            captureID: UUID(),
                            surfaceID: surface.surfaceID,
                            capturedAt: Date(),
                            image: image
                        )
                    )
                )
            }
        }
    }

    func startLocalPreview(
        surface: CaptureSurface,
        generation: UInt64,
        handler: any DesktopLocalPreviewHandling
    ) {
        guard previewProducer == nil, retiringProducer == nil else {
            handler.localPreviewDidFail(generation: generation, failure: .captureFailed)
            return
        }

        guard
            let filter = selectedFilter,
            let selected = selectedSurface,
            selected.surfaceID == surface.surfaceID
        else {
            handler.localPreviewDidFail(generation: generation, failure: .unavailable)
            return
        }

        let windows = filter.includedWindows
        guard windows.count == 1, let window = windows.first else {
            handler.localPreviewDidFail(generation: generation, failure: .unavailable)
            return
        }
        guard window.windowID == surface.surfaceID.windowID else {
            handler.localPreviewDidFail(generation: generation, failure: .surfaceSubstitutionRejected)
            return
        }

        let callbacks = DesktopLocalPreviewCallbackBridge(
            generation: generation,
            surfaceID: surface.surfaceID,
            handler: handler,
            service: self
        )
        let producer = DesktopSCStreamPreviewProducer(
            surface: surface,
            filter: filter,
            configuration: Self.makeStreamConfiguration(filter: filter),
            confirmStart: { callbacks.confirmStart() },
            deliverFrame: { transferred in callbacks.deliverFrame(transferred) },
            fail: { failure in callbacks.fail(failure) },
            stopped: { failure in callbacks.stopped(failure) },
            surfaceUnavailable: { unavailableSurface in
                callbacks.surfaceUnavailable(unavailableSurface)
            }
        )
        callbacks.producer = producer
        previewProducer = producer
        producer.start()
    }

    func stopLocalPreview(generation: UInt64) {
        _ = generation
        retirePreviewProducer()
    }

    func currentAvailability() -> CaptureAvailability {
        if CGPreflightScreenCaptureAccess() {
            return .ready
        }
        return .permissionDenied
    }

    private func retirePreviewProducer() {
        guard let producer = previewProducer else { return }
        previewProducer = nil
        retiringProducer = producer
        producer.invalidateAndStop()
    }

    fileprivate func previewProducerDidFinish(_ producer: DesktopSCStreamPreviewProducer) {
        if previewProducer === producer {
            previewProducer = nil
        }
        if retiringProducer === producer {
            retiringProducer = nil
        }
    }

    private static func makeStreamConfiguration(filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let width = Int((filter.contentRect.width * scale).rounded(.up))
        let height = Int((filter.contentRect.height * scale).rounded(.up))
        if width > 0 {
            configuration.width = width
        }
        if height > 0 {
            configuration.height = height
        }
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    private func handlePickedFilter(_ filter: SCContentFilter) {
        let windows = filter.includedWindows
        guard windows.count == 1, let window = windows.first else {
            selectedFilter = nil
            selectedSurface = nil
            delegate?.desktopCaptureServiceDidFail(.unavailable)
            return
        }

        let trimmedTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let surface = CaptureSurface(
            surfaceID: CaptureSurfaceID(windowID: window.windowID),
            title: trimmedTitle.isEmpty ? "Window" : trimmedTitle
        )
        selectedFilter = filter
        selectedSurface = surface
        delegate?.desktopCaptureServiceDidSelect(surface)
    }

    nonisolated fileprivate static func mapError(_ error: Error) -> DesktopCaptureFailure {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain,
              let code = SCStreamError.Code(rawValue: nsError.code)
        else {
            return .captureFailed
        }
        switch code {
        case .userDeclined, .missingEntitlements:
            return .permissionDenied
        case .noCaptureSource, .noWindowList, .noDisplayList,
             .failedApplicationConnectionInvalid, .failedApplicationConnectionInterrupted,
             .failedNoMatchingApplicationContext:
            return .unavailable
        case .userStopped:
            return .cancelled
        default:
            return .captureFailed
        }
    }
}

/// Hops preview callbacks onto the main actor without capturing a MainActor handler in Sendable closures.
private final class DesktopLocalPreviewCallbackBridge: @unchecked Sendable {
    let generation: UInt64
    let surfaceID: CaptureSurfaceID
    nonisolated(unsafe) weak var handler: (any DesktopLocalPreviewHandling)?
    nonisolated(unsafe) weak var service: ScreenCaptureKitDesktopCaptureService?
    nonisolated(unsafe) weak var producer: DesktopSCStreamPreviewProducer?

    init(
        generation: UInt64,
        surfaceID: CaptureSurfaceID,
        handler: any DesktopLocalPreviewHandling,
        service: ScreenCaptureKitDesktopCaptureService
    ) {
        self.generation = generation
        self.surfaceID = surfaceID
        self.handler = handler
        self.service = service
    }

    func confirmStart() {
        let generation = self.generation
        Task { @MainActor in
            self.handler?.localPreviewDidConfirmStart(generation: generation)
        }
    }

    /// Must run on the mailbox's existing MainActor hop. Do not enqueue another Task.
    func deliverFrame(_ transferred: TransferredCGImage) {
        let generation = self.generation
        let surfaceID = self.surfaceID
        let image = transferred.image
        MainActor.assumeIsolated {
            self.handler?.localPreviewDidDeliverFrame(
                DesktopPreviewFrame(
                    surfaceID: surfaceID,
                    capturedAt: Date(),
                    image: image
                ),
                generation: generation
            )
        }
    }

    func fail(_ failure: DesktopCaptureFailure) {
        let generation = self.generation
        let producer = self.producer
        Task { @MainActor in
            if let producer {
                self.service?.previewProducerDidFinish(producer)
            }
            self.handler?.localPreviewDidFail(generation: generation, failure: failure)
        }
    }

    func stopped(_ failure: DesktopCaptureFailure?) {
        let generation = self.generation
        let producer = self.producer
        Task { @MainActor in
            if let producer {
                self.service?.previewProducerDidFinish(producer)
            }
            self.handler?.localPreviewDidStop(generation: generation, failure: failure)
        }
    }

    func surfaceUnavailable(_ surface: CaptureSurface) {
        Task { @MainActor in
            self.service?.delegate?.desktopCaptureServiceSurfaceBecameUnavailable(surface)
        }
    }
}

/// One SCStream, latest-frame only. Stop/invalidate discards pending and late frames.
final class DesktopSCStreamPreviewProducer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let surface: CaptureSurface
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let captureQueue = DispatchQueue(label: "dev.chenda.OppiMac.local-preview")
    private let confirmStart: @Sendable () -> Void
    private let fail: @Sendable (DesktopCaptureFailure) -> Void
    private let stopped: @Sendable (DesktopCaptureFailure?) -> Void
    private let surfaceUnavailable: @Sendable (CaptureSurface) -> Void
    private let mailbox: DesktopLatestFrameMailbox<TransferredCGImage>
    private let invalidation: PreviewInvalidationState
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
    ])
    private let lock = NSLock()
    private var stream: SCStream?
    private var invalidated = false
    private var stopping = false

    init(
        surface: CaptureSurface,
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        confirmStart: @escaping @Sendable () -> Void,
        deliverFrame: @escaping @Sendable (TransferredCGImage) -> Void,
        fail: @escaping @Sendable (DesktopCaptureFailure) -> Void,
        stopped: @escaping @Sendable (DesktopCaptureFailure?) -> Void,
        surfaceUnavailable: @escaping @Sendable (CaptureSurface) -> Void
    ) {
        self.surface = surface
        self.filter = filter
        self.configuration = configuration
        self.confirmStart = confirmStart
        self.fail = fail
        self.stopped = stopped
        self.surfaceUnavailable = surfaceUnavailable
        let closed = PreviewInvalidationState()
        self.mailbox = DesktopLatestFrameMailbox<TransferredCGImage>(
            schedule: { work in
                Task { @MainActor in
                    work()
                }
            },
            deliver: { transferred in
                guard !closed.isInvalidated else { return }
                deliverFrame(transferred)
            }
        )
        self.invalidation = closed
        super.init()
    }

    func start() {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            fail(ScreenCaptureKitDesktopCaptureService.mapError(error))
            return
        }

        lock.lock()
        if invalidated {
            lock.unlock()
            stream.stopCapture { _ in }
            return
        }
        self.stream = stream
        lock.unlock()

        stream.startCapture { [weak self] error in
            self?.handleStart(error)
        }
    }

    func invalidateAndStop() {
        lock.lock()
        invalidated = true
        invalidation.invalidate()
        if stopping {
            lock.unlock()
            mailbox.close()
            return
        }
        stopping = true
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        mailbox.close()

        guard let stream else {
            stopped(nil)
            return
        }
        stream.stopCapture { [weak self] error in
            self?.stopped(error.map(ScreenCaptureKitDesktopCaptureService.mapError))
        }
    }

    deinit {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        stream?.stopCapture(completionHandler: { _ in })
    }

    private func handleStart(_ error: Error?) {
        lock.lock()
        if invalidated {
            let stream = self.stream
            self.stream = nil
            let alreadyStopping = stopping
            stopping = true
            lock.unlock()
            mailbox.close()
            if let stream {
                stream.stopCapture { [weak self] error in
                    if alreadyStopping { return }
                    self?.stopped(error.map(ScreenCaptureKitDesktopCaptureService.mapError))
                }
            } else if !alreadyStopping {
                stopped(nil)
            }
            return
        }
        if let error {
            invalidated = true
            invalidation.invalidate()
            stopping = true
            self.stream = nil
            lock.unlock()
            mailbox.close()
            fail(ScreenCaptureKitDesktopCaptureService.mapError(error))
            return
        }
        lock.unlock()
        confirmStart()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        lock.lock()
        let invalid = invalidated
        lock.unlock()
        guard !invalid else { return }
        guard let image = makeCGImage(from: sampleBuffer) else { return }
        mailbox.offer(TransferredCGImage(image: image))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        if invalidated {
            let alreadyStopping = stopping
            stopping = true
            self.stream = nil
            lock.unlock()
            mailbox.close()
            if !alreadyStopping {
                stopped(ScreenCaptureKitDesktopCaptureService.mapError(error))
            }
            return
        }
        invalidated = true
        invalidation.invalidate()
        stopping = true
        self.stream = nil
        lock.unlock()
        mailbox.close()

        let failure = ScreenCaptureKitDesktopCaptureService.mapError(error)
        if failure == .unavailable {
            surfaceUnavailable(surface)
        }
        fail(failure)
    }

    private func makeCGImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        return ciContext.createCGImage(image, from: extent)
    }
}

private final class PreviewInvalidationState: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false

    var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }
}

/// ScreenCaptureKit delivers picker callbacks off the main actor with a non-Sendable filter.
/// The filter is treated as exclusively owned after `didUpdateWith`.
private struct TransferredContentFilter: @unchecked Sendable {
    let filter: SCContentFilter
}

extension ScreenCaptureKitDesktopCaptureService: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            self.delegate?.desktopCaptureServiceDidCancelPicker()
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let transferred = TransferredContentFilter(filter: filter)
        Task { @MainActor in
            self.handlePickedFilter(transferred.filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        let mapped = Self.mapError(error)
        Task { @MainActor in
            logger.error("Content sharing picker failed: \(message, privacy: .public)")
            self.delegate?.desktopCaptureServiceDidFail(mapped)
        }
    }
}
