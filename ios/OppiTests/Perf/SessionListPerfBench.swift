import Testing
import Foundation
@testable import Oppi

// MARK: - Session List Performance Benchmarks

/// Micro-benchmarks for the session list view hot path.
///
/// Measures the computational cost of operations that run during every
/// SwiftUI body evaluation when scrolling the workspace detail (session list) view:
/// - Filtering sessions into active/stopped subsets
/// - Sorting active sessions by attention + turn-ended date
/// - Sorting stopped sessions by lastActivity
/// - Grouping stopped sessions into date buckets (Today, Yesterday, month groups)
/// - Per-row computation (displayTitle, modelShort, contextPercent, inferContextWindow)
/// - Permission lookup per active row
///
/// Output format: `METRIC name=number` for autoresearch consumption.
@Suite("SessionListPerfBench")
@MainActor
struct SessionListPerfBench {

    // MARK: - Configuration

    private static let iterations = 20
    private static let warmupIterations = 3

    // MARK: - Timing

    private static func measureMedianUs(
        setup: () -> Void = {},
        _ block: () -> Void
    ) -> Double {
        var timings: [UInt64] = []
        timings.reserveCapacity(iterations + warmupIterations)

        for i in 0 ..< (warmupIterations + iterations) {
            setup()
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            if i >= warmupIterations {
                timings.append(end &- start)
            }
        }

        timings.sort()
        let median = timings[timings.count / 2]
        return Double(median) / 1000.0
    }

    // MARK: - Test Data Generators

    /// Generate N realistic sessions spread across a workspace.
    /// Mix of statuses: ~10% active (busy/ready/starting), ~90% stopped.
    /// Dates span the last 90 days.
    private static func generateSessions(
        count: Int,
        workspaceId: String = "ws-bench",
        activeRatio: Double = 0.1
    ) -> [Session] {
        let now = Date()
        let models = [
            "anthropic/claude-sonnet-4-0",
            "anthropic/claude-opus-4-6",
            "openai/o3",
            "openai/gpt-4.1",
            "google/gemini-2.5-pro",
            "lmstudio/glm-4.7-flash-mlx",
            "lmstudio/custom-model-128k",
        ]
        let activeStatuses: [SessionStatus] = [.busy, .ready, .starting]
        let activeCount = Int(Double(count) * activeRatio)

        return (0..<count).map { i in
            let isActive = i < activeCount
            let status: SessionStatus = isActive ? activeStatuses[i % activeStatuses.count] : .stopped
            let daysAgo = isActive ? Double.random(in: 0..<1) : Double(i) / Double(count) * 90.0
            let activity = now.addingTimeInterval(-daysAgo * 86400)
            let created = activity.addingTimeInterval(-Double.random(in: 300...7200))
            let model = models[i % models.count]
            let cost = Double.random(in: 0.001...2.5)
            let msgCount = Int.random(in: 1...200)
            let hasChangeStats = Bool.random()

            return Session(
                id: "session-\(i)",
                workspaceId: workspaceId,
                workspaceName: "bench-workspace",
                name: i % 3 == 0 ? "Named Session \(i)" : nil,
                status: status,
                createdAt: created,
                lastActivity: activity,
                model: model,
                messageCount: msgCount,
                tokens: TokenUsage(input: Int.random(in: 1000...50000), output: Int.random(in: 500...20000)),
                cost: cost,
                changeStats: hasChangeStats ? SessionChangeStats(
                    mutatingToolCalls: Int.random(in: 0...100),
                    filesChanged: Int.random(in: 0...30),
                    changedFiles: (0..<min(5, Int.random(in: 0...10))).map { "file\($0).swift" },
                    changedFilesOverflow: nil,
                    addedLines: Int.random(in: 0...500),
                    removedLines: Int.random(in: 0...300)
                ) : nil,
                contextTokens: Int.random(in: 5000...180000),
                contextWindow: Bool.random() ? 200000 : nil,
                firstMessage: i % 3 != 0 ? "Fix the authentication bug in the login flow that causes a crash when the user enters an invalid email address format" : nil,
                lastMessage: "I've updated the file and the tests pass now.",
                thinkingLevel: ["high", "medium", nil][i % 3]
            )
        }
    }

