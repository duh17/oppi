import Foundation
import SwiftUI

/// Where a user or system action set `showQuickSession`.
enum QuickSessionPresentationSource: String, Sendable {
    case sessionListBar = "session_list_bar"
    case workspaceBar = "workspace_bar"
    case threadBar = "thread_bar"
    case agents = "agents"
    /// App Intent / control widget, presented by ContentView.
    case intent = "intent"
}

/// Size-class and window measurement that chose stack vs split.
struct WorkspaceNavigationMeasurement: Equatable, Sendable {
    var horizontalSizeClass: String
    var verticalSizeClass: String
    var windowWidth: Int
    var windowHeight: Int

    init(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        windowSize: CGSize
    ) {
        self.horizontalSizeClass = Self.label(horizontalSizeClass)
        self.verticalSizeClass = Self.label(verticalSizeClass)
        self.windowWidth = max(0, Int(windowSize.width.rounded()))
        self.windowHeight = max(0, Int(windowSize.height.rounded()))
    }

    init(horizontalSizeClass: String, verticalSizeClass: String, windowWidth: Int, windowHeight: Int) {
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }

    private static func label(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        case nil: "unspecified"
        @unknown default: "unknown"
        }
    }
}

enum NavigationPresentationTelemetry {
    static func sessionRoutePreserved(fromSessionId: String?, toSessionId: String?) -> Bool {
        guard let fromSessionId, !fromSessionId.isEmpty else { return false }
        return fromSessionId == toSessionId
    }

    static func metadata(
        from: String,
        to: String,
        measurement: WorkspaceNavigationMeasurement?,
        fromSessionId: String?,
        toSessionId: String?
    ) -> [String: String] {
        var metadata: [String: String] = [
            "from": from,
            "to": to,
            "horizontalSizeClass": measurement?.horizontalSizeClass ?? "unspecified",
            "verticalSizeClass": measurement?.verticalSizeClass ?? "unspecified",
            "windowWidth": measurement.map { String($0.windowWidth) } ?? "unmeasured",
            "windowHeight": measurement.map { String($0.windowHeight) } ?? "unmeasured",
            "sessionRoutePreserved": sessionRoutePreserved(
                fromSessionId: fromSessionId,
                toSessionId: toSessionId
            ) ? "true" : "false",
        ]
        if let fromSessionId, !fromSessionId.isEmpty {
            metadata["sessionId"] = fromSessionId
        }
        return metadata
    }
}

struct NavigationRouteSnapshot: Equatable, Sendable {
    var screen: String
    var stackDepth: Int
    var presentation: String
    var sessionId: String?
    var workspaceId: String?
}

struct NavigationRouteLog: Equatable, Sendable {
    var message: String
    var metadata: [String: String]
}

enum NavigationRouteTelemetry {
    /// One log per visible-route change. Identical snapshots are not events.
    static func log(previous: NavigationRouteSnapshot?, current: NavigationRouteSnapshot) -> NavigationRouteLog? {
        guard previous != current else { return nil }
        var metadata: [String: String] = [
            "screen": current.screen,
            "previousScreen": previous?.screen ?? "none",
            "stackDepth": String(current.stackDepth),
            "presentation": current.presentation,
        ]
        if let sessionId = current.sessionId, !sessionId.isEmpty {
            metadata["sessionId"] = sessionId
        }
        if let workspaceId = current.workspaceId, !workspaceId.isEmpty {
            metadata["workspaceId"] = workspaceId
        }
        return NavigationRouteLog(message: "Route changed", metadata: metadata)
    }
}

/// Collapses the diagnostic-context hooks that fire together in one turn
/// into the final route. An unchanged final snapshot does not log.
@MainActor
final class NavigationRouteTelemetryCoalescer {
    private var lastEmitted: NavigationRouteSnapshot?
    private var pending: NavigationRouteSnapshot?
    private var scheduled = false
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private let emit: (NavigationRouteLog) -> Void

    init(
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
            Task { @MainActor in work() }
        },
        emit: @escaping (NavigationRouteLog) -> Void = { log in
            ClientLog.info("Navigation", log.message, metadata: log.metadata, flush: true)
        }
    ) {
        self.schedule = schedule
        self.emit = emit
    }

    func note(_ snapshot: NavigationRouteSnapshot) {
        pending = snapshot
        guard !scheduled else { return }
        scheduled = true
        schedule { [weak self] in
            self?.flush()
        }
    }

    func flush() {
        scheduled = false
        guard let pending else { return }
        self.pending = nil
        guard let log = NavigationRouteTelemetry.log(previous: lastEmitted, current: pending) else { return }
        lastEmitted = pending
        emit(log)
    }
}

@MainActor
enum ChatMountTelemetry {
    private static var lastMountUptime: [String: TimeInterval] = [:]

    static func appearMetadata(
        sessionId: String,
        shellSwapRemount: Bool,
        presentation: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [String: String] {
        appearMetadata(
            sessionId: sessionId,
            shellSwapRemount: shellSwapRemount,
            presentation: presentation,
            now: now,
            lastMountUptime: &lastMountUptime
        )
    }

    static func appearMetadata(
        sessionId: String,
        shellSwapRemount: Bool,
        presentation: String,
        now: TimeInterval,
        lastMountUptime: inout [String: TimeInterval]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "sessionId": sessionId,
            "shellSwapRemount": shellSwapRemount ? "true" : "false",
            "presentation": presentation,
        ]
        if let previous = lastMountUptime[sessionId] {
            let deltaMs = max(0, Int(((now - previous) * 1_000).rounded()))
            metadata["sincePreviousMountMs"] = String(deltaMs)
        }
        lastMountUptime[sessionId] = now
        return metadata
    }

    /// `shellSwapRemount` on disappear means this unmount is the outgoing side
    /// of a shell swap: the chat left under a different presentation than it
    /// mounted with. The incoming appear records whether that swap was adopted.
    static func disappearMetadata(
        sessionId: String,
        shellSwapRemount: Bool,
        presentation: String
    ) -> [String: String] {
        [
            "sessionId": sessionId,
            "shellSwapRemount": shellSwapRemount ? "true" : "false",
            "presentation": presentation,
        ]
    }
}

