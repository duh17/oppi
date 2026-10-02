import Foundation
import Observation

/// The sidecar transport returns raw bytes and the actual HTTP byte range.
/// UTF-8 clamping may advance the start for a tail request, never for a gap.
struct TerminalOutputRange: Sendable {
    let data: Data
    let start: Int
    let end: Int // exclusive
    var totalBytes: Int? = nil // Content-Range total, used by full-history paging
}

enum TerminalOutputStreamState: Equatable, Sendable {
    case attaching, live, resyncing, tailResync(omittedBytes: Int), resyncFailed, complete

    var notice: String? {
        switch self {
        case .attaching: "Attaching terminal output…"
        case .resyncing: "Resyncing terminal output…"
        case .tailResync(let bytes): "Earlier output omitted (\(bytes) bytes); resynced from tail"
        case .resyncFailed: "Terminal output resync failed"
        case .live, .complete: nil
        }
    }
}

/// One byte cursor and one engine per call. All access, including recovery
/// completion and formatting, is serialized on MainActor. Views consume only
/// owned formatted snapshots, never raw log history or borrowed grid storage.
@MainActor @Observable
final class TerminalOutputStream {
    static let maximumGap = 4 * 1024 * 1024
    private static let maximumQueuedBytes = 256 * 1024
    typealias FetchRange = @Sendable (Range<Int>) async throws -> TerminalOutputRange

    private(set) var epoch = 0
    private(set) var cursor = 0
    private(set) var state: TerminalOutputStreamState = .attaching
    private(set) var formatted = ""
    private(set) var omittedBytes = 0
    private(set) var presentationRevision: UInt64 = 0

    @ObservationIgnored private let fetchRange: FetchRange
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var paintTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queued: [(ToolOutputStreamChunk, String)] = []
    @ObservationIgnored private var queuedBytes = 0
    @ObservationIgnored private var recoveryTarget = 0
    @ObservationIgnored private var finalLength: Int?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var observers: [UUID: () -> Void] = [:]
    #if canImport(GhosttyVt)
    @ObservationIgnored private var engine: TerminalLogEngine?
    #endif

    init(fetchRange: @escaping FetchRange) { self.fetchRange = fetchRange }

    func receive(_ chunk: ToolOutputStreamChunk, output: String) {
        guard chunk.epoch >= epoch else { return }
        guard chunk.epoch >= 1, chunk.offset >= 0, chunk.bytes >= 0,
              chunk.bytes > 0 || output.isEmpty,
              chunk.offset <= Int.max - chunk.bytes else { fail(); return }
        if chunk.epoch > epoch { reset(epoch: chunk.epoch) }
        guard state != .complete else { return }
        if recovery != nil {
            enqueue(chunk, output: output)
            return
        }
        let end = chunk.offset + chunk.bytes
        if chunk.bytes > 0, end <= cursor { return } // exact/subset duplicate
        if chunk.offset == cursor {
            if output.utf8.count != chunk.bytes || output.contains("\u{FFFD}") {
                // The JSON string is not a raw-byte authority. Recover this
                // span before feeding anything, and queue later live chunks.
                recover(to: end)
                return
            }
            do {
                try feed(Data(output.utf8))
                cursor = end // wire length, NOT decoded string length
                state = omittedBytes > 0 ? .tailResync(omittedBytes: omittedBytes) : .live
                schedulePaint()
            } catch { fail() }
        } else if chunk.offset > cursor {
            enqueue(chunk, output: output)
            recover(to: chunk.offset)
        } else {
            // Partial overlap is a protocol violation. Refetch the entire prefix
            // including the suspect chunk instead of feeding its ambiguous suffix.
            reset(epoch: epoch)
            recover(to: end)
        }
    }

