#if DEBUG
import Foundation

/// Fixtures for `SCREENSHOT_SCREEN=server-metrics` (and `server-metrics-off`):
/// the Server Metrics page over a fixture snapshot, no server load. The host
/// switcher lists Server Metrics because the fixture connection reports
/// sampling on. `ScreenshotPreviewView` mounts the page.
enum ServerMetricsScreenshotFixture {
    /// The app services over one paired fixture server.
    @MainActor
    static func makeRoot() -> AppRootEnvironment {
        // Pin the theme before `ThemeStore()` reads it, as the settings previews do.
        switch ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] {
        case "dark": ScreenshotVolatileDefaults.applyTheme(.dark)
        case "light": ScreenshotVolatileDefaults.applyTheme(.light)
        default: break
        }
        return .preview(coordinator: makeCoordinator())
    }

    @MainActor
    private static func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        guard let server = PairedServer(from: ServerCredentials(
            host: "mac-studio.local",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            scheme: .https,
            serverFingerprint: "sha256:server-metrics-preview",
            tlsCertFingerprint: "sha256:server-metrics-preview-leaf"
        )) else { return coordinator }
        coordinator.serverStore.replaceServersForPreview([server])
        if coordinator.switchToServer(server) {
            coordinator.connection(for: server.id)?.serverMetricsEnabled = true
        }
        return coordinator
    }

    /// 24 hours of 5-minute buckets, with a gap before the host sampler started.
    static func snapshot(samplingOn: Bool) -> ServerMetricsSnapshot {
        let now = Date().timeIntervalSince1970 * 1000
        let bucket = 300_000.0
        let count = 288
        let ts = (0..<count).map { now - Double(count - 1 - $0) * bucket }
        func series(_ base: Double, _ swing: Double, gap: Int = 0) -> [String: Any] {
            var avg: [Any] = []
            var max: [Any] = []
            for index in 0..<count {
                if index < gap {
                    avg.append(NSNull())
                    max.append(NSNull())
                    continue
                }
                let position = Double(index)
                let slow: Double = swing * sin(position / 9)
                let fast: Double = swing / 3 * sin(position / 2.3)
                let value: Double = base + slow + fast
                avg.append(value)
                max.append(value * 1.4)
            }
            return ["avg": avg, "max": max]
        }
        let latestHost: [String: Any] = [
            "scope": "host", "cpu": 18.4, "cpuCores": 32, "load1": 4.43,
            "memUsed": 283_000, "memTotal": 524_288, "diskUsed": 1_500_000, "diskTotal": 3_800_000,
        ]
        let latest: [String: Any] = [
            "ts": now,
            "cpu": ["user": 8.73, "system": 0.85, "total": 9.58],
            "memory": ["heapUsed": 217.25, "heapTotal": 272.91, "rss": 845.41, "external": 23.67],
            "sessions": ["busy": 2, "ready": 4, "starting": 0, "total": 6, "peak": 7],
            "wsConnections": 3,
            "eventLoop": ["p50": 21.79, "p95": 22.43, "p99": 23.95, "max": 141.82],
            "host": latestHost,
        ]
        let history: [String: Any] = [
            "range": "24h",
            "bucketMs": bucket,
            "ts": ts,
            "series": [
                "cpu": series(9, 4),
                "rss": series(820, 40),
                "heapUsed": series(210, 25),
                "sessions": series(4, 2),
                "hostCpu": series(18, 8, gap: 40),
                "memUsed": series(283_000, 6000, gap: 40),
                "diskUsed": series(1_500_000, 20_000, gap: 40),
            ],
        ]
        var body: [String: Any] = [
            "enabled": samplingOn,
            "intervalMs": 30_000,
            "serverStartedAt": now - 3 * 86_400_000 - 5 * 3_600_000,
            "platform": "darwin",
            "arch": "arm64",
        ]
        body["latest"] = samplingOn ? latest : NSNull()
        body["history"] = samplingOn ? history : NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let snapshot = try? JSONDecoder().decode(ServerMetricsSnapshot.self, from: data) else {
            preconditionFailure("server metrics preview fixture")
        }
        return snapshot
    }
}
#endif
