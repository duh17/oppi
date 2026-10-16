import Foundation

/// `GET /server/metrics?range=`: the resource sampler's latest sample and
/// bucketed history (up to 30 days) for the Server Metrics page. Memory and
/// disk are MB, CPU is percent: process CPU of one core, host CPU of the cores
/// the host or container may use.
struct ServerMetricsSnapshot: Decodable, Sendable, Equatable {
    /// `serverMetrics.enabled`. Off: no `latest` and no `history`.
    let enabled: Bool
    let intervalMs: Double
    let serverStartedAt: Double
    let platform: String
    let arch: String
    let latest: ServerResourceSample?
    let history: ServerMetricsHistory?
}

/// One line of the server's `server-metrics-*.jsonl`.
struct ServerResourceSample: Decodable, Sendable, Equatable {
    struct CPU: Decodable, Sendable, Equatable {
        let total: Double
    }

    struct Memory: Decodable, Sendable, Equatable {
        let heapUsed: Double
        let heapTotal: Double
        let rss: Double
    }

    struct Sessions: Decodable, Sendable, Equatable {
        let busy: Int
        let total: Int
    }

    struct EventLoop: Decodable, Sendable, Equatable {
        let p99: Double
        let max: Double
    }

    /// Absent on samples written before host sampling.
    struct Host: Decodable, Sendable, Equatable {
        enum Scope: String, Decodable, Sendable {
            /// The machine: macOS, Linux, or Windows.
            case host
            /// A Linux container: cgroup usage against the container's CPU and memory limits.
            case container
        }

        let scope: Scope
        let cpu: Double?
        /// The machine's CPUs, a container's CPU quota (can be fractional), or
        /// every CPU an unlimited container may run on.
        let cpuCores: Double?
        /// `cpuCores` is a container's CPU quota.
        let cpuLimited: Bool?
        /// Machine load average; absent in a container.
        let load1: Double?
        let memUsed: Double?
        let memTotal: Double?
        /// `memTotal` is a container's memory limit, not the machine's memory.
        let memLimited: Bool?
        let diskUsed: Double?
        let diskTotal: Double?
    }

    let ts: Double
    let cpu: CPU
    let memory: Memory
    let sessions: Sessions
    let wsConnections: Int
    let eventLoop: EventLoop
    let host: Host?
}

/// Columnar history: `series[key].avg[i]` belongs to `ts[i]`; nil is a gap.
struct ServerMetricsHistory: Decodable, Sendable, Equatable {
    struct Series: Decodable, Sendable, Equatable {
        let avg: [Double?]
        let max: [Double?]
    }

    let range: String
    let bucketMs: Double
    let ts: [Double]
    let series: [String: Series]

    func series(_ key: ServerMetricSeries) -> Series? {
        series[key.rawValue]
    }
}

enum ServerMetricSeries: String, Sendable {
    case cpu
    case rss
    case heapUsed
    case eventLoopP99
    case sessions
    case wsConnections
    case hostCpu
    case memUsed
    case diskUsed
}

enum ServerMetricsRange: String, CaseIterable, Sendable {
    case hour = "1h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var label: String { rawValue }

    /// The short ranges move every sample; longer ones refresh when pulled.
    var refreshesLive: Bool { self == .hour || self == .day }

    /// Left edge of the chart's time axis.
    var startLabel: String {
        switch self {
        case .hour: "1 hour ago"
        case .day: "24 hours ago"
        case .week: "7 days ago"
        case .month: "30 days ago"
        }
    }
}