    func finish(_ end: ToolOutputStreamEnd) {
        guard end.epoch >= epoch else { return }
        guard end.epoch >= 1, end.totalBytes >= 0 else { fail(); return }
        if state == .complete, end.epoch == epoch, end.totalBytes == cursor { return }
        if end.epoch > epoch { reset(epoch: end.epoch) }
        finalLength = end.totalBytes
        if recovery != nil {
            recoveryTarget = max(recoveryTarget, end.totalBytes)
        } else if end.totalBytes > cursor {
            recover(to: end.totalBytes)
        } else if end.totalBytes == cursor {
            complete()
        } else {
            reset(epoch: epoch)
            finalLength = end.totalBytes
            recover(to: end.totalBytes)
        }
    }

    func markReconnecting() {
        guard state != .complete else { return }
        generation += 1
        recovery?.cancel()
        recovery = nil
        recoveryTarget = cursor
        queued.removeAll()
        queuedBytes = 0
        state = .resyncing
        publish()
    }

    /// Used before reading a copy snapshot; cancellation still belongs to owner.
    func waitForRecovery() async { while let task = recovery { await task.value } }

    @discardableResult
    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func discard() {
        generation += 1
        recovery?.cancel()
        paintTask?.cancel()
        recovery = nil
        recoveryTarget = cursor
        paintTask = nil
        #if canImport(GhosttyVt)
        engine = nil
        #endif
    }

    private func reset(epoch: Int) {
        discard()
        self.epoch = epoch
        cursor = 0
        omittedBytes = 0
        finalLength = nil
        recoveryTarget = 0
        queued.removeAll()
        queuedBytes = 0
        formatted = ""
        state = .attaching
        dirty = true
    }

    private func enqueue(_ chunk: ToolOutputStreamChunk, output: String) {
        let size = output.utf8.count
        if queuedBytes + size > Self.maximumQueuedBytes || queued.count >= 512 {
            // Keep only a recovery high-water mark when the queue is full.
            // Missing chunks will be fetched, never concatenated or silently fed.
            recoveryTarget = max(recoveryTarget, chunk.offset + chunk.bytes,
                queued.map { $0.0.offset + $0.0.bytes }.max() ?? 0)
            queued.removeAll(keepingCapacity: true)
            queuedBytes = 0
        } else {
            queued.append((chunk, output))
            queuedBytes += size
        }
    }

    private func recover(to target: Int) {
        // This is a fresh recovery. Only finish/queue overflow extend an
        // in-flight target; a cancelled fill must not lend its high-water mark.
        recoveryTarget = target
        state = .resyncing
        publish()
        let token = generation
        recovery = Task { [weak self] in
            guard let self else { return }
            do {
                while self.cursor < self.recoveryTarget {
                    let target = self.recoveryTarget
                    let tail = target - self.cursor > Self.maximumGap
                    let start = tail ? target - Self.maximumGap : self.cursor
                    let result = try await self.fetchRecoveryRange(start..<target)
                    try Task.checkCancellation()
                    guard token == self.generation else { return }
                    guard result.end == target, result.start >= start,
                          result.start < result.end,
                          result.data.count == result.end - result.start,
                          tail || result.start == start else { throw RecoveryFailure() }
                    var data = result.data
                    if tail {
                        #if canImport(GhosttyVt)
                        self.engine = nil
                        #endif
                        var omitted = result.start
                        if let newline = data.firstIndex(of: 0x0A), newline < data.index(before: data.endIndex) {
                            let count = data.distance(from: data.startIndex, to: newline) + 1
                            data = Data(data.dropFirst(count))
                            omitted += count
                        }
                        self.omittedBytes = omitted
                    }
                    try self.feed(data)
                    self.cursor = result.end
                }
                guard token == self.generation else { return }
                self.recovery = nil
                let queued = self.queued
                self.queued.removeAll(keepingCapacity: true)
                self.queuedBytes = 0
                self.state = self.omittedBytes > 0 ? .tailResync(omittedBytes: self.omittedBytes) : .live
                for (chunk, output) in queued { self.receive(chunk, output: output) }
                if let length = self.finalLength, self.recovery == nil {
                    if length == self.cursor { self.complete() }
                    else if length > self.cursor { self.recover(to: length) }
                    else { self.fail() }
                }
                self.schedulePaint()
            } catch {
                guard token == self.generation, !Task.isCancelled else { return }
                self.recovery = nil
                self.fail()
            }
        }
    }