    /// Generate sessions belonging to different workspaces (simulates SessionStore with multiple workspaces).
    private static func generateMixedSessions(totalCount: Int, targetWorkspaceId: String = "ws-bench") -> [Session] {
        let workspaceIds = [targetWorkspaceId, "ws-other-1", "ws-other-2", "ws-other-3"]
        return (0..<totalCount).map { i in
            var session = generateSessions(count: 1, workspaceId: workspaceIds[i % workspaceIds.count])[0]
            session = Session(
                id: "mixed-\(i)",
                workspaceId: session.workspaceId,
                workspaceName: session.workspaceName,
                name: session.name,
                status: session.status,
                createdAt: session.createdAt,
                lastActivity: session.lastActivity,
                model: session.model,
                messageCount: session.messageCount,
                tokens: session.tokens,
                cost: session.cost,
                changeStats: session.changeStats,
                contextTokens: session.contextTokens,
                contextWindow: session.contextWindow,
                firstMessage: session.firstMessage,
                lastMessage: session.lastMessage,
                thinkingLevel: session.thinkingLevel
            )
            return session
        }
    }

    // MARK: - Benchmarks

    // --- 1. Filter workspace sessions from total store (200 total, ~50 for target workspace) ---

    @Test("METRIC filter_workspace_200")
    func filterWorkspace200() {
        let allSessions = Self.generateMixedSessions(totalCount: 200)
        let workspaceId = "ws-bench"

        let us = Self.measureMedianUs {
            let _ = allSessions.filter { $0.workspaceId == workspaceId }
        }
        print("METRIC filter_workspace_200=\(Int(us))")
    }

    // --- 2. Filter active sessions from workspace sessions ---

    @Test("METRIC filter_active_50")
    func filterActive50() {
        let sessions = Self.generateSessions(count: 50)

        let us = Self.measureMedianUs {
            let _ = sessions.filter { $0.status != .stopped }
        }
        print("METRIC filter_active_50=\(Int(us))")
    }

    // --- 3. Filter stopped sessions from workspace sessions ---

    @Test("METRIC filter_stopped_50")
    func filterStopped50() {
        let sessions = Self.generateSessions(count: 50)

        let us = Self.measureMedianUs {
            let _ = sessions.filter { $0.status == .stopped }
        }
        print("METRIC filter_stopped_50=\(Int(us))")
    }

    // --- 4. Sort active sessions (attention + turn-ended fallback) ---

    @Test("METRIC sort_active_10")
    func sortActive10() {
        let sessions = Self.generateSessions(count: 10, activeRatio: 1.0)
        // Simulate permission pending set
        let pendingSessionIds: Set<String> = Set(sessions.prefix(3).map(\.id))
        // Simulate turn-ended dates
        var turnEndedDates: [String: Date] = [:]
        let now = Date()
        for (i, s) in sessions.enumerated() {
            if i % 2 == 0 {
                turnEndedDates[s.id] = now.addingTimeInterval(-Double(i) * 60)
            }
        }

        let us = Self.measureMedianUs {
            var sorted = sessions
            sorted.sort { lhs, rhs in
                let lhsAttn = pendingSessionIds.contains(lhs.id)
                let rhsAttn = pendingSessionIds.contains(rhs.id)
                if lhsAttn != rhsAttn { return lhsAttn }
                let lhsSort = turnEndedDates[lhs.id] ?? lhs.createdAt
                let rhsSort = turnEndedDates[rhs.id] ?? rhs.createdAt
                return lhsSort > rhsSort
            }
        }
        print("METRIC sort_active_10=\(Int(us))")
    }

    // --- 5. Sort stopped sessions by lastActivity ---

    @Test("METRIC sort_stopped_200")
    func sortStopped200() {
        let sessions = Self.generateSessions(count: 200, activeRatio: 0.0)

        let us = Self.measureMedianUs {
            let _ = sessions.sorted { $0.lastActivity > $1.lastActivity }
        }
        print("METRIC sort_stopped_200=\(Int(us))")
    }

    // --- 6. Group stopped sessions into date buckets ---

