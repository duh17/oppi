#if DEBUG
import Foundation
import Synchronization

/// `CHAT_ROUTES_INTERNAL_URL_FILE=<path>`: the chat's server shows `proc://`
/// URLs (`capabilities.internalUrlViews`) and answers the session's
/// `internal-url` routes from the views in that file, a JSON object keyed by
/// URL whose values are wire `InternalUrlView`s. A `live` view reveals its
/// output a line at a time, `linesPerSecond` (default 4) from `initialLines`
/// (default 40) at its first read, so the viewer follows it; Stop ends it as
/// `Stopped`. Reads append from `from`, as the server's do.
enum ChatRoutesInternalURL {
    private struct Job: @unchecked Sendable {
        let view: [String: Any]
        let lines: [String]
        let initialLines: Int
        let linesPerSecond: Double
        var firstRead: Date?
        var stoppedAt: Date?
    }

    private static let path = ProcessInfo.processInfo.environment["CHAT_ROUTES_INTERNAL_URL_FILE"]
    private static let jobs = Mutex<[String: Job]?>(nil)

    static var isEnabled: Bool { path != nil }

    private static func loaded(_ jobs: inout [String: Job]?) -> [String: Job] {
        if let jobs { return jobs }
        let object = path.flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
        let fresh = object.mapValues { view -> Job in
            let output = (view["output"] as? [String: Any])?["text"] as? String ?? ""
            return Job(
                view: view,
                lines: output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                initialLines: view["initialLines"] as? Int ?? 40,
                linesPerSecond: view["linesPerSecond"] as? Double ?? 4
            )
        }
        jobs = fresh
        return fresh
    }

    /// The body for an `internal-url` request, or nil when it is not one.
    static func answer(_ method: String, _ url: URL) -> Data? {
        guard isEnabled, url.path.hasSuffix("/internal-url") || url.path.hasSuffix("/internal-url/stop") else {
            return nil
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let target = query.first { $0.name == "url" }?.value ?? ""
        let from = query.first { $0.name == "from" }?.value.flatMap(Int.init)
        return jobs.withLock { stored -> Data? in
            var all = loaded(&stored)
            guard var job = all[target] else { return nil }
            defer {
                all[target] = job
                stored = all
            }
            if method == "POST" {
                job.stoppedAt = Date()
                return Data(#"{"ok":true}"#.utf8)
            }
            return view(of: &job, from: from)
        }
    }

    private static func view(of job: inout Job, from: Int?) -> Data? {
        let now = Date()
        if job.firstRead == nil { job.firstRead = now }
        var view = job.view
        var status = view["status"] as? [String: Any] ?? [:]
        let live = status["live"] as? Bool == true && job.stoppedAt == nil
        let shown = live
            ? min(job.lines.count, job.initialLines + Int(now.timeIntervalSince(job.firstRead ?? now) * job.linesPerSecond))
            : job.lines.count
        let text = job.lines.prefix(shown).joined(separator: "\n") + (shown < job.lines.count ? "\n" : "")
        if let stoppedAt = job.stoppedAt {
            let ended = stoppedAt.timeIntervalSince1970 * 1000
            status["text"] = "Stopped"
            status["tone"] = "warning"
            status["live"] = false
            status["endedAt"] = ended
            view["stoppable"] = false
            var facts = (view["facts"] as? [[String: Any]] ?? []).filter { $0["label"] as? String != "Times out" }
            facts.insert(["label": "Ended", "time": ended], at: min(2, facts.count))
            view["facts"] = facts
        }
        view["status"] = status
        if let from, from <= text.utf16.count {
            view["output"] = [
                "start": from, "text": String(text[String.Index(utf16Offset: from, in: text)...]), "truncated": false,
            ]
        } else {
            view["output"] = ["start": 0, "text": text, "truncated": false]
        }
        return try? JSONSerialization.data(withJSONObject: view)
    }
}
#endif