    /// Pi's file can temporarily lag the published cursor. Keep the visible
    /// resync state through a bounded 416 retry; never accept a shorter Range.
    private func fetchRecoveryRange(_ range: Range<Int>) async throws -> TerminalOutputRange {
        for attempt in 0..<3 {
            do {
                let result = try await fetchRange(range)
                if result.end < range.upperBound { throw ShortRange() }
                return result
            }
            catch {
                let status: Int?
                switch error as? APIError {
                case .server(let code, _), .codedServer(let code, _, _): status = code
                default: status = nil
                }
                guard status == 416 || error is ShortRange, attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
            }
        }
        throw RecoveryFailure()
    }

    private struct ShortRange: Error {}
    private struct RecoveryFailure: Error {}

    private func feed(_ data: Data) throws {
        #if canImport(GhosttyVt)
        let engine = try engine ?? TerminalLogEngine(live: true)
        self.engine = engine
        try engine.feed(data)
        #endif
        dirty = true
    }

    private func schedulePaint() {
        guard paintTask == nil else { return }
        paintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            self.paintTask = nil
            self.paint()
        }
    }

    private func paint() {
        if dirty {
            #if canImport(GhosttyVt)
            do { formatted = try engine?.paint() ?? formatted }
            catch { state = .resyncFailed }
            #endif
            dirty = false
        }
        publish()
    }

    private func complete() {
        paintTask?.cancel()
        paintTask = nil
        paint()
        guard state != .resyncFailed else { return }
        #if canImport(GhosttyVt)
        engine = nil // completed readers load full history through the sidecar
        #endif
        state = .complete
        publish()
    }

    private func fail() {
        state = .resyncFailed
        queued.removeAll()
        queuedBytes = 0
        publish()
    }

    private func publish() {
        presentationRevision &+= 1
        for observer in observers.values { observer() }
    }
}

@MainActor
final class TerminalOutputStreamStore {
    private var owners: [String: TerminalOutputStream] = [:]
    private var ownerObservers: [UUID: (id: String, notify: (TerminalOutputStream?) -> Void)] = [:]
    var fetchRange: (@Sendable (_ toolCallId: String, _ range: Range<Int>) async throws -> TerminalOutputRange)?
    var onChange: ((String) -> Void)?

    func owner(for id: String) -> TerminalOutputStream? { owners[id] }

    /// Readers retain call identity across a full trace rebuild, not cell identity.
    @discardableResult
    func addOwnerObserver(for id: String, _ notify: @escaping (TerminalOutputStream?) -> Void) -> UUID {
        let token = UUID()
        ownerObservers[token] = (id, notify)
        return token
    }
    func removeOwnerObserver(_ token: UUID) { ownerObservers.removeValue(forKey: token) }
    private func notifyOwnerObservers(for id: String) {
        for observer in ownerObservers.values where observer.id == id { observer.notify(owners[id]) }
    }

    func ensureOwner(for id: String) -> TerminalOutputStream {
        if let existing = owners[id] { return existing }
        let owner = TerminalOutputStream { [weak self] range in
            guard let fetch = await self?.fetchRange else { throw SidecarUnavailable() }
            return try await fetch(id, range)
        }
        owner.addObserver { [weak self] in self?.onChange?(id) }
        owners[id] = owner
        notifyOwnerObservers(for: id)
        return owner
    }
    func markReconnecting() { for owner in owners.values { owner.markReconnecting() } }
    func clearAll() {
        let ids = Array(owners.keys)
        for owner in owners.values { owner.discard() }
        owners.removeAll()
        for id in ids { notifyOwnerObservers(for: id) }
    }
    private struct SidecarUnavailable: Error {}
}
