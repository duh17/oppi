import Foundation

/// The uploads of one send, per attachment, as the composer shows them: a state on
/// each attachment and one line with the batch's progress.
///
/// `PendingAttachmentUploader` reports byte progress per file; the chat applies it
/// here, and adds what only the screen knows: that the person cancelled, and that
/// the app went to the background while an upload could not continue there.
struct AttachmentUploadBatch: Equatable {
    enum State: Equatable {
        /// Queued behind the files before it.
        case waiting
        case uploading
        /// The connection dropped; the file starts over after a short wait.
        case retrying(attempt: Int, maxAttempts: Int, reason: String)
        case uploaded
        case failed(String)
        case cancelled
    }

    struct Item: Equatable {
        let id: String
        var name: String
        var sentBytes: Int64
        var totalBytes: Int64
        var state: State

        var fraction: Double {
            if state == .uploaded { return 1 }
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(sentBytes) / Double(totalBytes))
        }

        var isActive: Bool {
            switch state {
            case .waiting, .uploading, .retrying: return true
            case .uploaded, .failed, .cancelled: return false
            }
        }
    }

    private(set) var order: [String]
    private(set) var items: [String: Item]
    /// The app is in the background and this route cannot upload there (the in-app
    /// Tailscale node stops with the app); the transfer continues when Oppi returns.
    var isPaused = false

    /// The local attachments a send will upload, in send order.
    init(_ uploads: [(id: String, name: String, totalBytes: Int64)]) {
        order = uploads.map(\.id)
        items = Dictionary(uniqueKeysWithValues: uploads.map {
            ($0.id, Item(id: $0.id, name: $0.name, sentBytes: 0, totalBytes: $0.totalBytes, state: .waiting))
        })
    }

    func item(_ id: String) -> Item? { items[id] }

    var isActive: Bool { items.values.contains(where: \.isActive) }

    /// The file being sent now, if any.
    var current: Item? {
        order.lazy.compactMap { items[$0] }.first { item in
            switch item.state {
            case .uploading, .retrying: return true
            default: return false
            }
        }
    }

    /// Bytes sent across the batch over its total; a finished file counts in full.
    var fraction: Double {
        let all = order.compactMap { items[$0] }
        let total = all.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        let sent = all.reduce(Int64(0)) { $0 + ($1.state == .uploaded ? $1.totalBytes : min($1.sentBytes, $1.totalBytes)) }
        return min(1, Double(sent) / Double(total))
    }

    /// Takes the uploader's report for one file. A file that already finished,
    /// failed, or was cancelled keeps that state: a byte count hopping to the main
    /// actor can land after the outcome.
    mutating func apply(_ progress: AttachmentUploadProgress) {
        guard var item = items[progress.attachmentId] else { return }
        if !item.isActive { return }
        item.name = progress.name
        item.sentBytes = progress.sentBytes
        if progress.totalBytes > 0 { item.totalBytes = progress.totalBytes }
        switch progress.phase {
        case .uploading:
            item.state = .uploading
        case .retrying(let attempt, let maxAttempts, let reason):
            item.state = .retrying(attempt: attempt, maxAttempts: maxAttempts, reason: reason)
        case .uploaded:
            item.state = .uploaded
            item.sentBytes = item.totalBytes
        case .failed(let reason):
            item.state = .failed(reason)
        }
        items[item.id] = item
    }

    /// The person stopped the send: the file in flight is cancelled, and files that
    /// never started go back to plain attachments.
    mutating func cancel() {
        for id in order {
            guard let item = items[id] else { continue }
            switch item.state {
            case .uploading, .retrying:
                items[id]?.state = .cancelled
            case .waiting:
                items[id] = nil
            case .uploaded, .failed, .cancelled:
                break
            }
        }
        order.removeAll { items[$0] == nil }
        isPaused = false
    }

    /// The send stopped for a reason the uploader did not attach to a file (no
    /// connection, the session closed): the file in flight shows it, the rest return.
    mutating func fail(_ reason: String) {
        for id in order {
            guard let item = items[id] else { continue }
            switch item.state {
            case .uploading, .retrying:
                items[id]?.state = .failed(reason)
            case .waiting:
                items[id] = nil
            case .uploaded, .failed, .cancelled:
                break
            }
        }
        order.removeAll { items[$0] == nil }
        isPaused = false
    }

    /// Only attachments still in the draft keep a state (a removed one drops out).
    mutating func keep(only ids: Set<String>) {
        order.removeAll { !ids.contains($0) }
        items = items.filter { ids.contains($0.key) }
    }

    /// The batch line above the composer while a send uploads; nil when idle.
    var statusLine: String? {
        guard isActive else { return nil }
        if isPaused { return "Paused \u{2014} keep Oppi open to finish" }
        guard let current else { return "Preparing upload\u{2026}" }
        let position = order.count > 1 ? "\((order.firstIndex(of: current.id) ?? 0) + 1) of \(order.count) \u{00B7} " : ""
        switch current.state {
        case .retrying(let attempt, let maxAttempts, let reason):
            return "Retrying \(position)\(current.name) (try \(attempt) of \(maxAttempts)): \(reason)"
        default:
            let all = order.compactMap { items[$0] }
            let total = all.reduce(Int64(0)) { $0 + $1.totalBytes }
            let sent = Int64((Double(total) * fraction).rounded())
            // No file name: the file's own ring says which one is moving, and the
            // line stays short enough for an iPhone.
            return "Uploading \(position)\(Self.bytes(sent)) of \(Self.bytes(total)) (\(Int(fraction * 100))%)"
        }
    }

    /// The short state on one attachment: "48%", "Waiting", "Paused", "Failed".
    func badge(for id: String) -> String? {
        guard let item = items[id] else { return nil }
        switch item.state {
        case .waiting: return isPaused ? "Paused" : "Waiting"
        case .uploading: return isPaused ? "Paused" : "\(Int(item.fraction * 100))%"
        case .retrying: return isPaused ? "Paused" : "Retrying"
        case .uploaded: return "Uploaded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
