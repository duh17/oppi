@preconcurrency import AVFoundation
import AVKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AuthenticatedMediaPlaybackConstants {
    static let scheme = "oppi-media"
}

struct AuthenticatedMediaRequestedRange: Equatable, Sendable {
    static let maxChunkLength: Int64 = 1_048_576

    /// Inclusive start byte. `end` is nil for an open-ended `bytes=N-` request.
    let start: Int64
    let end: Int64?
    /// True when this HTTP range is only the next chunk of a larger AVPlayer request.
    let continuesToEnd: Bool

    init(start: Int64, end: Int64?, continuesToEnd: Bool = false) {
        self.start = start
        self.end = end
        self.continuesToEnd = continuesToEnd
    }

    /// AVPlayer often asks for the rest of the resource with `requestedLength ==
    /// Int.max`. A closed `bytes=N-9223372036854775806` header is not a JS safe
    /// integer, so the Oppi server rejects it as HTTP 416 and playback stalls.
    /// Cap each HTTP GET to 1 MB and continue the same loading request in chunks.
    static func make(
        offset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool
    ) -> AuthenticatedMediaRequestedRange {
        let start = max(offset, 0)
        let wantsRest = requestsAllDataToEndOfResource
            || requestedLength <= 0
            || requestedLength == Int.max
        let requested = wantsRest ? Self.maxChunkLength : Int64(requestedLength)
        let length = min(max(requested, 1), Self.maxChunkLength)
        if start > Int64.max - length {
            return AuthenticatedMediaRequestedRange(start: start, end: nil, continuesToEnd: wantsRest)
        }
        return AuthenticatedMediaRequestedRange(
            start: start,
            end: start + length - 1,
            continuesToEnd: wantsRest
        )
    }

    var headerValue: String {
        if let end {
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }
}

enum AuthenticatedMediaRangeContinuation {
    static func nextOffset(afterEnd: Int64, totalLength: Int64?) -> Int64? {
        guard let totalLength else { return nil }
        let next = afterEnd + 1
        return next < totalLength ? next : nil
    }
}

enum AuthenticatedMediaResponseValidator {
    static func errorMessage(
        statusCode: Int,
        requestedRange: AuthenticatedMediaRequestedRange?,
        contentRange: String?
    ) -> String? {
        guard (200 ... 299).contains(statusCode) else {
            return "Media request failed with HTTP \(statusCode)"
        }

        guard let requestedRange else { return nil }
        guard statusCode == 206 else {
            return "Ranged media request expected HTTP 206 but received HTTP \(statusCode)"
        }
        guard let parsedRange = parseContentRange(contentRange) else {
            return "Ranged media response is missing a valid Content-Range header"
        }
        guard parsedRange.start == requestedRange.start,
              let parsedEnd = parsedRange.end,
              parsedEnd >= requestedRange.start else {
            return "Ranged media response Content-Range does not match the requested byte range"
        }
        if let requestedEnd = requestedRange.end, parsedEnd > requestedEnd {
            return "Ranged media response Content-Range does not match the requested byte range"
        }
        return nil
    }

