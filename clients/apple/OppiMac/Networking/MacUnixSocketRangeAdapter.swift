@preconcurrency import AVFoundation
import Foundation
import OSLog
import UniformTypeIdentifiers

private let mediaLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacUnixSocketRangeAdapter"
)

/// Byte range for one Unix-socket media GET.
///
/// AVPlayer often asks for the rest of the resource with `requestedLength ==
/// Int.max`. A closed `bytes=N-9223372036854775806` header is not a JS-safe
/// integer, so the Oppi server rejects it as HTTP 416. Cap each GET to 1 MB.
struct MacUnixSocketRequestedRange: Equatable, Sendable {
    static let maxChunkLength: Int64 = 1_048_576

    let start: Int64
    let end: Int64?
    let continuesToEnd: Bool

    init(start: Int64, end: Int64?, continuesToEnd: Bool = false) {
        self.start = start
        self.end = end
        self.continuesToEnd = continuesToEnd
    }

    static func make(
        offset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool
    ) -> MacUnixSocketRequestedRange {
        let start = max(offset, 0)
        let wantsRest = requestsAllDataToEndOfResource
            || requestedLength <= 0
            || requestedLength == Int.max
        let requested = wantsRest ? Self.maxChunkLength : Int64(requestedLength)
        let length = min(max(requested, 1), Self.maxChunkLength)
        if start > Int64.max - length {
            return MacUnixSocketRequestedRange(start: start, end: nil, continuesToEnd: wantsRest)
        }
        return MacUnixSocketRequestedRange(
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

enum MacUnixSocketRangeContinuation {
    static func nextOffset(afterEnd: Int64, totalLength: Int64?) -> Int64? {
        guard let totalLength else { return nil }
        let next = afterEnd + 1
        return next < totalLength ? next : nil
    }
}

enum MacUnixSocketMediaResponseValidator {
    static func errorMessage(
        statusCode: Int,
        requestedRange: MacUnixSocketRequestedRange?,
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

    private static func parseContentRange(_ header: String?) -> MacUnixSocketRequestedRange? {
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
        return MacUnixSocketRequestedRange(start: start, end: end)
    }
}

enum MacUnixSocketMediaError: Error, Equatable {
    case emptyAuthorization
    case http(String)
}

enum MacUnixSocketMediaPath {
    static func workspaceRaw(
        workspaceID: String,
        filePath: String,
        worktreeId: String? = nil
    ) -> String? {
        guard let path = encode(prefix: ["workspaces", workspaceID, "raw"], filePath: filePath) else {
            return nil
        }
        return appendWorktreeQuery(path, worktreeId: worktreeId)
    }

    static func appendWorktreeQuery(_ path: String, worktreeId: String?) -> String {
        guard let worktreeId = FileViewerPlan.normalizedWorktreeId(worktreeId) else { return path }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/&=?#")
        let encoded = worktreeId.addingPercentEncoding(withAllowedCharacters: allowed) ?? worktreeId
        return "\(path)?worktreeId=\(encoded)"
    }

    static func sessionRaw(workspaceID: String, sessionID: String, filePath: String) -> String? {
        encode(prefix: ["workspaces", workspaceID, "sessions", sessionID, "raw"], filePath: filePath)
    }

    static func sessionAttachment(
        sessionID: String,
        attachmentID: String,
        scope: SessionRouteScope? = nil
    ) -> String? {
        let route = scope == .control ? "control-sessions" : "sessions"
        return encode(prefix: [route, sessionID, "attachments", attachmentID], filePath: nil)
    }

    private static func encode(prefix: [String], filePath: String?) -> String? {
        var segments = prefix
        if let filePath {
            let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            segments.append(
                contentsOf: trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            )
        }
        let encoded = segments.compactMap(encodePathSegment)
        guard encoded.count == segments.count, !encoded.isEmpty else { return nil }
        return "/" + encoded.joined(separator: "/")
    }

    private static func encodePathSegment(_ segment: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%+?#&")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

enum MacMediaMimeType {
    static func hint(forPathExtension pathExtension: String?) -> String? {
        switch (pathExtension ?? "").lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "caf": return "audio/x-caf"
        case "ogg", "oga": return "audio/ogg"
        case "flac": return "audio/flac"
        case "opus": return "audio/opus"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        default: return nil
        }
    }
}

/// Owner Unix-socket media endpoint. The `sk_` token stays in the Authorization
/// header and is never placed on an AVPlayer URL or TCP loopback request.
struct MacAuthenticatedMediaSource: Sendable {
    let requestPath: String
    let socketPath: String
    let authorizationProvider: @Sendable () async throws -> String
    let contentTypeHint: String?
    let sourceFileExtension: String?

    var identity: String {
        [
            requestPath,
            socketPath,
            contentTypeHint ?? "",
            sourceFileExtension ?? "",
        ].joined(separator: "|")
    }
}

enum MacOwnerMediaSource {
    static func make(
        requestPath: String,
        socketPath: String,
        token: String,
        contentTypeHint: String?,
        sourceFileExtension: String?
    ) -> MacAuthenticatedMediaSource {
        MacAuthenticatedMediaSource(
            requestPath: requestPath,
            socketPath: socketPath,
            authorizationProvider: { "Bearer \(token)" },
            contentTypeHint: contentTypeHint,
            sourceFileExtension: sourceFileExtension
        )
    }

    static func workspaceFile(
        workspaceID: String,
        path: String,
        token: String,
        socketPath: String,
        worktreeId: String? = nil
    ) -> MacAuthenticatedMediaSource? {
        guard let requestPath = MacUnixSocketMediaPath.workspaceRaw(
            workspaceID: workspaceID,
            filePath: path,
            worktreeId: worktreeId
        ) else {
            return nil
        }
        let ext = (path as NSString).pathExtension
        return make(
            requestPath: requestPath,
            socketPath: socketPath,
            token: token,
            contentTypeHint: MacMediaMimeType.hint(forPathExtension: ext),
            sourceFileExtension: ext.isEmpty ? nil : ext
        )
    }

    static func sessionFile(
        workspaceID: String,
        sessionID: String,
        path: String,
        token: String,
        socketPath: String
    ) -> MacAuthenticatedMediaSource? {
        guard let requestPath = MacUnixSocketMediaPath.sessionRaw(
            workspaceID: workspaceID,
            sessionID: sessionID,
            filePath: path
        ) else {
            return nil
        }
        let ext = (path as NSString).pathExtension
        return make(
            requestPath: requestPath,
            socketPath: socketPath,
            token: token,
            contentTypeHint: MacMediaMimeType.hint(forPathExtension: ext),
            sourceFileExtension: ext.isEmpty ? nil : ext
        )
    }

    static func sessionAttachment(
        sessionID: String,
        attachmentID: String,
        mimeType: String?,
        token: String,
        socketPath: String,
        scope: SessionRouteScope? = nil
    ) -> MacAuthenticatedMediaSource? {
        guard let requestPath = MacUnixSocketMediaPath.sessionAttachment(
            sessionID: sessionID,
            attachmentID: attachmentID,
            scope: scope
        ) else {
            return nil
        }
        return make(
            requestPath: requestPath,
            socketPath: socketPath,
            token: token,
            contentTypeHint: mimeType,
            sourceFileExtension: nil
        )
    }
}

enum MacUnixSocketMediaRequest {
    static func make(
        method: String,
        path: String,
        authorization: String,
        range: MacUnixSocketRequestedRange?
    ) -> MacLocalHTTPRequest {
        var headers = [
            "Authorization": authorization,
            "Cache-Control": "no-cache",
        ]
        if let range {
            headers["Range"] = range.headerValue
        }
        return MacLocalHTTPRequest(method: method, path: path, headers: headers)
    }
}

struct MacUnixSocketMediaChunk: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(response: MacLocalHTTPResponse) {
        statusCode = response.statusCode
        headers = response.headers
        body = response.body
    }

    var contentType: String? { header("content-type") }
    var contentRange: String? { header("content-range") }

    var totalLength: Int64? {
        guard let header = contentRange, let slash = header.lastIndex(of: "/") else {
            return intHeader("content-length")
        }
        let suffix = header[header.index(after: slash)...]
        guard suffix != "*" else { return nil }
        return Int64(suffix)
    }

    var deliveredEnd: Int64? {
        guard let header = contentRange else { return nil }
        let parts = header.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let rangeAndLength = parts[1].split(separator: "/", maxSplits: 1)
        guard !rangeAndLength.isEmpty else { return nil }
        let bounds = rangeAndLength[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2 else { return nil }
        return Int64(bounds[1])
    }

    private func header(_ name: String) -> String? {
        if let value = headers[name] { return value }
        return headers.first { $0.key.lowercased() == name }?.value
    }

    private func intHeader(_ name: String) -> Int64? {
        guard let value = header(name) else { return nil }
        return Int64(value)
    }
}

enum MacUnixSocketRangeClient {
    static func fetch(
        source: MacAuthenticatedMediaSource,
        range: MacUnixSocketRequestedRange?,
        transport: any MacLocalHTTPPerforming
    ) async throws -> MacUnixSocketMediaChunk {
        let authorization = try await source.authorizationProvider()
        guard !authorization.isEmpty else {
            throw MacUnixSocketMediaError.emptyAuthorization
        }
        let request = MacUnixSocketMediaRequest.make(
            method: "GET",
            path: source.requestPath,
            authorization: authorization,
            range: range
        )
        let response = try await transport.perform(request)
        if let message = MacUnixSocketMediaResponseValidator.errorMessage(
            statusCode: response.statusCode,
            requestedRange: range,
            contentRange: MacUnixSocketMediaChunk(response: response).contentRange
        ) {
            throw MacUnixSocketMediaError.http(message)
        }
        return MacUnixSocketMediaChunk(response: response)
    }
}

/// AVPlayer talks to `oppi-media://owner-socket/…`. This loader turns byte-range
/// requests into owner Unix-socket HTTP with `Authorization: Bearer sk_…`.
final class MacUnixSocketRangeAdapter: NSObject, @unchecked Sendable, AVAssetResourceLoaderDelegate {
    let delegateQueue = DispatchQueue(label: "dev.chenda.OppiMac.unix-socket-media")

    private let source: MacAuthenticatedMediaSource
    private let transport: any MacLocalHTTPPerforming
    private let lock = NSLock()
    private var cancelledIDs: Set<ObjectIdentifier> = []
    private var isInvalidated = false
    private var inFlightTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

#if DEBUG
    var debugBeforeCommit: (@Sendable () -> Void)?
    private(set) var debugDidCommit = false
    private(set) var debugCheckedCommit = false
    private let debugRequestToken = NSObject()
#endif

    init(source: MacAuthenticatedMediaSource, transport: (any MacLocalHTTPPerforming)? = nil) {
        self.source = source
        self.transport = transport ?? MacUnixSocketHTTPClient(socketPath: source.socketPath, timeout: 60)
        super.init()
    }

    func cancelAll() {
        lock.lock()
        isInvalidated = true
        let tasks = Array(inFlightTasks.values)
        inFlightTasks.removeAll()
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let hasDataRequest = loadingRequest.dataRequest != nil
        let requestedRange: MacUnixSocketRequestedRange
        if let dataRequest = loadingRequest.dataRequest {
            let offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
            requestedRange = MacUnixSocketRequestedRange.make(
                offset: offset,
                requestedLength: dataRequest.requestedLength,
                requestsAllDataToEndOfResource: dataRequest.requestsAllDataToEndOfResource
            )
        } else {
            // Never HEAD through the Unix-socket codec: Content-Length on HEAD
            // is the resource size, not the empty body.
            requestedRange = MacUnixSocketRequestedRange(start: 0, end: 0, continuesToEnd: false)
        }
        startFulfillment(
            loadingRequest,
            requestID: ObjectIdentifier(loadingRequest),
            initialRange: requestedRange,
            deliverData: hasDataRequest
        )
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        cancel(requestID: ObjectIdentifier(loadingRequest))
    }

#if DEBUG
    func debugStartFulfillment() {
        startFulfillment(
            nil,
            requestID: ObjectIdentifier(debugRequestToken),
            initialRange: MacUnixSocketRequestedRange(start: 0, end: 3),
            deliverData: true
        )
    }

    func debugDidCancelCurrent() {
        cancel(requestID: ObjectIdentifier(debugRequestToken))
    }
#endif

    private func startFulfillment(
        _ loadingRequest: AVAssetResourceLoadingRequest?,
        requestID: ObjectIdentifier,
        initialRange: MacUnixSocketRequestedRange,
        deliverData: Bool
    ) {
        let task = Task { [weak self] in
            await self?.fulfill(
                loadingRequest,
                requestID: requestID,
                initialRange: initialRange,
                deliverData: deliverData
            )
            self?.removeInFlightTask(requestID)
        }
        lock.lock()
        if isInvalidated || cancelledIDs.contains(requestID) {
            lock.unlock()
            task.cancel()
            return
        }
        inFlightTasks[requestID] = task
        lock.unlock()
    }

    private func cancel(requestID: ObjectIdentifier) {
        lock.lock()
        cancelledIDs.insert(requestID)
        let task = inFlightTasks.removeValue(forKey: requestID)
        lock.unlock()
        task?.cancel()
    }

    private func removeInFlightTask(_ requestID: ObjectIdentifier) {
        lock.lock()
        inFlightTasks.removeValue(forKey: requestID)
        lock.unlock()
    }

    private func fulfill(
        _ loadingRequest: AVAssetResourceLoadingRequest?,
        requestID: ObjectIdentifier,
        initialRange: MacUnixSocketRequestedRange,
        deliverData: Bool
    ) async {
        var range = initialRange
        var didFillContentInfo = false
        while true {
            if isAbandoned(loadingRequest, requestID: requestID) { return }
            do {
                let chunk = try await MacUnixSocketRangeClient.fetch(
                    source: source,
                    range: range,
                    transport: transport
                )
                if isAbandoned(loadingRequest, requestID: requestID) { return }
                var committed = false
                await onDelegateQueue {
#if DEBUG
                    self.debugBeforeCommit?()
                    self.debugCheckedCommit = true
#endif
                    // Recheck on the resource-loader queue so a cancel that landed
                    // during the hop cannot still fill or respond.
                    if self.isAbandoned(loadingRequest, requestID: requestID) {
                        return
                    }
                    if let loadingRequest {
                        if !didFillContentInfo {
                            self.fillContentInformation(loadingRequest.contentInformationRequest, chunk: chunk)
                            didFillContentInfo = true
                        }
                        if deliverData {
                            loadingRequest.dataRequest?.respond(with: chunk.body)
                        }
                    }
#if DEBUG
                    self.debugDidCommit = true
#endif
                    committed = true
                }
                if !committed { return }
                if !range.continuesToEnd { break }
                guard let deliveredEnd = chunk.deliveredEnd,
                      let next = MacUnixSocketRangeContinuation.nextOffset(
                        afterEnd: deliveredEnd,
                        totalLength: chunk.totalLength
                      )
                else {
                    break
                }
                range = MacUnixSocketRequestedRange.make(
                    offset: next,
                    requestedLength: Int(MacUnixSocketRequestedRange.maxChunkLength),
                    requestsAllDataToEndOfResource: true
                )
            } catch is CancellationError {
                return
            } catch {
                if isAbandoned(loadingRequest, requestID: requestID) { return }
                mediaLogger.error("Unix-socket media range failed: \(error.localizedDescription, privacy: .public)")
                await onDelegateQueue {
                    guard !self.isAbandoned(loadingRequest, requestID: requestID),
                          let loadingRequest,
                          !loadingRequest.isCancelled,
                          !loadingRequest.isFinished
                    else {
                        return
                    }
                    loadingRequest.finishLoading(with: error)
                }
                return
            }
        }
        await onDelegateQueue {
            guard !self.isAbandoned(loadingRequest, requestID: requestID),
                  let loadingRequest,
                  !loadingRequest.isCancelled,
                  !loadingRequest.isFinished
            else {
                return
            }
            loadingRequest.finishLoading()
        }
    }

    private func isAbandoned(
        _ loadingRequest: AVAssetResourceLoadingRequest?,
        requestID: ObjectIdentifier
    ) -> Bool {
        if Task.isCancelled { return true }
        if let loadingRequest, loadingRequest.isCancelled || loadingRequest.isFinished {
            return true
        }
        lock.lock()
        let abandoned = isInvalidated || cancelledIDs.contains(requestID)
        lock.unlock()
        return abandoned
    }

    private func fillContentInformation(
        _ info: AVAssetResourceLoadingContentInformationRequest?,
        chunk: MacUnixSocketMediaChunk
    ) {
        guard let info else { return }
        let mimeType = chunk.contentType ?? source.contentTypeHint
        info.contentType = resourceLoaderContentType(
            mimeType: mimeType,
            fallbackExtension: source.sourceFileExtension
        )
        info.isByteRangeAccessSupported = true
        if let totalLength = chunk.totalLength {
            info.contentLength = totalLength
        }
    }

    private func resourceLoaderContentType(mimeType: String?, fallbackExtension: String?) -> String {
        if let mimeType, let type = UTType(mimeType: mimeType) {
            return type.identifier
        }
        if let fallbackExtension, let type = UTType(filenameExtension: fallbackExtension) {
            return type.identifier
        }
        return UTType.data.identifier
    }

    private func onDelegateQueue(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            delegateQueue.async {
                work()
                continuation.resume()
            }
        }
    }
}

@MainActor
final class MacAuthenticatedMediaPlaybackSession {
    let player: AVPlayer
    private let loader: MacUnixSocketRangeAdapter
    private let asset: AVURLAsset

    init(source: MacAuthenticatedMediaSource, transport: (any MacLocalHTTPPerforming)? = nil) {
        loader = MacUnixSocketRangeAdapter(source: source, transport: transport)
        asset = AVURLAsset(url: Self.makeAssetURL())
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["playable", "tracks", "duration"]
        )
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
    }

    nonisolated static func makeAssetURL() -> URL {
        var components = URLComponents()
        components.scheme = "oppi-media"
        components.host = "owner-socket"
        components.path = "/\(UUID().uuidString)"
        return components.url ?? URL(fileURLWithPath: "/oppi-media-\(UUID().uuidString)")
    }

    func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        loader.cancelAll()
    }
}

enum MacAVPlayback {
    case idle
    case fileURL(URL)
    case ownerSocket(MacAuthenticatedMediaSource)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var identity: String {
        switch self {
        case .idle:
            return "idle"
        case .fileURL(let url):
            return "file:\(url.absoluteString)"
        case .ownerSocket(let source):
            return "socket:\(source.identity)"
        }
    }
}

enum MacAVPlaybackURLPolicy {
    static func allows(_ url: URL) -> Bool {
        let text = url.absoluteString
        if text.contains("sk_") { return false }
        switch url.scheme?.lowercased() {
        case "oppi-media", "file":
            return true
        case "http", "https":
            return true
        default:
            return url.isFileURL
        }
    }
}