    @Test("METRIC group_stopped_200")
    func groupStopped200() {
        let sessions = Self.generateSessions(count: 200, activeRatio: 0.0)

        let us = Self.measureMedianUs {
            // Mirrors WorkspaceStoppedSessionsSection.stoppedSessionGroups
            // Pre-sort by lastActivity descending (production code receives pre-sorted data)
            let sorted = sessions.sorted { $0.lastActivity > $1.lastActivity }

            let now = Date()
            let recentCutoffTs = now.timeIntervalSince1970 - 30 * 86400
            let tzOffset = Double(TimeZone.current.secondsFromGMT(for: now))

            // Single-pass: group into Int-keyed buckets, track max date per bucket
            var buckets: [Int: [Session]] = [:]
            var bucketMaxDate: [Int: Date] = [:]
            buckets.reserveCapacity(40)
            bucketMaxDate.reserveCapacity(40)

            for session in sorted {
                let ts = session.lastActivity.timeIntervalSince1970
                let key: Int
                if ts >= recentCutoffTs {
                    let localTs = ts + tzOffset
                    key = Int(floor(localTs / 86400))  // day index
                } else {
                    let cal = Calendar.current
                    let comps = cal.dateComponents([.year, .month], from: session.lastActivity)
                    // Negative keys for month buckets to avoid collision with day indices
                    key = -(comps.year! * 100 + comps.month!)
                }
                buckets[key, default: []].append(session)
                if bucketMaxDate[key] == nil {
                    bucketMaxDate[key] = session.lastActivity  // First item is max (pre-sorted)
                }
            }

            // Sort buckets by max date descending
            let sortedBuckets = buckets.sorted { lhs, rhs in
                (bucketMaxDate[lhs.key] ?? .distantPast) > (bucketMaxDate[rhs.key] ?? .distantPast)
            }
            // Items within each bucket are already sorted (from pre-sorted input)
            let _ = sortedBuckets
        }
        print("METRIC group_stopped_200=\(Int(us))")
    }

    // --- 7. Per-row SessionRow computation (50 rows) ---

    @Test("METRIC row_compute_50")
    func rowCompute50() {
        let sessions = Self.generateSessions(count: 50)

        let us = Self.measureMedianUs {
            for session in sessions {
                // displayTitle
                let _ = session.displayTitle

                // modelShort
                let _ = session.model?.split(separator: "/").last.map(String.init)

                // contextPercent
                if let used = session.contextTokens,
                   let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
                   window > 0 {
                    let _ = min(max(Double(used) / Double(window), 0), 1)
                }

                // costString
                let cost = session.cost
                let _ = cost >= 0.01
                    ? String(format: "$%.2f", cost)
                    : String(format: "$%.3f", cost)

                // relativeString
                let _ = session.lastActivity.relativeString()
            }
        }
        print("METRIC row_compute_50=\(Int(us))")
    }

    // --- 8. inferContextWindow with regex fallback (50 calls) ---

    @Test("METRIC infer_context_50")
    func inferContext50() {
        let models = [
            "anthropic/claude-sonnet-4-0",
            "openai/gpt-4.1",
            "lmstudio/custom-model-128k",
            "unknown/mystery-model",
            "lmstudio/qwen3-32b",
        ]

        let us = Self.measureMedianUs {
            for i in 0..<50 {
                let _ = inferContextWindow(from: models[i % models.count])
            }
        }
        print("METRIC infer_context_50=\(Int(us))")
    }

    // --- 9. Full body evaluation simulation (filter + sort + group + row compute) ---

    @Test("METRIC full_body_eval_200")
    func fullBodyEval200() {
        let allSessions = Self.generateMixedSessions(totalCount: 200)
        let workspaceId = "ws-bench"
        let pendingSessionIds: Set<String> = Set(allSessions.prefix(5).map(\.id))
        var turnEndedDates: [String: Date] = [:]
        let now = Date()
        for (i, s) in allSessions.enumerated() where i % 3 == 0 {
            turnEndedDates[s.id] = now.addingTimeInterval(-Double(i) * 30)
        }

        let us = Self.measureMedianUs {
            let workspaceSessions = allSessions.filter { $0.workspaceId == workspaceId }

            let activeSessions = workspaceSessions
                .filter { $0.status != .stopped }
                .sorted { lhs, rhs in
                    let lhsAttn = pendingSessionIds.contains(lhs.id)
                    let rhsAttn = pendingSessionIds.contains(rhs.id)
                    if lhsAttn != rhsAttn { return lhsAttn }
                    let lhsSort = turnEndedDates[lhs.id] ?? lhs.createdAt
                    let rhsSort = turnEndedDates[rhs.id] ?? rhs.createdAt
                    return lhsSort > rhsSort
                }

            let stoppedSessions = workspaceSessions
                .filter { $0.status == .stopped }
                .sorted { $0.lastActivity > $1.lastActivity }

            // Int-keyed grouping with precomputed max dates
            let nowTs = Date()
            let recentCutoffTs = nowTs.timeIntervalSince1970 - 30 * 86400
            let tzOffset = Double(TimeZone.current.secondsFromGMT(for: nowTs))

            var buckets: [Int: [Session]] = [:]
            var bucketMaxDate: [Int: Date] = [:]
            buckets.reserveCapacity(40)
            bucketMaxDate.reserveCapacity(40)

            for session in stoppedSessions {
                let ts = session.lastActivity.timeIntervalSince1970
                let key: Int
                if ts >= recentCutoffTs {
                    let localTs = ts + tzOffset
                    key = Int(floor(localTs / 86400))
                } else {
                    let cal = Calendar.current
                    let comps = cal.dateComponents([.year, .month], from: session.lastActivity)
                    key = -(comps.year! * 100 + comps.month!)
                }
                buckets[key, default: []].append(session)
                if bucketMaxDate[key] == nil {
                    bucketMaxDate[key] = session.lastActivity
                }
            }

            let sortedBuckets = buckets.sorted { lhs, rhs in
                (bucketMaxDate[lhs.key] ?? .distantPast) > (bucketMaxDate[rhs.key] ?? .distantPast)
            }

            for session in activeSessions {
                let _ = session.displayTitle
                let _ = session.model?.split(separator: "/").last.map(String.init)
                if let used = session.contextTokens,
                   let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
                   window > 0 {
                    let _ = min(max(Double(used) / Double(window), 0), 1)
                }
                let _ = session.lastActivity.relativeString()
            }
            for bucket in sortedBuckets {
                for session in bucket.value {
                    let _ = session.displayTitle
                    let _ = session.model?.split(separator: "/").last.map(String.init)
                    let _ = session.lastActivity.relativeString()
                }
            }
        }
        print("METRIC full_body_eval_200=\(Int(us))")
    }