    private static func parseContentRange(_ header: String?) -> AuthenticatedMediaRequestedRange? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndLength = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndLength.count == 2 else { return nil }
        let bounds = rangeAndLength[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        if rangeAndLength[1] != "*" {
            guard let total = Int64(rangeAndLength[1]), total > end else {
                return nil
            }
        }
        return AuthenticatedMediaRequestedRange(start: start, end: end)
    }
}

/// Streams bearer-authenticated media through AVFoundation without putting the
/// token in the URL. AVPlayer talks to an `oppi-media://` URL; this loader
/// turns AVFoundation byte-range requests into normal HTTP requests with the
/// `Authorization` header.
private final class AuthenticatedMediaResourceLoader: NSObject, @unchecked Sendable, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private final class LoadingContext {
        let loadingRequest: AVAssetResourceLoadingRequest
        var requestedRange: AuthenticatedMediaRequestedRange?
        var continueToEnd = false
        var totalLength: Int64?
        var deliveredEnd: Int64?
        var cancelled = false
        var responseError: Error?

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            requestedRange: AuthenticatedMediaRequestedRange?
        ) {
            self.loadingRequest = loadingRequest
            self.requestedRange = requestedRange
            self.continueToEnd = requestedRange?.continuesToEnd ?? false
        }
    }

    private let source: AuthenticatedMediaSource
    private let trustDelegate: PinnedServerTrustDelegate
    private let lock = NSLock()
    private var contextsByTaskId: [Int: LoadingContext] = [:]
    private var tasksByRequestId: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var isInvalidated = false
    private var liveTaskIds: Set<Int> = []
    private var networkLifetime: AuthenticatedMediaResourceLoader?

    let delegateQueue = DispatchQueue(label: "dev.chenda.oppi.authenticated-media.resource-loader")
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    init(source: AuthenticatedMediaSource) {
        self.source = source
        trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: source.tlsCertFingerprint,
            expectedServerName: source.tlsServerName
        )
        super.init()
    }

    deinit {
        // cancelAll() may retain self while CFNetwork still has callbacks.
        // Do not do that from deinit. Idle loaders only need session invalidation.
        session.invalidateAndCancel()
    }

    func cancelAll() {
        lock.lock()
        isInvalidated = true
        for context in contextsByTaskId.values {
            context.cancelled = true
        }
        let tasks = Array(tasksByRequestId.values)
        let shouldRetain = !liveTaskIds.isEmpty || !tasks.isEmpty
        if shouldRetain {
            // Keep the URLSession delegate alive until didComplete / invalidation.
            // Dropping it here UAFs under in-flight CFNetwork callbacks.
            networkLifetime = self
        }
#if DEBUG
        AuthenticatedMediaResourceLoaderTesting.lastCancelRetainedSelfForInFlightCallbacks = shouldRetain
#endif
        contextsByTaskId.removeAll()
        tasksByRequestId.removeAll()
        lock.unlock()

        for task in tasks {
            task.cancel()
        }

        if !shouldRetain {
            session.invalidateAndCancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Resolve the byte range synchronously; resolve the bearer per request so
        // long playback refreshes instead of reusing a short-lived token snapshot.
        let requestedRange: AuthenticatedMediaRequestedRange?
        let rangeHeader: String?
        if let dataRequest = loadingRequest.dataRequest {
            let offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
            requestedRange = AuthenticatedMediaRequestedRange.make(
                offset: offset,
                requestedLength: dataRequest.requestedLength,
                requestsAllDataToEndOfResource: dataRequest.requestsAllDataToEndOfResource
            )
            rangeHeader = requestedRange?.headerValue
        } else {
            requestedRange = nil
            rangeHeader = nil
        }

        let requestId = ObjectIdentifier(loadingRequest)
        let url = source.url
        let authorizationProvider = source.authorizationProvider
        Task { [weak self] in
            guard let self else {
                return
            }
            // Resolve the bearer before building the request. A failure here
            // (revoked/unknown device, unavailable key) fails the AV loading
            // request without ever issuing an unauthenticated network request.
            let authorization: String
            do {
                authorization = try await authorizationProvider()
            } catch {
                self.finishLoadingIfActive(loadingRequest, error: error)
                return
            }
            guard !authorization.isEmpty else {
                self.finishLoadingIfActive(loadingRequest, error: mediaError("No bearer available"))
                return
            }
            if self.isAbandoned(loadingRequest) {
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = loadingRequest.dataRequest == nil ? "HEAD" : "GET"
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if let rangeHeader {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }

            let task = self.session.dataTask(with: request)
            let context = LoadingContext(loadingRequest: loadingRequest, requestedRange: requestedRange)
            let shouldStart = self.lock.withLock { () -> Bool in
                if self.isInvalidated {
                    return false
                }
                self.contextsByTaskId[task.taskIdentifier] = context
                self.tasksByRequestId[requestId] = task
                self.liveTaskIds.insert(task.taskIdentifier)
                return true
            }
            if shouldStart {
                task.resume()
            } else {
                task.cancel()
            }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let requestId = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasksByRequestId.removeValue(forKey: requestId)
        if let task, let context = contextsByTaskId.removeValue(forKey: task.taskIdentifier) {
            context.cancelled = true
        }
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trustDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trustDelegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        context(for: task)?.responseError = mediaError("Media redirects are not allowed")
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = context(for: dataTask) else {
            completionHandler(.cancel)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            context.responseError = mediaError("Invalid media response")
            completionHandler(.cancel)
            return
        }

        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        if let errorMessage = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: http.statusCode,
            requestedRange: context.requestedRange,
            contentRange: contentRange
        ) {
            MediaPlaybackTelemetry.logError(
                kind: MediaPlaybackTelemetry.mediaKind(
                    mimeType: source.contentTypeHint,
                    sourceFileExtension: source.sourceFileExtension
                ),
                source: "authenticated_media",
                mode: "range",
                phase: "range_response",
                error: mediaError(errorMessage),
                message: errorMessage
            )
            ClientLog.warning(
                "MediaPlayback",
                errorMessage,
                metadata: [
                    "status": String(http.statusCode),
                    "range": context.requestedRange?.headerValue ?? "none",
                    "content_range": contentRange ?? "",
                ]
            )
            context.responseError = mediaError(errorMessage)
            completionHandler(.cancel)
            return
        }

        if let totalLength = totalLengthFromContentRange(contentRange) {
            context.totalLength = totalLength
        }
        if let deliveredEnd = endFromContentRange(contentRange) {
            context.deliveredEnd = deliveredEnd
        }
        fillContentInformation(
            context.loadingRequest.contentInformationRequest,
            response: http
        )
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let context = context(for: dataTask), !context.cancelled else { return }
        context.loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let context = removeContext(for: task)
        let shouldInvalidate = lock.withLock { () -> Bool in
            liveTaskIds.remove(task.taskIdentifier)
            return isInvalidated && liveTaskIds.isEmpty
        }

        if let context, !context.cancelled {
            if let error = context.responseError ?? error {
                context.loadingRequest.finishLoading(with: error)
            } else if context.continueToEnd,
                      let deliveredEnd = context.deliveredEnd,
                      let nextOffset = AuthenticatedMediaRangeContinuation.nextOffset(
                        afterEnd: deliveredEnd,
                        totalLength: context.totalLength
                      ) {
                startNextChunk(context: context, offset: nextOffset)
            } else {
                context.loadingRequest.finishLoading()
            }
        }

        if shouldInvalidate {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError: Error?) {
        lock.lock()
        networkLifetime = nil
        lock.unlock()
    }

    private func startNextChunk(context: LoadingContext, offset: Int64) {
        let nextRange = AuthenticatedMediaRequestedRange.make(
            offset: offset,
            requestedLength: Int(AuthenticatedMediaRequestedRange.maxChunkLength),
            requestsAllDataToEndOfResource: true
        )
        let loadingRequest = context.loadingRequest
        let continueToEnd = context.continueToEnd
        let totalLength = context.totalLength
        let requestId = ObjectIdentifier(loadingRequest)
        let authorizationProvider = source.authorizationProvider
        Task { [weak self] in
            guard let self else { return }
            let authorization: String
            do {
                authorization = try await authorizationProvider()
            } catch {
                self.finishLoadingIfActive(loadingRequest, error: error)
                return
            }
            guard !authorization.isEmpty else {
                self.finishLoadingIfActive(loadingRequest, error: self.mediaError("No bearer available"))
                return
            }
            var request = URLRequest(url: self.source.url)
            request.httpMethod = "GET"
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue(nextRange.headerValue, forHTTPHeaderField: "Range")
            if loadingRequest.isCancelled || loadingRequest.isFinished {
                return
            }
            let nextContext = LoadingContext(
                loadingRequest: loadingRequest,
                requestedRange: nextRange
            )
            nextContext.continueToEnd = continueToEnd
            nextContext.totalLength = totalLength
            let task = self.session.dataTask(with: request)
            let shouldStart = self.lock.withLock { () -> Bool in
                if self.isInvalidated {
                    return false
                }
                self.contextsByTaskId[task.taskIdentifier] = nextContext
                self.tasksByRequestId[requestId] = task
                self.liveTaskIds.insert(task.taskIdentifier)
                return true
            }
            if shouldStart {
                task.resume()
            } else {
                task.cancel()
            }
        }
    }

    private func isAbandoned(_ loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if loadingRequest.isCancelled || loadingRequest.isFinished {
            return true
        }
        return lock.withLock { isInvalidated }
    }

    private func finishLoadingIfActive(_ loadingRequest: AVAssetResourceLoadingRequest, error: Error) {
        guard !isAbandoned(loadingRequest) else { return }
        loadingRequest.finishLoading(with: error)
    }

    private func context(for task: URLSessionTask) -> LoadingContext? {
        lock.lock()
        let context = contextsByTaskId[task.taskIdentifier]
        lock.unlock()
        return context
    }

    private func removeContext(for task: URLSessionTask) -> LoadingContext? {
        lock.lock()
        let context = contextsByTaskId.removeValue(forKey: task.taskIdentifier)
        if let context {
            tasksByRequestId.removeValue(forKey: ObjectIdentifier(context.loadingRequest))
        }
        lock.unlock()
        return context
    }

    private func fillContentInformation(
        _ info: AVAssetResourceLoadingContentInformationRequest?,
        response: HTTPURLResponse
    ) {
        guard let info else { return }

        let mimeType = response.mimeType ?? source.contentTypeHint
        info.contentType = resourceLoaderContentType(
            mimeType: mimeType,
            fallbackExtension: source.sourceFileExtension
        )
        info.isByteRangeAccessSupported = true

        if let totalLength = totalLengthFromContentRange(response.value(forHTTPHeaderField: "Content-Range")) {
            info.contentLength = totalLength
        } else if response.expectedContentLength >= 0 {
            info.contentLength = response.expectedContentLength
        }
    }

    private func resourceLoaderContentType(mimeType: String?, fallbackExtension: String?) -> String {
        if let mimeType,
           let type = UTType(mimeType: mimeType) {
            return type.identifier
        }

        if let fallbackExtension,
           let type = UTType(filenameExtension: fallbackExtension) {
            return type.identifier
        }

        return UTType.data.identifier
    }

    private func totalLengthFromContentRange(_ header: String?) -> Int64? {
        guard let header else { return nil }
        guard let slashIndex = header.lastIndex(of: "/") else { return nil }
        let suffix = header[header.index(after: slashIndex)...]
        guard suffix != "*" else { return nil }
        return Int64(suffix)
    }

    private func endFromContentRange(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let rangeAndLength = parts[1].split(separator: "/", maxSplits: 1)
        guard !rangeAndLength.isEmpty else { return nil }
        let bounds = rangeAndLength[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2 else { return nil }
        return Int64(bounds[1])
    }

    private func mediaError(_ message: String) -> NSError {
        NSError(
            domain: "dev.chenda.oppi.authenticated-media",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum MediaPlaybackTelemetry {
    static func mediaKind(mimeType: String?, sourceFileExtension: String?) -> String {
        let normalizedMime = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalizedMime.hasPrefix("video/") { return "video" }
        if normalizedMime.hasPrefix("audio/") { return "audio" }
        if normalizedMime.hasPrefix("image/") { return "image" }

        let ext = sourceFileExtension?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["mp4", "mov", "webm", "mkv"].contains(ext) { return "video" }
        if ["wav", "mp3", "m4a", "aac", "flac", "ogg", "opus"].contains(ext) { return "audio" }
        if ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff"].contains(ext) { return "image" }
        return "unknown"
    }

    static func recordStart(
        startedNs: UInt64,
        kind: String,
        source: String,
        mode: String,
        sessionId: String?
    ) {
        let durationMs = Double((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .mediaPlaybackStartMs,
                value: durationMs,
                unit: .ms,
                sessionId: sessionId,
                tags: [
                    "kind": kind,
                    "source": source,
                    "mode": mode,
                    "status": "ok",
                ]
            )
        }
    }

    static func recordError(
        kind: String,
        source: String,
        phase: String,
        error: Error?,
        sessionId: String?
    ) {
        let errorKind = error.map { Self.errorKind($0) } ?? "other"
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .mediaPlaybackError,
                value: 1,
                unit: .count,
                sessionId: sessionId,
                tags: [
                    "kind": kind,
                    "source": source,
                    "phase": phase,
                    "error_kind": errorKind,
                ]
            )
        }
    }

    static func logError(
        kind: String,
        source: String,
        mode: String,
        phase: String,
        error: Error?,
        message: String = "Media playback failed"
    ) {
        ClientLog.warning(
            "MediaPlayback",
            message,
            metadata: clientLogMetadata(
                kind: kind,
                source: source,
                phase: phase,
                error: error,
                extra: ["mode": mode]
            )
        )
    }

    static func clientLogMetadata(
        kind: String,
        source: String,
        phase: String,
        error: Error? = nil,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "kind": kind,
            "source": source,
            "phase": phase,
        ]
        if let error {
            metadata.merge(ClientLog.networkErrorMetadata(error)) { current, _ in current }
            metadata["error_kind"] = Self.errorKind(error)
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private static func errorKind(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "timeout"
            case NSURLErrorCancelled:
                return "cancelled"
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return "network"
            default:
                return "network"
            }
        }
        if nsError.domain == AVFoundationErrorDomain {
            return "avfoundation"
        }
        if nsError.domain == "dev.chenda.oppi.authenticated-media" {
            return "http"
        }
        return "other"
    }
}

@MainActor
final class AuthenticatedMediaPlaybackSession {
    let player: AVPlayer

    private let loader: AuthenticatedMediaResourceLoader
    private let asset: AVURLAsset
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var hasStartedPlaying = false
    private var lastStallLogAt: TimeInterval = 0

    init(source: AuthenticatedMediaSource) {
        loader = AuthenticatedMediaResourceLoader(source: source)
        asset = AVURLAsset(url: Self.makeAssetURL())
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)

        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: [
                "playable",
                "tracks",
                "duration",
                "hasProtectedContent",
            ]
        )
        player = AVPlayer(playerItem: item)
        // Custom resource-loader assets should not wait to minimize stalling;
        // AVPlayer cannot see the real network buffer behind oppi-media://.
        player.automaticallyWaitsToMinimizeStalling = false
        observeStalls(kind: MediaPlaybackTelemetry.mediaKind(
            mimeType: source.contentTypeHint,
            sourceFileExtension: source.sourceFileExtension
        ))
    }

    private func observeStalls(kind: String) {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.handleTimeControlChange(player.timeControlStatus, kind: kind)
            }
        }
        bufferEmptyObservation = player.currentItem?.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.handleBufferEmpty(item.isPlaybackBufferEmpty, kind: kind)
            }
        }
    }

    private func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus, kind: String) {
        if status == .playing {
            hasStartedPlaying = true
            return
        }
        guard hasStartedPlaying, status == .waitingToPlayAtSpecifiedRate else { return }
        logStall(kind: kind, reason: player.reasonForWaitingToPlay?.rawValue ?? "waiting")
    }

    private func handleBufferEmpty(_ isEmpty: Bool, kind: String) {
        guard hasStartedPlaying, isEmpty else { return }
        logStall(kind: kind, reason: "playback_buffer_empty")
    }

    private func logStall(kind: String, reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStallLogAt >= 2 else { return }
        lastStallLogAt = now
        ClientLog.warning(
            "MediaPlayback",
            "Media playback stalled",
            metadata: [
                "kind": kind,
                "reason": reason,
                "time_control": String(describing: player.timeControlStatus),
            ]
        )
        MediaPlaybackTelemetry.recordError(
            kind: kind,
            source: "authenticated_media",
            phase: "stall",
            error: nil,
            sessionId: nil
        )
    }

    private static func makeAssetURL() -> URL {
        var components = URLComponents()
        components.scheme = AuthenticatedMediaPlaybackConstants.scheme
        components.host = "stream"
        components.path = "/\(UUID().uuidString)"
        return components.url ?? URL(fileURLWithPath: "/oppi-media-\(UUID().uuidString)")
    }

    /// Pause transport without dropping the item. Apple's AVPlayer API uses
    /// `pause()` to stop playback; `replaceCurrentItem(with:)` is for switching
    /// assets on a reused player, not for hide/dismiss.
    func pausePlayback() {
        player.pause()
    }

    func teardown() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        Self.discardItem(player)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        loader.cancelAll()
    }

    deinit {
        Self.discardItem(player)
        loader.cancelAll()
    }

    /// Drop the item only when the host is actually destroyed. A later `play()`
    /// on an empty AVPlayer cannot leak audio.
    nonisolated private static func discardItem(_ player: AVPlayer) {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

enum MediaPlaybackDisappearSource: Equatable {
    case playerSurface
    case timelineVisibility
}

enum MediaPlaybackTeardownPolicy {
    struct Ownership: Equatable {
        var isVisible = true
        var isFullScreen = false
        var isPictureInPicture = false
        var isFullScreenTransitioning = false

        var shouldTeardown: Bool {
            !isVisible && !isFullScreen && !isPictureInPicture && !isFullScreenTransitioning
        }
    }

    enum Event: Equatable {
        case setVisible(Bool)
        case willBeginFullScreen
        case willEndFullScreen
        case didEndFullScreen
        case willStartPictureInPicture
        case didStopPictureInPicture
    }

    static func apply(_ event: Event, to ownership: inout Ownership) {
        switch event {
        case .setVisible(let visible):
            ownership.isVisible = visible
        case .willBeginFullScreen:
            ownership.isFullScreen = true
            ownership.isFullScreenTransitioning = false
        case .willEndFullScreen:
            ownership.isFullScreenTransitioning = true
        case .didEndFullScreen:
            ownership.isFullScreen = false
            ownership.isFullScreenTransitioning = false
        case .willStartPictureInPicture:
            ownership.isPictureInPicture = true
        case .didStopPictureInPicture:
            ownership.isPictureInPicture = false
        }
    }

    static func shouldTeardown(
        isVisible: Bool,
        isFullScreen: Bool,
        isPictureInPicture: Bool
    ) -> Bool {
        Ownership(
            isVisible: isVisible,
            isFullScreen: isFullScreen,
            isPictureInPicture: isPictureInPicture
        ).shouldTeardown
    }
}

@MainActor
final class AuthenticatedMediaPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var playbackSession: AuthenticatedMediaPlaybackSession?
    private var statusObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var preparedIdentity: String?
    private var recordedStartIdentity: String?
    private var recordedErrorIdentity: String?
    private var ownership = MediaPlaybackTeardownPolicy.Ownership()
    private var suppressNextReturnedSurfaceDisappear = false
#if DEBUG
    var debugDidTeardownForTesting = false
    var debugIsVisibleForTesting: Bool { ownership.isVisible }
#endif

    func prepare(
        source: AuthenticatedMediaSource,
        autoplay: Bool,
        telemetrySource: String,
        telemetryMode: String,
        telemetrySessionId: String?,
        onPresentationSize: (@MainActor @Sendable (CGSize) -> Void)?
    ) {
        guard preparedIdentity != source.identity else { return }

        teardown(resetPreparedIdentity: false)
        preparedIdentity = source.identity
        recordedStartIdentity = nil
        recordedErrorIdentity = nil
        isLoading = true
        errorMessage = nil

        let startedNs = DispatchTime.now().uptimeNanoseconds
        let mediaKind = MediaPlaybackTelemetry.mediaKind(
            mimeType: source.contentTypeHint,
            sourceFileExtension: source.sourceFileExtension
        )
        let playbackSession = AuthenticatedMediaPlaybackSession(source: source)
        let player = playbackSession.player
        self.playbackSession = playbackSession
        self.player = player

        presentationSizeObservation = player.currentItem?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let width = item.presentationSize.width
            let height = item.presentationSize.height
            Task { @MainActor [weak self] in
                self?.handlePresentationSize(
                    width: width,
                    height: height,
                    callback: onPresentationSize
                )
            }
        }
        statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.errorMessage = nil
                    if self.recordedStartIdentity != source.identity {
                        self.recordedStartIdentity = source.identity
                        MediaPlaybackTelemetry.recordStart(
                            startedNs: startedNs,
                            kind: mediaKind,
                            source: telemetrySource,
                            mode: telemetryMode,
                            sessionId: telemetrySessionId
                        )
                    }
                    if autoplay {
                        player.play()
                    }
                case .failed:
                    self.isLoading = false
                    self.errorMessage = item.error?.localizedDescription ?? "Media failed to load"
                    if self.recordedErrorIdentity != source.identity {
                        self.recordedErrorIdentity = source.identity
                        MediaPlaybackTelemetry.recordError(
                            kind: mediaKind,
                            source: telemetrySource,
                            phase: "player_item",
                            error: item.error,
                            sessionId: telemetrySessionId
                        )
                        MediaPlaybackTelemetry.logError(
                            kind: mediaKind,
                            source: telemetrySource,
                            mode: telemetryMode,
                            phase: "player_item",
                            error: item.error
                        )
                    }
                    player.pause()
                    self.player = nil
                case .unknown:
                    self.isLoading = true
                @unknown default:
                    self.isLoading = false
                    self.errorMessage = "Unsupported media state"
                    if self.recordedErrorIdentity != source.identity {
                        self.recordedErrorIdentity = source.identity
                        MediaPlaybackTelemetry.recordError(
                            kind: mediaKind,
                            source: telemetrySource,
                            phase: "player_state",
                            error: nil,
                            sessionId: telemetrySessionId
                        )
                        MediaPlaybackTelemetry.logError(
                            kind: mediaKind,
                            source: telemetrySource,
                            mode: telemetryMode,
                            phase: "player_state",
                            error: nil,
                            message: "Unsupported media player state"
                        )
                    }
                    player.pause()
                    self.player = nil
                }
            }
        }
    }

    private func handlePresentationSize(
        width: CGFloat,
        height: CGFloat,
        callback: (@MainActor @Sendable (CGSize) -> Void)?
    ) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        callback?(CGSize(width: width, height: height))
    }

    func setFullScreen(_ fullScreen: Bool) {
        if fullScreen {
            suppressNextReturnedSurfaceDisappear = false
        }
        applyOwnership(fullScreen ? .willBeginFullScreen : .didEndFullScreen)
    }

    func setPictureInPicture(_ pictureInPicture: Bool) {
        if pictureInPicture {
            suppressNextReturnedSurfaceDisappear = false
        }
        applyOwnership(pictureInPicture ? .willStartPictureInPicture : .didStopPictureInPicture)
    }

    func setVisible(_ visible: Bool) {
        applyOwnership(.setVisible(visible))
    }

    @discardableResult
    func handleDisappear(source: MediaPlaybackDisappearSource = .playerSurface) -> Bool {
        // AVKit detaches the inline host and can make its collection-view cell
        // end display while presenting full-screen or PiP. Neither callback is
        // a real offscreen hide; keep the same player until native presentation
        // ends or a later unowned hide arrives.
        if ownership.isFullScreen
            || ownership.isPictureInPicture
            || ownership.isFullScreenTransitioning {
            return false
        }
        if source == .playerSurface, suppressNextReturnedSurfaceDisappear {
            // When dismissing the selected player, SwiftUI can deliver its
            // representable's onDisappear after AVKit's did-end completion. This
            // one callback still belongs to the native transition. Timeline
            // visibility and explicit recycle remain authoritative teardown paths.
            suppressNextReturnedSurfaceDisappear = false
            return false
        }
        setVisible(false)
        return true
    }

    func handleWillEndFullScreen() {
        applyOwnership(.willEndFullScreen)
    }

    func handleDidEndFullScreen(hostIsAttached _: Bool = true) {
        let returnsToVisibleSurface = ownership.isVisible && player != nil
        applyOwnership(.didEndFullScreen)
        suppressNextReturnedSurfaceDisappear = returnsToVisibleSurface
        // AVKit reports the player VC detached at dismiss completion even
        // when the inline wiki card is still on screen. handleDisappear
        // during fullscreen is a no-op. Hide/dismiss pauses transport;
        // prepareForRemoval() is the only path that drops the item.
    }

    func handleDidStopPictureInPicture(hostIsAttached _: Bool = true) {
        let returnsToVisibleSurface = ownership.isVisible && player != nil
        applyOwnership(.didStopPictureInPicture)
        suppressNextReturnedSurfaceDisappear = returnsToVisibleSurface
    }

    private func applyOwnership(_ event: MediaPlaybackTeardownPolicy.Event) {
        MediaPlaybackTeardownPolicy.apply(event, to: &ownership)
        teardownIfHiddenAndUnowned()
    }

    private func teardownIfHiddenAndUnowned() {
        // Full-screen and PiP can detach the inline view while AVKit still
        // owns playback. Hide/dismiss only pauses; dropping the item here
        // leaves the inline card on a spinner and makes tap-to-play a no-op.
        // Recycle and identity changes still call teardown() via
        // prepareForRemoval().
        guard ownership.shouldTeardown else { return }
        playbackSession?.pausePlayback()
        player?.pause()
    }

    func teardown(resetPreparedIdentity: Bool = true) {
        statusObservation?.invalidate()
        statusObservation = nil
        presentationSizeObservation?.invalidate()
        presentationSizeObservation = nil
        playbackSession?.teardown()
        playbackSession = nil
        player = nil
        isLoading = false
        ownership.isFullScreen = false
        ownership.isPictureInPicture = false
        ownership.isFullScreenTransitioning = false
        suppressNextReturnedSurfaceDisappear = false
#if DEBUG
        debugDidTeardownForTesting = true
#endif

        if resetPreparedIdentity {
            preparedIdentity = nil
            recordedStartIdentity = nil
            recordedErrorIdentity = nil
        }
    }
}

