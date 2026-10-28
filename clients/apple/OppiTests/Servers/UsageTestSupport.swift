import Foundation
@testable import Oppi

/// A server whose stats, days, and provider status the test scripts, holding answers on request.
final class ScriptedUsageClient: UsageStatsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _statsByRange: [UsageRange: ServerStats] = [:]
    private var _details: [String: DailyDetail] = [:]
    private var _providers: [ProviderAuthProviderStatus] = []
    private var _failStats = false
    private var _failProviders = false
    private var _ranges: [UsageRange] = []
    private var _days: [String] = []
    private var heldStats: [UsageRange: [CheckedContinuation<Void, Never>]] = [:]
    private var holdingStats: Set<UsageRange> = []
    private var heldDetails: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var holdingDetails: Set<String> = []

    var statsByRange: [UsageRange: ServerStats] {
        get { lock.withLock { _statsByRange } }
        set { lock.withLock { _statsByRange = newValue } }
    }
    var details: [String: DailyDetail] {
        get { lock.withLock { _details } }
        set { lock.withLock { _details = newValue } }
    }
    var providers: [ProviderAuthProviderStatus] {
        get { lock.withLock { _providers } }
        set { lock.withLock { _providers = newValue } }
    }
    var failStats: Bool {
        get { lock.withLock { _failStats } }
        set { lock.withLock { _failStats = newValue } }
    }
    var failProviders: Bool {
        get { lock.withLock { _failProviders } }
        set { lock.withLock { _failProviders = newValue } }
    }
    var requestedRanges: [UsageRange] { lock.withLock { _ranges } }
    var requestedDays: [String] { lock.withLock { _days } }

    func holdStats(for range: UsageRange) { lock.withLock { _ = holdingStats.insert(range) } }
    func releaseStats(for range: UsageRange) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holdingStats.remove(range)
            return heldStats.removeValue(forKey: range) ?? []
        }
        waiting.forEach { $0.resume() }
    }
    func holdDetail(for date: String) { lock.withLock { _ = holdingDetails.insert(date) } }
    func releaseDetail(for date: String) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holdingDetails.remove(date)
            return heldDetails.removeValue(forKey: date) ?? []
        }
        waiting.forEach { $0.resume() }
    }

    private struct Failure: LocalizedError { var errorDescription: String? { "The server said no." } }

    func fetchStats(range: UsageRange) async throws -> ServerStats {
        lock.withLock { _ranges.append(range) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hold = lock.withLock { () -> Bool in
                guard holdingStats.contains(range) else { return false }
                heldStats[range, default: []].append(continuation)
                return true
            }
            if !hold { continuation.resume() }
        }
        guard !failStats, let result = statsByRange[range] else { throw Failure() }
        return result
    }

    func fetchDailyDetail(date: String) async throws -> DailyDetail {
        lock.withLock { _days.append(date) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hold = lock.withLock { () -> Bool in
                guard holdingDetails.contains(date) else { return false }
                heldDetails[date, default: []].append(continuation)
                return true
            }
            if !hold { continuation.resume() }
        }
        guard let result = details[date] else { throw Failure() }
        return result
    }

    func listProviderAuthStatus() async throws -> [ProviderAuthProviderStatus] {
        guard !failProviders else { throw Failure() }
        return providers
    }
}
