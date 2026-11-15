import Foundation

/// One read of a server document at a time, so what the app holds ends on the server's latest.
///
/// - A refresh asked for while a read runs does not start a second one: the running one reads
///   once more after it ends (what changed may postdate its read), and the caller waits for that.
/// - A local change (`noteLocalChange`, a save this device made that the server already applied)
///   that lands while a read is out means the read may predate it: its answer is not applied, and
///   it reads again instead.
/// - `cancel` ends the run without applying anything more; the next refresh starts a new one.
///
/// `ServerConnection` refreshes `/server/info` through one.
@MainActor
final class RefreshCoalescer<Value> {
    private var running: Task<Void, Never>?
    /// Counts runs, so a run that `cancel` replaced never clears its successor.
    private var runs: UInt64 = 0
    private var readAgain = false
    private var localChanges: UInt64 = 0

    func noteLocalChange() {
        localChanges &+= 1
    }

    /// Reads with `read` and applies each answer with `apply`. A failed read ends the run with
    /// `failed`; a cancelled one ends it silently.
    func refresh(
        read: @escaping @MainActor () async throws -> Value,
        apply: @escaping @MainActor (Value) -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) async {
        if let running {
            readAgain = true
            await running.value
            return
        }
        runs &+= 1
        let run = runs
        let task = Task { @MainActor [weak self] in
            defer { if let self, self.runs == run { self.running = nil } }
            do {
                var again = true
                while again, !Task.isCancelled {
                    guard let self else { return }
                    self.readAgain = false
                    let changes = self.localChanges
                    let value = try await read()
                    guard !Task.isCancelled else { return }
                    let overtaken = self.localChanges != changes
                    if !overtaken { apply(value) }
                    again = overtaken || self.readAgain
                }
            } catch {
                if !Task.isCancelled { failed(error) }
            }
        }
        running = task
        await task.value
    }

    func cancel() {
        running?.cancel()
        running = nil
        runs &+= 1
        readAgain = false
    }
}