struct AuthenticatedMediaPlayerView: View {
    let source: AuthenticatedMediaSource
    var height: CGFloat = 260
    var cornerRadius: CGFloat = 10
    var autoplay = false
    var isActive = true
    var unavailableTitle = "Media preview unavailable"
    var unavailableSystemImage = "play.slash"
    var failureActionTitle: String? = nil
    var onFailureAction: (() -> Void)? = nil
    var onPresentationSize: (@MainActor @Sendable (CGSize) -> Void)? = nil
    var telemetrySource = "authenticated_media"
    var telemetryMode = "inline"
    var telemetrySessionId: String? = nil

    private let injectedModel: AuthenticatedMediaPlayerModel?
    @StateObject private var ownedModel = AuthenticatedMediaPlayerModel()

    init(
        source: AuthenticatedMediaSource,
        height: CGFloat = 260,
        cornerRadius: CGFloat = 10,
        autoplay: Bool = false,
        isActive: Bool = true,
        unavailableTitle: String = "Media preview unavailable",
        unavailableSystemImage: String = "play.slash",
        failureActionTitle: String? = nil,
        onFailureAction: (() -> Void)? = nil,
        onPresentationSize: (@MainActor @Sendable (CGSize) -> Void)? = nil,
        telemetrySource: String = "authenticated_media",
        telemetryMode: String = "inline",
        telemetrySessionId: String? = nil,
        model: AuthenticatedMediaPlayerModel? = nil
    ) {
        self.source = source
        self.height = height
        self.cornerRadius = cornerRadius
        self.autoplay = autoplay
        self.isActive = isActive
        self.unavailableTitle = unavailableTitle
        self.unavailableSystemImage = unavailableSystemImage
        self.failureActionTitle = failureActionTitle
        self.onFailureAction = onFailureAction
        self.onPresentationSize = onPresentationSize
        self.telemetrySource = telemetrySource
        self.telemetryMode = telemetryMode
        self.telemetrySessionId = telemetrySessionId
        injectedModel = model
    }

