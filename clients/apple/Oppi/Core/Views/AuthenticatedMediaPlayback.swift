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
    /// Inclusive end of a finite AV loading request. Nil when AV asked for the rest.
    let requestedEnd: Int64?

    init(start: Int64, end: Int64?, continuesToEnd: Bool = false, requestedEnd: Int64? = nil) {
        self.start = start
        self.end = end
        self.continuesToEnd = continuesToEnd
        self.requestedEnd = requestedEnd
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
        Self.make(
            currentOffset: offset,
            requestedOffset: offset,
            requestedLength: requestedLength,
            requestsAllDataToEndOfResource: requestsAllDataToEndOfResource
        )
    }

    /// `requestedEnd` is always `requestedOffset + requestedLength - 1` for a
    /// finite AV request. `currentOffset` only reduces remaining bytes.
    static func make(
        currentOffset: Int64,
        requestedOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool
    ) -> AuthenticatedMediaRequestedRange {
        let origin = max(requestedOffset, 0)
        let start = max(currentOffset, origin)
        let wantsRest = requestsAllDataToEndOfResource
            || requestedLength <= 0
            || requestedLength == Int.max
        let finiteEnd: Int64?
        if wantsRest {
            finiteEnd = nil
        } else {
            finiteEnd = AuthenticatedMediaRangeContinuation.inclusiveEnd(
                start: origin,
                length: Int64(requestedLength)
            ) ?? Int64.max
        }
        if let chunk = AuthenticatedMediaRangeContinuation.chunk(
            start: start,
            continueToEnd: wantsRest,
            requestedEnd: finiteEnd
        ) {
            return chunk
        }
        return AuthenticatedMediaRequestedRange(
            start: start,
            end: start,
            continuesToEnd: wantsRest,
            requestedEnd: finiteEnd
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
    static func nextOffset(
        afterEnd: Int64,
        totalLength: Int64?,
        requestedEnd: Int64? = nil
    ) -> Int64? {
        guard let next = adding(afterEnd, 1) else { return nil }
        if let requestedEnd, next > requestedEnd {
            return nil
        }
        if let totalLength {
            return next < totalLength ? next : nil
        }
        return requestedEnd == nil ? nil : next
    }

    /// Next 1 MiB-or-smaller HTTP range. Finite requests stop at `requestedEnd`;
    /// open-ended requests keep `continuesToEnd` and never enlarge the cap.
    static func nextChunk(
        offset: Int64,
        continueToEnd: Bool,
        requestedEnd: Int64?
    ) -> AuthenticatedMediaRequestedRange? {
        chunk(start: max(offset, 0), continueToEnd: continueToEnd, requestedEnd: requestedEnd)
    }

    /// Inclusive end of `length` bytes starting at `start`, or nil on overflow.
    static func inclusiveEnd(start: Int64, length: Int64) -> Int64? {
        guard length > 0 else { return nil }
        guard let sum = adding(start, length) else { return nil }
        return sum - 1
    }

    /// `requestedEnd - offset + 1`, saturating at `Int64.max` without wrapping.
    static func remainingBytes(from offset: Int64, to requestedEnd: Int64) -> Int64? {
        guard offset >= 0, offset <= requestedEnd else { return nil }
        let (diff, overflow) = requestedEnd.subtractingReportingOverflow(offset)
        if overflow { return nil }
        if let remaining = adding(diff, 1) {
            return remaining
        }
        return Int64.max
    }

    static func chunk(
        start: Int64,
        continueToEnd: Bool,
        requestedEnd: Int64?
    ) -> AuthenticatedMediaRequestedRange? {
        let remaining: Int64
        if continueToEnd {
            remaining = AuthenticatedMediaRequestedRange.maxChunkLength
        } else {
            guard let requestedEnd,
                  let finiteRemaining = remainingBytes(from: start, to: requestedEnd),
                  finiteRemaining > 0 else {
                return nil
            }
            remaining = finiteRemaining
        }
        let length = min(max(remaining, 1), AuthenticatedMediaRequestedRange.maxChunkLength)
        guard let end = inclusiveEnd(start: start, length: length) else {
            return AuthenticatedMediaRequestedRange(
                start: start,
                end: nil,
                continuesToEnd: continueToEnd,
                requestedEnd: requestedEnd
            )
        }
        let cappedEnd = requestedEnd.map { min(end, $0) } ?? end
        return AuthenticatedMediaRequestedRange(
            start: start,
            end: cappedEnd,
            continuesToEnd: continueToEnd,
            requestedEnd: requestedEnd
        )
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
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

/// Body length is checked against the **response** Content-Range span, not the
/// requested HTTP chunk. A valid shorter 206 must continue at the next actual
/// byte rather than fail or skip to the advertised request end.
enum AuthenticatedMediaResponseBody {
    static let shorterThanContentRange = "Ranged media response body shorter than Content-Range"
    static let longerThanContentRange = "Ranged media response body larger than Content-Range"

    static func shortfallErrorMessage(
        receivedByteCount: Int64,
        rangeStart: Int64,
        advertisedEnd: Int64?
    ) -> String? {
        guard let expected = expectedByteCount(rangeStart: rangeStart, advertisedEnd: advertisedEnd),
              expected > 0 else {
            return nil
        }
        return receivedByteCount >= expected ? nil : shorterThanContentRange
    }

    static func overrunErrorMessage(
        receivedByteCount: Int64,
        rangeStart: Int64,
        advertisedEnd: Int64?
    ) -> String? {
        guard let expected = expectedByteCount(rangeStart: rangeStart, advertisedEnd: advertisedEnd),
              expected > 0 else {
            return nil
        }
        return receivedByteCount > expected ? longerThanContentRange : nil
    }

    /// Bytes of `incoming` that stay inside the advertised Content-Range.
    /// Extra bytes are not forwarded.
    static func allowedForwardableByteCount(
        receivedByteCount: Int64,
        incomingByteCount: Int,
        rangeStart: Int64,
        advertisedEnd: Int64?
    ) -> Int {
        guard incomingByteCount > 0 else { return 0 }
        guard let expected = expectedByteCount(rangeStart: rangeStart, advertisedEnd: advertisedEnd),
              expected > 0 else {
            return incomingByteCount
        }
        let remaining = expected - receivedByteCount
        if remaining <= 0 { return 0 }
        if remaining >= Int64(incomingByteCount) { return incomingByteCount }
        return Int(remaining)
    }

    private static func expectedByteCount(rangeStart: Int64, advertisedEnd: Int64?) -> Int64? {
        guard let advertisedEnd else { return nil }
        return AuthenticatedMediaRangeContinuation.remainingBytes(
            from: rangeStart,
            to: advertisedEnd
        )
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
        var requestedEnd: Int64?
        var totalLength: Int64?
        var deliveredEnd: Int64?
        var receivedByteCount: Int64 = 0
        var cancelled = false
        var responseError: Error?

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            requestedRange: AuthenticatedMediaRequestedRange?
        ) {
            self.loadingRequest = loadingRequest
            self.requestedRange = requestedRange
            self.continueToEnd = requestedRange?.continuesToEnd ?? false
            self.requestedEnd = requestedRange?.requestedEnd
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
            let requestedOffset = dataRequest.requestedOffset
            let currentOffset = max(dataRequest.currentOffset, requestedOffset)
            requestedRange = AuthenticatedMediaRequestedRange.make(
                currentOffset: currentOffset,
                requestedOffset: requestedOffset,
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
        if let shortfall = contentLengthShortfallError(http, context: context) {
            context.responseError = shortfall
            completionHandler(.cancel)
            return
        }
        if let overrun = contentLengthOverrunError(http, context: context) {
            context.responseError = overrun
            completionHandler(.cancel)
            return
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
        let advertisedEnd = context.deliveredEnd ?? context.requestedRange?.end
        let allowed = AuthenticatedMediaResponseBody.allowedForwardableByteCount(
            receivedByteCount: context.receivedByteCount,
            incomingByteCount: data.count,
            rangeStart: context.requestedRange?.start ?? 0,
            advertisedEnd: advertisedEnd
        )
        if allowed < data.count {
            context.responseError = mediaError(AuthenticatedMediaResponseBody.longerThanContentRange)
        }
        guard allowed > 0 else { return }
        let forwarded = allowed == data.count ? data : Data(data.prefix(allowed))
        context.receivedByteCount += Int64(allowed)
        context.loadingRequest.dataRequest?.respond(with: forwarded)
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
            } else if let shortfall = shortfallError(context) {
                context.loadingRequest.finishLoading(with: shortfall)
            } else if context.continueToEnd || context.requestedEnd != nil,
                      let deliveredEnd = actualDeliveredEnd(context),
                      let nextOffset = AuthenticatedMediaRangeContinuation.nextOffset(
                        afterEnd: deliveredEnd,
                        totalLength: context.totalLength,
                        requestedEnd: context.requestedEnd
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
        guard let nextRange = AuthenticatedMediaRangeContinuation.nextChunk(
            offset: offset,
            continueToEnd: context.continueToEnd,
            requestedEnd: context.requestedEnd
        ) else {
            if !context.loadingRequest.isCancelled, !context.loadingRequest.isFinished {
                context.loadingRequest.finishLoading()
            }
            return
        }
        let loadingRequest = context.loadingRequest
        let continueToEnd = context.continueToEnd
        let requestedEnd = context.requestedEnd
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
            if self.isAbandoned(loadingRequest) {
                return
            }
            let nextContext = LoadingContext(
                loadingRequest: loadingRequest,
                requestedRange: nextRange
            )
            nextContext.continueToEnd = continueToEnd
            nextContext.requestedEnd = requestedEnd
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

    private func actualDeliveredEnd(_ context: LoadingContext) -> Int64? {
        if let dataRequest = context.loadingRequest.dataRequest {
            let current = dataRequest.currentOffset
            let start = context.requestedRange?.start ?? dataRequest.requestedOffset
            if current > start {
                return current - 1
            }
        }
        guard let start = context.requestedRange?.start, context.receivedByteCount > 0 else {
            return nil
        }
        return AuthenticatedMediaRangeContinuation.inclusiveEnd(
            start: start,
            length: context.receivedByteCount
        )
    }

    private func contentLengthShortfallError(
        _ http: HTTPURLResponse,
        context: LoadingContext
    ) -> Error? {
        guard context.loadingRequest.dataRequest != nil else { return nil }
        let contentLength = http.expectedContentLength
        guard contentLength >= 0 else { return nil }
        return responseSpanShortfall(context, receivedByteCount: contentLength)
    }

    private func contentLengthOverrunError(
        _ http: HTTPURLResponse,
        context: LoadingContext
    ) -> Error? {
        guard context.loadingRequest.dataRequest != nil else { return nil }
        let contentLength = http.expectedContentLength
        guard contentLength >= 0 else { return nil }
        return responseSpanOverrun(context, receivedByteCount: contentLength)
    }

    private func shortfallError(_ context: LoadingContext) -> Error? {
        guard context.loadingRequest.dataRequest != nil else { return nil }
        return responseSpanShortfall(context, receivedByteCount: context.receivedByteCount)
    }

    private func responseSpanShortfall(_ context: LoadingContext, receivedByteCount: Int64) -> Error? {
        let start = context.requestedRange?.start ?? 0
        guard let message = AuthenticatedMediaResponseBody.shortfallErrorMessage(
            receivedByteCount: receivedByteCount,
            rangeStart: start,
            advertisedEnd: context.deliveredEnd
        ) else {
            return nil
        }
        return mediaError(message)
    }

    private func responseSpanOverrun(_ context: LoadingContext, receivedByteCount: Int64) -> Error? {
        let start = context.requestedRange?.start ?? 0
        let advertisedEnd = context.deliveredEnd ?? context.requestedRange?.end
        guard let message = AuthenticatedMediaResponseBody.overrunErrorMessage(
            receivedByteCount: receivedByteCount,
            rangeStart: start,
            advertisedEnd: advertisedEnd
        ) else {
            return nil
        }
        return mediaError(message)
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

/// AVKit (including PiP) controls the player directly, not just our SwiftUI
/// buttons. Admit every transport start on the capture owner's actor before
/// AVPlayer sees it. Keep KVO below as a safety net for system-driven changes.
private final class CaptureAwareMediaPlayer: AVPlayer {
    override nonisolated func play() {
        admitPlayback { super.play() }
    }

    override nonisolated func playImmediately(atRate rate: Float) {
        guard rate != 0 else { super.playImmediately(atRate: rate); return }
        admitPlayback { super.playImmediately(atRate: rate) }
    }

    override nonisolated var rate: Float {
        get { super.rate }
        set {
            guard newValue != 0 else { super.rate = 0; return }
            admitPlayback { super.rate = newValue }
        }
    }

    override nonisolated func setRate(_ rate: Float, time: CMTime, atHostTime hostTime: CMTime) {
        guard rate != 0 else { super.setRate(rate, time: time, atHostTime: hostTime); return }
        admitPlayback { super.setRate(rate, time: time, atHostTime: hostTime) }
    }

    nonisolated private func admitPlayback(_ request: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if MediaPlaybackAudioSession.prepareSharedSession() { request() }
            }
        } else {
            // AVPlayer permits background transport calls. Hop rather than
            // synchronously blocking an AVFoundation thread on the main queue.
            Task { @MainActor in
                if MediaPlaybackAudioSession.prepareSharedSession() { request() }
            }
        }
    }
}

@MainActor
final class AuthenticatedMediaPlaybackSession {
    let player: AVPlayer

    private let loader: AuthenticatedMediaResourceLoader
    private let asset: AVURLAsset
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var captureAcquisitionObserver: UUID?
    private var hasStartedPlaying = false
    private var lastStallLogAt: TimeInterval = 0
    private var lastUnmutedVolume: Float = MediaPlaybackMutePolicy.defaultUnmutedVolume

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
        player = CaptureAwareMediaPlayer(playerItem: item)
        captureAcquisitionObserver = VoiceInputManager.shared.observeCaptureAcquisition { [weak player] in
            player?.pause()
        }
        // Custom resource-loader assets should not wait to minimize stalling;
        // AVPlayer cannot see the real network buffer behind oppi-media://.
        player.automaticallyWaitsToMinimizeStalling = false
        // Mounting/render-ahead is not playback intent. In particular it must
        // not replace a live dictation route with .playback.
        observeMute()
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

    private func observeMute() {
        applyMuteOutput(isMuted: player.isMuted, currentVolume: player.volume)
        muteObservation = player.observe(\.isMuted, options: [.new]) { [weak self] player, _ in
            let isMuted = player.isMuted
            let volume = player.volume
            Task { @MainActor in
                self?.applyMuteOutput(isMuted: isMuted, currentVolume: volume)
            }
        }
    }

    private func applyMuteOutput(isMuted: Bool, currentVolume: Float) {
        let applied = MediaPlaybackMutePolicy.appliedVolume(
            isMuted: isMuted,
            currentVolume: currentVolume,
            lastUnmutedVolume: lastUnmutedVolume
        )
        lastUnmutedVolume = applied.lastUnmutedVolume
        if player.volume != applied.volume {
            player.volume = applied.volume
        }
    }

    private func handleTimeControlChange(_ status: AVPlayer.TimeControlStatus, kind: String) {
        if status == .playing || status == .waitingToPlayAtSpecifiedRate {
            guard MediaPlaybackAudioSession.prepareSharedSession() else {
                player.pause()
                return
            }
        }
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
        if let captureAcquisitionObserver {
            VoiceInputManager.shared.removeCaptureAcquisitionObserver(captureAcquisitionObserver)
            self.captureAcquisitionObserver = nil
        }
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        muteObservation?.invalidate()
        muteObservation = nil
        Self.discardItem(player)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        loader.cancelAll()
    }

    deinit {
        if let captureAcquisitionObserver {
            Task { @MainActor in
                VoiceInputManager.shared.removeCaptureAcquisitionObserver(captureAcquisitionObserver)
            }
        }
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

/// Video playback must own the media route. Dictation leaves `.playAndRecord`
/// plus HFP selected after `setActive(false)`, and AVKit then binds mute and
/// volume to call audio instead of AirPods media volume.
enum MediaPlaybackAudioSession {
    static let category: AVAudioSession.Category = .playback
    static let mode: AVAudioSession.Mode = .default
    static let options = AVAudioSession.CategoryOptions()

    static func needsPlaybackCategory(_ current: AVAudioSession.Category) -> Bool {
        current != category
    }

    static func prepare(
        currentCategory: AVAudioSession.Category,
        setCategory: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) throws -> Void
    ) throws {
        guard needsPlaybackCategory(currentCategory) else { return }
        try setCategory(category, mode, options)
    }

    @MainActor
    @discardableResult
    static func prepareSharedSession() -> Bool {
        guard !VoiceInputManager.shared.ownsCaptureAudioSession else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try prepare(currentCategory: session.category) { category, mode, options in
                try session.setCategory(category, mode: mode, options: options)
            }
            return true
        } catch {
            ClientLog.warning(
                "MediaPlayback",
                "Could not configure playback audio session",
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }
}

/// `AVPlayer.isMuted` can leave Bluetooth output audible. Zero volume when
/// muted, and restore the previous volume on unmute unless AVKit already did.
enum MediaPlaybackMutePolicy {
    static let defaultUnmutedVolume: Float = 1

    static func appliedVolume(
        isMuted: Bool,
        currentVolume: Float,
        lastUnmutedVolume: Float
    ) -> (volume: Float, lastUnmutedVolume: Float) {
        if isMuted {
            let preserved = currentVolume > 0 ? currentVolume : lastUnmutedVolume
            return (0, preserved > 0 ? preserved : defaultUnmutedVolume)
        }
        if currentVolume > 0 {
            return (currentVolume, currentVolume)
        }
        let restored = lastUnmutedVolume > 0 ? lastUnmutedVolume : defaultUnmutedVolume
        return (restored, restored)
    }
}

@MainActor
final class AuthenticatedMediaPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentTime: TimeInterval = 0

    private var playbackSession: AuthenticatedMediaPlaybackSession?
    private var statusObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private weak var timeObservedPlayer: AVPlayer?
    private var preparedIdentity: String?
    private var recordedStartIdentity: String?
    private var recordedErrorIdentity: String?
    private var ownership = MediaPlaybackTeardownPolicy.Ownership()
    private var suppressNextReturnedSurfaceDisappear = false
#if DEBUG
    var debugDidTeardownForTesting = false
    var debugIsVisibleForTesting: Bool { ownership.isVisible }
    var debugIsFullScreenForTesting: Bool { ownership.isFullScreen }
    var debugIsPictureInPictureForTesting: Bool { ownership.isPictureInPicture }
    var debugPlaybackProbeForTesting: String {
        let item = player?.currentItem
        let itemLabel: String
        switch item?.status {
        case .readyToPlay: itemLabel = "ready"
        case .failed: itemLabel = "failed"
        case .unknown: itemLabel = "unknown"
        case .none: itemLabel = "nil"
        @unknown default: itemLabel = "other"
        }
        let rate = player?.rate ?? 0
        let tcs: String
        switch player?.timeControlStatus {
        case .playing: tcs = "playing"
        case .paused: tcs = "paused"
        case .waitingToPlayAtSpecifiedRate: tcs = "waiting"
        case .none: tcs = "none"
        @unknown default: tcs = "other"
        }
        let waiting = player?.reasonForWaitingToPlay?.rawValue ?? "none"
        let seconds = player?.currentTime().seconds ?? currentTime
        let timeLabel = seconds.isFinite ? String(format: "%.3f", seconds) : "nan"
        let err = item?.error == nil ? "none" : "yes"
        let mid = String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16)
        let pid = player.map { String(UInt(bitPattern: ObjectIdentifier($0)), radix: 16) } ?? "nil"
        return [
            "item=\(itemLabel)",
            "rate=\(String(format: "%.2f", rate))",
            "tcs=\(tcs)",
            "wait=\(waiting)",
            "time=\(timeLabel)",
            "vis=\(ownership.isVisible ? 1 : 0)",
            "fs=\(ownership.isFullScreen ? 1 : 0)",
            "pip=\(ownership.isPictureInPicture ? 1 : 0)",
            "err=\(err)",
            "mid=\(mid)",
            "pid=\(pid)",
        ].joined(separator: " ")
    }
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
        currentTime = 0
        startTimeObserver(on: player)

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
        stopTimeObserver()
        playbackSession?.teardown()
        playbackSession = nil
        player = nil
        currentTime = 0
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

    private func startTimeObserver(on player: AVPlayer) {
        stopTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                self?.currentTime = seconds
            }
        }
        timeObservedPlayer = player
    }

    private func stopTimeObserver() {
        if let timeObserver, let timeObservedPlayer {
            timeObservedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeObservedPlayer = nil
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
    var timedText: TimedText.LoadResult = .empty

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
        model: AuthenticatedMediaPlayerModel? = nil,
        timedText: TimedText.LoadResult = .empty
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
        self.timedText = timedText
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
            timedText: timedText,
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
    var timedText: TimedText.LoadResult
    @ObservedObject var model: AuthenticatedMediaPlayerModel
    @State private var selectedTrackIndex: Int?

    var body: some View {
#if DEBUG
        let _ = AuthenticatedMediaPlayerTesting.record(model, source: source)
#endif
        Group {
            if let player = model.player {
                AVPlayerViewControllerContainer(
                    player: player,
                    playbackModel: model,
                    captionText: currentCaptionText,
                    captionTracks: timedText.tracks,
                    selectedCaptionTrackIndex: resolvedTrackIndex,
                    onSelectCaptionTrack: { index in
                        selectedTrackIndex = index
                    },
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
        .onChange(of: timedText) { _, _ in
            selectedTrackIndex = timedText.selectedIndex
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

    private var resolvedTrackIndex: Int {
        selectedTrackIndex ?? timedText.selectedIndex
    }

    private var currentCaptionText: String? {
        guard timedText.tracks.indices.contains(resolvedTrackIndex) else { return nil }
        return TimedText.currentCue(
            in: timedText.tracks[resolvedTrackIndex].cues,
            at: model.currentTime
        )?.text
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
/// DEBUG-only currentTime oracle bound to the receiving AVPlayerViewController.
/// time/pid/rate/fs come from that controller's player, not by copying the
/// initiating model's probe string onto unrelated controllers.
@MainActor
enum AuthenticatedMediaE2EPlaybackProbe {
    static let identifier = "e2e.video.playback"
    static var testingForceEnabled = false

    static var isEnabled: Bool {
        if testingForceEnabled { return true }
        let env = ProcessInfo.processInfo.environment
        return env["PI_E2E_INVITE_URL"] != nil || env["OPPI_E2E_DIAGNOSTICS"] == "1"
    }

    static func install(
        on controller: AVPlayerViewController,
        model: AuthenticatedMediaPlayerModel?
    ) {
        guard isEnabled else { return }
        controller.view.accessibilityIdentifier = "videoPlayer.native"
        let boundModel = modelOwning(controller.player, candidate: model)
        guard let host = controller.contentOverlayView ?? controller.view else { return }
        let probe = attachedProbe(on: host) ?? addProbe(to: host)
        probe.controller = controller
        probe.model = boundModel
        probe.playerView = controller.view
        probe.refresh()
        probe.startIfNeeded()
    }

    /// AVKit moves the player's content overlay into its fullscreen container;
    /// it need not present another AVPlayerViewController. Observe the original
    /// controller's actual player and verify that its overlay reached the
    /// transition destination, rather than searching unrelated controllers.
    static func bindPresentedFullscreen(
        from controller: AVPlayerViewController,
        destination: UIViewController?
    ) {
        guard isEnabled else { return }
        for probe in probeViews(on: controller) {
            probe.fullscreenView = destination?.view
            probe.refresh()
        }
    }

    static func uninstall(from controller: AVPlayerViewController) {
        let probes = probeViews(on: controller)
        for probe in probes {
            probe.stop()
            probe.removeFromSuperview()
        }
        if controller.view.accessibilityIdentifier == "videoPlayer.native" {
            controller.view.accessibilityValue = nil
        }
    }

    static func debugProbeValue(on controller: AVPlayerViewController) -> String? {
        if let probe = probeViews(on: controller).first {
            probe.refresh()
            return probe.accessibilityValue
        }
        return controller.view.accessibilityValue
    }

    static func debugIsDisplayLinkActive(on controller: AVPlayerViewController) -> Bool {
        probeViews(on: controller).contains { $0.isDisplayLinkActive }
    }

    static func debugHasProbeView(on controller: AVPlayerViewController) -> Bool {
        !probeViews(on: controller).isEmpty
    }

    private static func modelOwning(
        _ player: AVPlayer?,
        candidate: AuthenticatedMediaPlayerModel?
    ) -> AuthenticatedMediaPlayerModel? {
        guard let candidate else { return nil }
        guard let player, candidate.player === player else { return nil }
        return candidate
    }

    private static func probeViews(on controller: AVPlayerViewController) -> [ProbeView] {
        let overlayViews = controller.contentOverlayView?.subviews.compactMap { $0 as? ProbeView } ?? []
        let viewProbes = controller.view.subviews.compactMap { $0 as? ProbeView }
        return overlayViews + viewProbes
    }

    private static func attachedProbe(on overlay: UIView) -> ProbeView? {
        overlay.subviews.compactMap { $0 as? ProbeView }.first
    }

    private static func addProbe(to overlay: UIView) -> ProbeView {
        let probe = ProbeView()
        overlay.addSubview(probe)
        probe.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            probe.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            probe.topAnchor.constraint(equalTo: overlay.topAnchor),
            probe.widthAnchor.constraint(equalToConstant: 8),
            probe.heightAnchor.constraint(equalToConstant: 8),
        ])
        return probe
    }

    fileprivate static func probeValue(
        player: AVPlayer?,
        model: AuthenticatedMediaPlayerModel?,
        reportsFullScreen: Bool
    ) -> String {
        let item = player?.currentItem
        let itemLabel: String
        switch item?.status {
        case .readyToPlay: itemLabel = "ready"
        case .failed: itemLabel = "failed"
        case .unknown: itemLabel = "unknown"
        case .none: itemLabel = "nil"
        @unknown default: itemLabel = "other"
        }
        let rate = player?.rate ?? 0
        let tcs: String
        switch player?.timeControlStatus {
        case .playing: tcs = "playing"
        case .paused: tcs = "paused"
        case .waitingToPlayAtSpecifiedRate: tcs = "waiting"
        case .none: tcs = "none"
        @unknown default: tcs = "other"
        }
        let waiting = player?.reasonForWaitingToPlay?.rawValue ?? "none"
        let seconds = player?.currentTime().seconds ?? 0
        let timeLabel = seconds.isFinite ? String(format: "%.3f", seconds) : "nan"
        let err = item?.error == nil ? "none" : "yes"
        let ownedModel = modelOwning(player, candidate: model)
        let mid = ownedModel.map { String(UInt(bitPattern: ObjectIdentifier($0)), radix: 16) } ?? "none"
        let pid = player.map { String(UInt(bitPattern: ObjectIdentifier($0)), radix: 16) } ?? "nil"
        let vis: Int
        if let ownedModel {
            vis = ownedModel.debugIsVisibleForTesting ? 1 : 0
        } else {
            vis = 0
        }
        let fs = reportsFullScreen ? 1 : 0
        let pip = ownedModel?.debugIsPictureInPictureForTesting == true ? 1 : 0
        return [
            "item=\(itemLabel)",
            "rate=\(String(format: "%.2f", rate))",
            "tcs=\(tcs)",
            "wait=\(waiting)",
            "time=\(timeLabel)",
            "vis=\(vis)",
            "fs=\(fs)",
            "pip=\(pip)",
            "err=\(err)",
            "mid=\(mid)",
            "pid=\(pid)",
        ].joined(separator: " ")
    }

    private final class ProbeView: UIView {
        weak var model: AuthenticatedMediaPlayerModel?
        weak var controller: AVPlayerViewController?
        weak var playerView: UIView?
        weak var fullscreenView: UIView?
        private nonisolated(unsafe) var displayLink: CADisplayLink?
        private let displayLinkProxy = DisplayLinkProxy()

        var isDisplayLinkActive: Bool { displayLink != nil }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = AuthenticatedMediaE2EPlaybackProbe.identifier
            backgroundColor = .clear
            alpha = 0.01
            displayLinkProxy.owner = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func startIfNeeded() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 5, maximum: 10, preferred: 5)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func refresh() {
            let player = controller?.player
            let boundModel = AuthenticatedMediaE2EPlaybackProbe.modelOwning(player, candidate: model)
            if model != nil, boundModel == nil {
                model = nil
            }
            let resolvedFullscreen = fullscreenView.map {
                $0.window != nil && isDescendant(of: $0)
            } ?? false
            let value = AuthenticatedMediaE2EPlaybackProbe.probeValue(
                player: player,
                model: boundModel,
                reportsFullScreen: resolvedFullscreen
            )
            accessibilityLabel = value
            accessibilityValue = value
            playerView?.accessibilityValue = value
            if resolvedFullscreen, let fullscreenView {
                fullscreenView.accessibilityIdentifier = "videoPlayer.native"
                fullscreenView.accessibilityValue = value
            }
        }

        override func removeFromSuperview() {
            stop()
            super.removeFromSuperview()
        }

        nonisolated deinit {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var owner: ProbeView?

        @objc func tick(_ link: CADisplayLink) {
            owner?.refresh()
        }
    }
}

enum AuthenticatedMediaPlayerTesting {
    @MainActor static var resolvedModels: [ObjectIdentifier] = []
    /// Empty means recording is off. Parallel Swift Testing suites can mount
    /// other players in the same process; only the opted-in source is kept.
    @MainActor private static var allowedSourceIdentities: Set<String> = []

    @MainActor
    static func reset(allowingSource source: AuthenticatedMediaSource? = nil) {
        resolvedModels.removeAll()
        if let source {
            allowedSourceIdentities = [source.identity]
        } else {
            allowedSourceIdentities.removeAll()
        }
    }

    @MainActor
    static func record(_ model: AuthenticatedMediaPlayerModel, source: AuthenticatedMediaSource) {
        guard allowedSourceIdentities.contains(source.identity) else { return }
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
