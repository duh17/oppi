import Foundation
import Observation

/// What a program last said with OSC 9;4 (ConEmu / Windows Terminal progress).
///
/// The states and the percentage follow libghostty's parser, which follows
/// Ghostty's own handling: a determinate report carries 0...100, a pause with
/// no number stands for "stopped at the end" (full), and an error with no
/// number or an indeterminate report has no position to show.
struct SSHTerminalProgressReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case set, error, indeterminate, paused
    }

    let state: State
    /// 0...100 as the program sent it. Nil when it sent none, and always nil
    /// for an indeterminate report, which has no position by definition.
    let percent: Int?

    init(state: State, percent: Int?) {
        self.state = state
        self.percent = state == .indeterminate ? nil : percent.map { min(100, max(0, $0)) }
    }

    /// How much of the ring is filled. Nil means the ring spins: the program
    /// gave no position.
    var fraction: Double? {
        if let percent { return Double(percent) / 100 }
        return state == .paused ? 1 : nil
    }

    /// The VoiceOver value. A plain determinate report reads "Progress 40%".
    var spokenValue: String {
        switch (state, percent) {
        case (.set, let percent?): "Progress \(percent)%"
        case (.set, nil): "Progress"
        case (.indeterminate, _): "Progress, in progress"
        case (.paused, let percent?): "Progress paused at \(percent)%"
        case (.paused, nil): "Progress paused"
        case (.error, let percent?): "Progress failed at \(percent)%"
        case (.error, nil): "Progress failed"
        }
    }
}

/// The program's current OSC 9;4 progress for one terminal.
///
/// libghostty only forwards the report, so the lifetime rules live here, as
/// they do for OSC 7501: each report replaces the one before it, `remove`
/// clears it, RIS and the end of the connection clear it, and a report that
/// is not renewed goes away on its own after `timeout`. Ghostty does the same
/// (15 seconds, restarted by every report) because a program that crashed or
/// was killed never sends the remove, and its bar would otherwise stay.
@MainActor @Observable
final class SSHTerminalProgressStore {
    /// Ghostty removes a progress report it has not heard again from after this long.
    static let staleTimeout: Duration = .seconds(15)

    private(set) var report: SSHTerminalProgressReport?

    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(timeout: Duration = SSHTerminalProgressStore.staleTimeout) {
        self.timeout = timeout
    }

    isolated deinit { timer?.cancel() }

    /// A report from the program. The stale clock restarts even when the
    /// report is the same as the last, since a repeat is still proof of life.
    func apply(_ next: SSHTerminalProgressReport, at now: ContinuousClock.Instant = .now) {
        if report != next { report = next }
        deadline = now.advanced(by: timeout)
        startTimerIfNeeded()
    }

    /// OSC 9;4;0, RIS, or the end of the connection.
    func reset() {
        report = nil
        deadline = nil
        timer?.cancel()
        timer = nil
    }

    /// Drops the report when `timeout` has passed since the last one.
    /// Returns whether it did.
    @discardableResult
    func expireIfStale(at now: ContinuousClock.Instant = .now) -> Bool {
        guard report != nil, let deadline, now >= deadline else { return false }
        reset()
        return true
    }

    /// One sleeping task per report burst: it wakes at the deadline, and if a
    /// later report pushed the deadline out, it sleeps again instead of every
    /// report starting a task of its own.
    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                // Not held across the sleep, so a dropped terminal frees its store.
                guard let deadline = self?.deadline else { return }
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                if self.expireIfStale() { return }
            }
        }
    }
}