    var body: some View {
        AuthenticatedMediaPlayerSurface(
            source: source,
            height: height,
            cornerRadius: cornerRadius,
            autoplay: autoplay,
            isActive: isActive,
            unavailableTitle: unavailableTitle,
            unavailableSystemImage: unavailableSystemImage,
            failureActionTitle: failureActionTitle,
            onFailureAction: onFailureAction,
            onPresentationSize: onPresentationSize,
            telemetrySource: telemetrySource,
            telemetryMode: telemetryMode,
            telemetrySessionId: telemetrySessionId,
            model: injectedModel ?? ownedModel
        )
    }
}

private struct AuthenticatedMediaPlayerSurface: View {
    let source: AuthenticatedMediaSource
    var height: CGFloat
    var cornerRadius: CGFloat
    var autoplay: Bool
    var isActive: Bool
    var unavailableTitle: String
    var unavailableSystemImage: String
    var failureActionTitle: String?
    var onFailureAction: (() -> Void)?
    var onPresentationSize: (@MainActor @Sendable (CGSize) -> Void)?
    var telemetrySource: String
    var telemetryMode: String
    var telemetrySessionId: String?
    @ObservedObject var model: AuthenticatedMediaPlayerModel

    var body: some View {
#if DEBUG
        let _ = AuthenticatedMediaPlayerTesting.record(model)
#endif
        Group {
            if let player = model.player {
                AVPlayerViewControllerContainer(
                    player: player,
                    onFullScreenChange: { fullScreen in
                        if fullScreen {
                            model.setFullScreen(true)
                            WorkspaceMediaOverlayPost.begin()
                        }
                    },
                    onFullScreenWillEnd: { model.handleWillEndFullScreen() },
                    onFullScreenDidEnd: { attached in
                        model.handleDidEndFullScreen(hostIsAttached: attached)
                    },
                    onFullScreenTransitionFinished: {
                        WorkspaceMediaOverlayPost.end()
                    },
                    onPictureInPictureChange: { active in
                        if active {
                            model.setPictureInPicture(true)
                        }
                    },
                    onPictureInPictureDidStop: { attached in
                        model.handleDidStopPictureInPicture(hostIsAttached: attached)
                    }
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if let errorMessage = model.errorMessage {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.themeBgHighlight)
                    .frame(height: height)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: unavailableSystemImage)
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                            Text(unavailableTitle)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundStyle(.themeComment.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 12)
                            if let failureActionTitle, let onFailureAction {
                                AuthenticatedMediaFailureActionButton(
                                    title: failureActionTitle,
                                    action: onFailureAction
                                )
                            }
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.themeBgHighlight)
                    .frame(height: height)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .task(id: "\(source.identity)|\(isActive)") {
            model.setVisible(isActive)
            guard isActive else { return }
            model.prepare(
                source: source,
                autoplay: autoplay,
                telemetrySource: telemetrySource,
                telemetryMode: telemetryMode,
                telemetrySessionId: telemetrySessionId,
                onPresentationSize: onPresentationSize
            )
        }
        .onChange(of: isActive) { _, active in
            model.setVisible(active)
        }
        .onDisappear {
            model.handleDisappear()
        }
    }
}

struct AuthenticatedMediaFailureActionButton: UIViewRepresentable {
    let title: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> AuthenticatedMediaFailureActionView {
        let view = AuthenticatedMediaFailureActionView()
        view.apply(title: title, target: context.coordinator, action: #selector(Coordinator.tap))
        return view
    }

    func updateUIView(_ uiView: AuthenticatedMediaFailureActionView, context: Context) {
        context.coordinator.action = action
        uiView.apply(title: title, target: context.coordinator, action: #selector(Coordinator.tap))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AuthenticatedMediaFailureActionView,
        context: Context
    ) -> CGSize {
        uiView.intrinsicContentSize
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func tap() {
            action()
        }
    }
}

final class AuthenticatedMediaFailureActionView: UIView {
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "authenticated-media-failure-action"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "authenticated-media-failure-action"
        button.accessibilityTraits = .button
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        let fitting = button.intrinsicContentSize
        return CGSize(width: max(44, fitting.width + 16), height: max(44, fitting.height))
    }

    func apply(title: String, target: Any?, action: Selector) {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1)
            return outgoing
        }
        button.configuration = configuration
        button.accessibilityLabel = title
        button.removeTarget(nil, action: nil, for: .touchUpInside)
        button.addTarget(target, action: action, for: .touchUpInside)
        invalidateIntrinsicContentSize()
    }
}

