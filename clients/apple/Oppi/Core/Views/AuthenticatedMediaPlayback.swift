@preconcurrency import AVFoundation
import AVKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum AuthenticatedMediaPlaybackConstants {
    static let scheme = "oppi-media"
    static let defaultRangeLength = 1_048_576
}

struct AuthenticatedMediaRequestedRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
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
              parsedRange.end >= requestedRange.start,
              parsedRange.end <= requestedRange.end else {
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
private final class AuthenticatedMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private final class LoadingContext {
        let loadingRequest: AVAssetResourceLoadingRequest
        let requestedRange: AuthenticatedMediaRequestedRange?
        var cancelled = false
        var responseError: Error?

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            requestedRange: AuthenticatedMediaRequestedRange?
        ) {
            self.loadingRequest = loadingRequest
            self.requestedRange = requestedRange
        }
    }

    private let source: AuthenticatedMediaSource
    private let trustDelegate: PinnedServerTrustDelegate
    private let lock = NSLock()
    private var contextsByTaskId: [Int: LoadingContext] = [:]
    private var tasksByRequestId: [ObjectIdentifier: URLSessionDataTask] = [:]

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
        trustDelegate = PinnedServerTrustDelegate(pinnedLeafFingerprint: source.tlsCertFingerprint)
        super.init()
    }

    deinit {
        cancelAll()
        session.invalidateAndCancel()
    }

    func cancelAll() {
        lock.lock()
        let tasks = Array(tasksByRequestId.values)
        contextsByTaskId.removeAll()
        tasksByRequestId.removeAll()
        lock.unlock()

        for task in tasks {
            task.cancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        var request = URLRequest(url: source.url)
        request.httpMethod = loadingRequest.dataRequest == nil ? "HEAD" : "GET"
        request.setValue(source.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let requestedRange: AuthenticatedMediaRequestedRange?
        if let dataRequest = loadingRequest.dataRequest {
            let offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
            let requestedLength = dataRequest.requestedLength > 0
                ? dataRequest.requestedLength
                : AuthenticatedMediaPlaybackConstants.defaultRangeLength
            let end = offset + Int64(requestedLength) - 1
            requestedRange = AuthenticatedMediaRequestedRange(start: offset, end: end)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        } else {
            requestedRange = nil
        }

        let task = session.dataTask(with: request)
        let context = LoadingContext(loadingRequest: loadingRequest, requestedRange: requestedRange)
        let requestId = ObjectIdentifier(loadingRequest)

        lock.lock()
        contextsByTaskId[task.taskIdentifier] = context
        tasksByRequestId[requestId] = task
        lock.unlock()

        task.resume()
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

        if let errorMessage = AuthenticatedMediaResponseValidator.errorMessage(
            statusCode: http.statusCode,
            requestedRange: context.requestedRange,
            contentRange: http.value(forHTTPHeaderField: "Content-Range")
        ) {
            context.responseError = mediaError(errorMessage)
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
        context.loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let context = removeContext(for: task)
        guard let context, !context.cancelled else { return }

        if let error = context.responseError ?? error {
            context.loadingRequest.finishLoading(with: error)
        } else {
            context.loadingRequest.finishLoading()
        }
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

    private func mediaError(_ message: String) -> NSError {
        NSError(
            domain: "dev.chenda.oppi.authenticated-media",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
final class AuthenticatedMediaPlaybackSession {
    let player: AVPlayer

    private let loader: AuthenticatedMediaResourceLoader
    private let asset: AVURLAsset

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
        player.automaticallyWaitsToMinimizeStalling = true
    }

    private static func makeAssetURL() -> URL {
        var components = URLComponents()
        components.scheme = AuthenticatedMediaPlaybackConstants.scheme
        components.host = "stream"
        components.path = "/\(UUID().uuidString)"
        return components.url ?? URL(fileURLWithPath: "/oppi-media-\(UUID().uuidString)")
    }

    func teardown() {
        player.pause()
        asset.resourceLoader.setDelegate(nil, queue: nil)
        loader.cancelAll()
    }
}

@MainActor
private final class AuthenticatedMediaPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var playbackSession: AuthenticatedMediaPlaybackSession?
    private var statusObservation: NSKeyValueObservation?
    private var preparedIdentity: String?

    func prepare(source: AuthenticatedMediaSource, autoplay: Bool) {
        guard preparedIdentity != source.identity else { return }

        teardown(resetPreparedIdentity: false)
        preparedIdentity = source.identity
        isLoading = true
        errorMessage = nil

        let playbackSession = AuthenticatedMediaPlaybackSession(source: source)
        let player = playbackSession.player
        self.playbackSession = playbackSession
        self.player = player

        statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.errorMessage = nil
                    if autoplay {
                        player.play()
                    }
                case .failed:
                    self.isLoading = false
                    self.errorMessage = item.error?.localizedDescription ?? "Media failed to load"
                    player.pause()
                    self.player = nil
                case .unknown:
                    self.isLoading = true
                @unknown default:
                    self.isLoading = false
                    self.errorMessage = "Unsupported media state"
                    player.pause()
                    self.player = nil
                }
            }
        }
    }

    func teardown(resetPreparedIdentity: Bool = true) {
        statusObservation?.invalidate()
        statusObservation = nil
        playbackSession?.teardown()
        playbackSession = nil
        player = nil
        isLoading = false

        if resetPreparedIdentity {
            preparedIdentity = nil
        }
    }
}

struct AuthenticatedMediaPlayerView: View {
    let source: AuthenticatedMediaSource
    var height: CGFloat = 260
    var cornerRadius: CGFloat = 10
    var autoplay = false
    var unavailableTitle = "Media preview unavailable"
    var unavailableSystemImage = "play.slash"

    @StateObject private var model = AuthenticatedMediaPlayerModel()

    var body: some View {
        Group {
            if let player = model.player {
                AVPlayerViewControllerContainer(player: player)
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
        .task(id: source.identity) {
            model.prepare(source: source, autoplay: autoplay)
        }
        .onDisappear {
            model.teardown()
        }
    }
}

@MainActor
final class AuthenticatedMediaPlayerViewController: AVPlayerViewController {
    private var playbackSession: AuthenticatedMediaPlaybackSession?

    func configure(source: AuthenticatedMediaSource, autoplay: Bool) {
        let playbackSession = AuthenticatedMediaPlaybackSession(source: source)
        self.playbackSession = playbackSession
        player = playbackSession.player
        showsPlaybackControls = true
        allowsPictureInPicturePlayback = true
        canStartPictureInPictureAutomaticallyFromInline = true
        entersFullScreenWhenPlaybackBegins = false
        exitsFullScreenWhenPlaybackEnds = false
        view.accessibilityIdentifier = "videoPlayer.native"
        if autoplay {
            playbackSession.player.play()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            playbackSession?.teardown()
            playbackSession = nil
        }
    }
}