    // --- 10. Full body eval at scale (500 total sessions, ~125 for workspace) ---

    @Test("METRIC full_body_eval_500")
    func fullBodyEval500() {
        let allSessions = Self.generateMixedSessions(totalCount: 500)
        let workspaceId = "ws-bench"
        let pendingSessionIds: Set<String> = Set(allSessions.prefix(5).map(\.id))
        var turnEndedDates: [String: Date] = [:]
        let now = Date()
        for (i, s) in allSessions.enumerated() where i % 3 == 0 {
            turnEndedDates[s.id] = now.addingTimeInterval(-Double(i) * 30)
        }

        let us = Self.measureMedianUs {
            let workspaceSessions = allSessions.filter { $0.workspaceId == workspaceId }

            let activeSessions = workspaceSessions
                .filter { $0.status != .stopped }
                .sorted { lhs, rhs in
                    let lhsAttn = pendingSessionIds.contains(lhs.id)
                    let rhsAttn = pendingSessionIds.contains(rhs.id)
                    if lhsAttn != rhsAttn { return lhsAttn }
                    let lhsSort = turnEndedDates[lhs.id] ?? lhs.createdAt
                    let rhsSort = turnEndedDates[rhs.id] ?? rhs.createdAt
                    return lhsSort > rhsSort
                }

            let stoppedSessions = workspaceSessions
                .filter { $0.status == .stopped }
                .sorted { $0.lastActivity > $1.lastActivity }

            let nowTs = Date()
            let recentCutoffTs = nowTs.timeIntervalSince1970 - 30 * 86400
            let tzOffset = Double(TimeZone.current.secondsFromGMT(for: nowTs))

            var buckets: [Int: [Session]] = [:]
            var bucketMaxDate: [Int: Date] = [:]
            buckets.reserveCapacity(40)
            bucketMaxDate.reserveCapacity(40)

            for session in stoppedSessions {
                let ts = session.lastActivity.timeIntervalSince1970
                let key: Int
                if ts >= recentCutoffTs {
                    let localTs = ts + tzOffset
                    key = Int(floor(localTs / 86400))
                } else {
                    let cal = Calendar.current
                    let comps = cal.dateComponents([.year, .month], from: session.lastActivity)
                    key = -(comps.year! * 100 + comps.month!)
                }
                buckets[key, default: []].append(session)
                if bucketMaxDate[key] == nil {
                    bucketMaxDate[key] = session.lastActivity
                }
            }

            let sortedBuckets = buckets.sorted { lhs, rhs in
                (bucketMaxDate[lhs.key] ?? .distantPast) > (bucketMaxDate[rhs.key] ?? .distantPast)
            }

            for session in activeSessions {
                let _ = session.displayTitle
                let _ = session.model?.split(separator: "/").last.map(String.init)
                if let used = session.contextTokens,
                   let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
                   window > 0 {
                    let _ = min(max(Double(used) / Double(window), 0), 1)
                }
                let _ = session.lastActivity.relativeString()
            }
            for bucket in sortedBuckets {
                for session in bucket.value {
                    let _ = session.displayTitle
                    let _ = session.model?.split(separator: "/").last.map(String.init)
                    let _ = session.lastActivity.relativeString()
                }
            }
        }
        print("METRIC full_body_eval_500=\(Int(us))")
    }
}