@MainActor
final class AuthenticatedMediaPlayerViewController: AVPlayerViewController {
    private var playbackSession: AuthenticatedMediaPlaybackSession?
    private var statusObservation: NSKeyValueObservation?
    private var recordedStartIdentity: String?
    private var recordedErrorIdentity: String?

    func configure(
        source: AuthenticatedMediaSource,
        autoplay: Bool,
        telemetrySource: String = "authenticated_media",
        telemetrySessionId: String? = nil,
        startedNs: UInt64? = nil
    ) {
        statusObservation?.invalidate()
        statusObservation = nil
        recordedStartIdentity = nil
        recordedErrorIdentity = nil

        let playbackStartedNs = startedNs ?? DispatchTime.now().uptimeNanoseconds
        let mediaKind = MediaPlaybackTelemetry.mediaKind(
            mimeType: source.contentTypeHint,
            sourceFileExtension: source.sourceFileExtension
        )
        let playbackSession = AuthenticatedMediaPlaybackSession(source: source)
        self.playbackSession = playbackSession
        player = playbackSession.player
        showsPlaybackControls = true
        allowsPictureInPicturePlayback = true
        canStartPictureInPictureAutomaticallyFromInline = true
        entersFullScreenWhenPlaybackBegins = false
        exitsFullScreenWhenPlaybackEnds = false
        view.accessibilityIdentifier = "videoPlayer.native"
        statusObservation = playbackSession.player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    if self.recordedStartIdentity != source.identity {
                        self.recordedStartIdentity = source.identity
                        MediaPlaybackTelemetry.recordStart(
                            startedNs: playbackStartedNs,
                            kind: mediaKind,
                            source: telemetrySource,
                            mode: "fullscreen",
                            sessionId: telemetrySessionId
                        )
                    }
                case .failed:
                    if self.recordedErrorIdentity != source.identity {
                        self.recordedErrorIdentity = source.identity
                        MediaPlaybackTelemetry.recordError(
                            kind: mediaKind,
                            source: telemetrySource,
                            phase: "player_item",
                            error: item.error,
                            sessionId: telemetrySessionId
                        )
                        MediaPlaybackTelemetry.logError(
                            kind: mediaKind,
                            source: telemetrySource,
                            mode: "fullscreen",
                            phase: "player_item",
                            error: item.error
                        )
                    }
                case .unknown:
                    break
                @unknown default:
                    if self.recordedErrorIdentity != source.identity {
                        self.recordedErrorIdentity = source.identity
                        MediaPlaybackTelemetry.recordError(
                            kind: mediaKind,
                            source: telemetrySource,
                            phase: "player_state",
                            error: nil,
                            sessionId: telemetrySessionId
                        )
                        MediaPlaybackTelemetry.logError(
                            kind: mediaKind,
                            source: telemetrySource,
                            mode: "fullscreen",
                            phase: "player_state",
                            error: nil,
                            message: "Unsupported media player state"
                        )
                    }
                }
            }
        }
        if autoplay {
            playbackSession.player.play()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            statusObservation?.invalidate()
            statusObservation = nil
            playbackSession?.teardown()
            playbackSession = nil
            recordedStartIdentity = nil
            recordedErrorIdentity = nil
        }
    }
}

