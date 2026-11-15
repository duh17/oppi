import Foundation
import Synchronization

/// Runs attachment body uploads as delegate-driven upload tasks, so each reports
/// its progress and fails only when no bytes move for `idleTimeout` (never on a
/// total duration: a screen recording can take many minutes).
///
/// `background` is the app's one background URLSession. A file upload on a
/// direct route runs there, so it keeps going while Oppi is in the background or
/// the screen is locked; iOS wakes the app when it finishes
/// (`AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`).
/// A route through the in-app Tailscale node cannot: its proxy lives in this
/// process and stops with it, so those uploads use a foreground transport.
///
/// Each task carries its server's `PinnedServerTrustDelegate`, so the pinned
/// certificate and the bearer header are exactly those of the API request.
final class AttachmentUploadTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (_ sentBytes: Int64, _ totalBytes: Int64) -> Void

    static let idleTimeout: TimeInterval = 120

    static let backgroundIdentifier = "\(Bundle.main.bundleIdentifier ?? "dev.chaosdonkey.oppi").attachment-uploads"

    /// iOS allows one live session per identifier, so every server shares this one.
    static let background: AttachmentUploadTransport = {
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return AttachmentUploadTransport(configuration: configuration)
    }()

    private struct Pending {
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        let trust: PinnedServerTrustDelegate
        let progress: Progress?
        var body = Data()
    }

    private let pending = Mutex<[Int: Pending]>([:])
    /// Tasks nobody awaits: started before Oppi was relaunched. Their response
    /// bodies by task, and finished results by `reattachKey`, until a send of the
    /// same file in the same session adopts them.
    private let orphanBodies = Mutex<[Int: Data]>([:])
    private let orphanResults = Mutex<[String: (Data, URLResponse)]>([:])
    private let finishBackgroundEvents = Mutex<(@Sendable () -> Void)?>(nil)
    private let configuration: URLSessionConfiguration
    // URLSession needs its delegate (self) first; init forces it before any use.
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

    /// A foreground transport. `configuration` keeps its route (proxy) and
    /// protocol classes; its timeouts become idle-only.
    init(configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        self.configuration = configuration
        super.init()
        _ = session
    }

    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    /// Hands over iOS's completion for a background wake; it runs once this
    /// session has delivered every pending event.
    func finishEventsWhenDelivered(_ completion: @escaping @Sendable () -> Void) {
        finishBackgroundEvents.withLock { $0 = completion }
    }

    /// Uploads a file. When a task for the same file and session survives from
    /// before a relaunch, still running or already finished, this waits for that
    /// one instead of sending the file again.
    func upload(
        _ request: URLRequest,
        fromFile fileURL: URL,
        trust: PinnedServerTrustDelegate,
        progress: Progress?
    ) async throws -> (Data, URLResponse) {
        let key = Self.reattachKey(request: request, fileURL: fileURL)
        if let key {
            if let finished = orphanResults.withLock({ $0.removeValue(forKey: key) }) {
                return finished
            }
            for task in await session.allTasks
            where task.taskDescription == key && task.state == .running && !isAwaited(task) {
                return try await adopt(task, trust: trust, progress: progress)
            }
        }
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = key
        return try await run(task, trust: trust, progress: progress)
    }

    /// The session's attachments path and the file: another upload of this file
    /// to the same session is the same upload.
    static func reattachKey(request: URLRequest, fileURL: URL) -> String? {
        guard let path = request.url?.path, let range = path.range(of: "/attachments/") else { return nil }
        return "\(path[..<range.lowerBound])\n\(fileURL.standardizedFileURL.path)"
    }

    private func isAwaited(_ task: URLSessionTask) -> Bool {
        pending.withLock { $0[task.taskIdentifier] != nil }
    }

    private func adopt(
        _ task: URLSessionTask,
        trust: PinnedServerTrustDelegate,
        progress: Progress?
    ) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let body = orphanBodies.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? Data()
                pending.withLock {
                    $0[task.taskIdentifier] = Pending(
                        continuation: continuation,
                        trust: trust,
                        progress: progress,
                        body: body
                    )
                }
                // It may have finished between the scan and now.
                if task.state == .completed {
                    urlSession(session, task: task, didCompleteWithError: task.error)
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Background sessions take only files; data bodies use a foreground transport.
    func upload(
        _ request: URLRequest,
        from data: Data,
        trust: PinnedServerTrustDelegate,
        progress: Progress?
    ) async throws -> (Data, URLResponse) {
        try await run(session.uploadTask(with: request, from: data), trust: trust, progress: progress)
    }

    private func run(
        _ task: URLSessionUploadTask,
        trust: PinnedServerTrustDelegate,
        progress: Progress?
    ) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.withLock {
                    $0[task.taskIdentifier] = Pending(continuation: continuation, trust: trust, progress: progress)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let progress = pending.withLock { $0[task.taskIdentifier]?.progress }
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let awaited = pending.withLock { pending -> Bool in
            guard pending[dataTask.taskIdentifier] != nil else { return false }
            pending[dataTask.taskIdentifier]?.body.append(data)
            return true
        }
        if !awaited {
            orphanBodies.withLock { $0[dataTask.taskIdentifier, default: Data()].append(data) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let finished = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else {
            // Nobody waits yet (a relaunch): keep a success for the next send of this file.
            let body = orphanBodies.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? Data()
            if error == nil, let response = task.response, let key = task.taskDescription {
                orphanResults.withLock { $0[key] = (body, response) }
            }
            return
        }
        if let error {
            finished.continuation.resume(throwing: error)
        } else if let response = task.response {
            finished.continuation.resume(returning: (finished.body, response))
        } else {
            finished.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = pending.withLock({ $0[task.taskIdentifier]?.trust }) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        trust.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let trust = pending.withLock({ $0[task.taskIdentifier]?.trust }) else {
            completionHandler(nil)
            return
        }
        trust.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let completion = finishBackgroundEvents.withLock({ value in
            defer { value = nil }
            return value
        }) else { return }
        DispatchQueue.main.async(execute: completion)
    }
}
