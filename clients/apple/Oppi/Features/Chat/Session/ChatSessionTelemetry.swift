import CoreFoundation
import Foundation

/// Chat runtime telemetry for the iOS client: process-start timing and the
/// mapping from the shared runtime's telemetry events to catalog events.
/// OppiCore (which the Mac target also compiles) stays free of generated
/// catalog types; this is the one place its vocabulary becomes catalog values.
enum ChatSessionTelemetry {

    /// Process start timestamp for app launch metric.
    /// Static let is lazy (dispatch_once) — call `warmProcessStartTime()` from
    /// AppDelegate.didFinishLaunchingWithOptions to force capture before any views load.
    static let processStartTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    /// Force-evaluate `processStartTime`. Call once from AppDelegate.
    static func warmProcessStartTime() {
        _ = processStartTime
    }

    static func nowMs() -> Int64 { Date.nowMs() }

    /// The catalog event for a shared-runtime event, with its workspace when it
    /// has one. Nil when the runtime emitted a value the catalog does not
    /// declare; the runtime's vocabulary is the catalog's snake_case values, so
    /// that is a bug the mapping test catches.
    static func event(
        for runtimeEvent: ChatSessionRuntimeTelemetry
    ) -> (event: any TelemetryEvent, workspaceId: String?)? {
        switch runtimeEvent {
        case .cacheLoad(let durationMs, let hit, let eventCount):
            return (AppCacheLoad(durationMs: Double(durationMs), hit: hit, events: eventCount), nil)

        case .reducerLoad(let durationMs, let source, let eventCount, let itemCount):
            guard let loadSource = TelemetryTag.LoadSource(rawValue: source) else { return nil }
            return (
                AppReducerLoad(
                    durationMs: Double(durationMs),
                    events: eventCount,
                    items: itemCount,
                    loadSource: loadSource
                ),
                nil
            )

        case .catchUp(let durationMs, let result):
            guard let result = AppCatchup.Result(rawValue: result) else { return nil }
            return (AppCatchup(durationMs: Double(durationMs), result: result), nil)

        case .sessionLoad(let durationMs, let workspaceId, let path, let itemCount):
            guard let loadPath = AppSessionLoad.LoadPath(rawValue: path) else { return nil }
            return (
                AppSessionLoad(durationMs: Double(durationMs), items: itemCount, loadPath: loadPath),
                workspaceId
            )

        case .freshContentLag(let durationMs, let workspaceId, let reason, let cached, let transport):
            guard let reason = AppFreshContentLag.Reason(rawValue: reason) else { return nil }
            return (
                AppFreshContentLag(
                    durationMs: Double(durationMs),
                    cached: cached,
                    reason: reason,
                    transport: AppFreshContentLag.Transport(rawValue: transport)
                ),
                workspaceId
            )

        case .sessionSwitch(let durationMs, let cached):
            return (AppSessionSwitch(durationMs: Double(durationMs), cached: cached), nil)

        case .timeToFirstToken(let durationMs, let provider, let model):
            return (AppTtft(durationMs: Double(durationMs), provider: provider, model: model), nil)

        case .traceFetch(let durationMs, let workspaceId, let status, let eventCount, let errorKind):
            return (
                AppTraceFetch(
                    durationMs: Double(durationMs),
                    traceEvents: eventCount,
                    status: status == "ok" ? .ok : .error,
                    errorKind: errorKind.flatMap(TelemetryTag.ErrorKind.init(rawValue:))
                ),
                workspaceId
            )
        }
    }
}