#if DEBUG
enum AuthenticatedMediaPlayerTesting {
    @MainActor static var resolvedModels: [ObjectIdentifier] = []

    @MainActor
    static func reset() {
        resolvedModels.removeAll()
    }

    @MainActor
    static func record(_ model: AuthenticatedMediaPlayerModel) {
        resolvedModels.append(ObjectIdentifier(model))
    }
}

enum AuthenticatedMediaResourceLoaderTesting {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastCancelRetained = false

    /// Set when `cancelAll()` keeps the URLSession delegate alive because a
    /// CFNetwork task is still outstanding. Tests read this instead of racing
    /// `didComplete` on the session queue.
    static var lastCancelRetainedSelfForInFlightCallbacks: Bool {
        get { lock.withLock { lastCancelRetained } }
        set { lock.withLock { lastCancelRetained = newValue } }
    }
}

final class AuthenticatedMediaResourceLoaderLifetimeProbe: @unchecked Sendable {
    private weak var loader: AuthenticatedMediaResourceLoader?

    fileprivate init(loader: AuthenticatedMediaResourceLoader) {
        self.loader = loader
    }

    var isAlive: Bool { loader != nil }

    var retainsSelfUntilNetworkIdle: Bool {
        loader?.debugRetainsSelfUntilNetworkIdle ?? false
    }
}

