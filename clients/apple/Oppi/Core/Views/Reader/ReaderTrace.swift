import Foundation

/// The live text behind one open reader: a thinking trace, a running command's
/// output, or a file a tool is still writing. `ChatTimelineReaderTraces` feeds
/// it from the timeline's apply; the reader observes it once for the body it
/// shows (`ReaderBodyContext.follow`).
@MainActor
final class ReaderTrace<Snapshot> {
    private(set) var snapshot: Snapshot
    private let isNews: (Snapshot, Snapshot) -> Bool
    private var observers: [Int: (Snapshot) -> Void] = [:]
    private var nextObserverID = 0

    /// `isNews(current, next)` decides whether observers hear about `next`.
    init(_ snapshot: Snapshot, isNews: @escaping (Snapshot, Snapshot) -> Bool) {
        self.snapshot = snapshot
        self.isNews = isNews
    }

    /// Keeps `next` and hands it to every observer when it is news.
    /// `DeltaCoalescer` is the only live clock, so news goes out at once.
    func update(_ next: Snapshot) {
        let deliver = isNews(snapshot, next)
        snapshot = next
        guard deliver else { return }
        for observer in observers.values {
            observer(next)
        }
    }

    /// Calls `observer` with each later news snapshot until the token is
    /// cancelled or released.
    func observe(_ observer: @escaping (Snapshot) -> Void) -> ReaderTraceToken {
        let id = nextObserverID
        nextObserverID += 1
        observers[id] = observer
        return ReaderTraceToken { [weak self] in
            self?.observers[id] = nil
        }
    }
}

extension ReaderTrace where Snapshot: Equatable {
    convenience init(_ snapshot: Snapshot) {
        self.init(snapshot, isNews: !=)
    }
}

/// One observation of a `ReaderTrace`; it ends on `cancel()` or release.
@MainActor
final class ReaderTraceToken {
    private var end: (() -> Void)?

    fileprivate init(end: @escaping () -> Void) {
        self.end = end
    }

    func cancel() {
        end?()
        end = nil
    }

    isolated deinit {
        cancel()
    }
}

struct ThinkingSnapshot: Equatable {
    let text: String
    let isDone: Bool
}

struct TerminalSnapshot {
    let output: String
    let command: String?
    let isDone: Bool
    /// The finished call's sidecar. A reader built after completion loads the
    /// whole output from it when its content passed none. Never news by itself.
    var sidecarSource: ToolOutputSidecarWindowSource?

    static func isNews(_ current: Self, _ next: Self) -> Bool {
        current.output != next.output || current.command != next.command || current.isDone != next.isDone
    }
}

struct SourceSnapshot {
    let text: String
    let filePath: String?
    let isDone: Bool
    let finalContent: FullScreenCodeContent?

    /// A change of final kind is news; another final payload of the same kind
    /// waits for the next text.
    static func isNews(_ current: Self, _ next: Self) -> Bool {
        current.text != next.text
            || current.filePath != next.filePath
            || current.isDone != next.isDone
            || current.finalContent?.kindName != next.finalContent?.kindName
    }
}