extension AuthenticatedMediaResourceLoader {
    var debugRetainsSelfUntilNetworkIdle: Bool {
        lock.withLock { networkLifetime != nil }
    }

    func debugStartInFlightDataTask(url: URL) {
        let task = session.dataTask(with: url)
        lock.lock()
        liveTaskIds.insert(task.taskIdentifier)
        tasksByRequestId[ObjectIdentifier(task)] = task
        lock.unlock()
        task.resume()
    }
}

extension AuthenticatedMediaPlaybackSession {
    func debugStartInFlightResourceRequest(url: URL) {
        loader.debugStartInFlightDataTask(url: url)
    }

    func debugResourceLoaderLifetimeProbe() -> AuthenticatedMediaResourceLoaderLifetimeProbe {
        AuthenticatedMediaResourceLoaderLifetimeProbe(loader: loader)
    }

    var debugRetainsResourceLoaderUntilNetworkIdle: Bool {
        loader.debugRetainsSelfUntilNetworkIdle
    }
}

extension AuthenticatedMediaPlayerModel {
    func debugForceFailureForTesting(_ message: String) {
        errorMessage = message
        isLoading = false
        player = nil
    }

    func debugInstallStandalonePlayerForTesting() -> AVPlayer {
        let player = AVPlayer()
        self.player = player
        debugDidTeardownForTesting = false
        return player
    }
}
#endif
