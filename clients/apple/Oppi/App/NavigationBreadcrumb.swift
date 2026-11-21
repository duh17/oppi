import Foundation
import UIKit

/// Where a user or system action set `showQuickSession`.
enum QuickSessionPresentationSource: String, Sendable {
    case sessionListBar = "session_list_bar"
    case workspaceBar = "workspace_bar"
    case agents = "agents"
    /// App Intent / control widget, presented by the app root.
    case intent = "intent"
    /// The New Session keyboard command (`KeyboardCommand.newSession`).
    case keyboard = "keyboard"
}

/// The screens in front in a window, read from UIKit. The route state behind
/// `diagnosticScreenLabel` can lag a push, so a Quick Session request logs
/// this too: whether a chat was on top when a control opened it.
@MainActor
struct FrontScreens {
    let chatOnTop: Bool
    /// Class names of the front screens, comma separated.
    let names: String

    static func current(in window: UIWindow?) -> Self {
        let fronts = window.map(screens(in:)) ?? []
        return Self(
            chatOnTop: fronts.contains { $0 is ChatRouteViewController },
            names: fronts.map { String(describing: type(of: $0)) }.joined(separator: ",")
        )
    }

    /// The screens in front in `window`, the topmost presented screen's
    /// first.
    static func screens(in window: UIWindow) -> [UIViewController] {
        var fronts: [UIViewController] = []
        if let root = window.rootViewController { collect(root, into: &fronts) }
        return fronts
    }

    /// What shows: a presented screen over its presenter, a stack's top, each
    /// column of a split, and a screen with no shown children of its own. A
    /// hidden child (a parked companion, a screen's attached leaf) does not.
    private static func collect(_ screen: UIViewController, into fronts: inout [UIViewController]) {
        let shown = screen.children.filter { $0.viewIfLoaded?.isHidden != true }
        // An active search is presented by UIKit but is not a screen of its own.
        if let presented = screen.presentedViewController, !(presented is UISearchController) {
            collect(presented, into: &fronts)
        } else if screen is ChatRouteViewController {
            fronts.append(screen)
        } else if let navigation = screen as? UINavigationController {
            if let top = navigation.topViewController { collect(top, into: &fronts) }
        } else if shown.isEmpty {
            fronts.append(screen)
        } else {
            for child in shown {
                collect(child, into: &fronts)
            }
        }
    }
}

/// Size-class and window measurement that chose stack vs split.
struct WorkspaceNavigationMeasurement: Equatable, Sendable {
    var horizontalSizeClass: String
    var verticalSizeClass: String
    var windowWidth: Int
    var windowHeight: Int

    init(
        horizontalSizeClass: UIUserInterfaceSizeClass,
        verticalSizeClass: UIUserInterfaceSizeClass,
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

    private static func label(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        case .unspecified: "unspecified"
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
        presentation: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [String: String] {
        appearMetadata(
            sessionId: sessionId,
            presentation: presentation,
            now: now,
            lastMountUptime: &lastMountUptime
        )
    }

    static func appearMetadata(
        sessionId: String,
        presentation: String,
        now: TimeInterval,
        lastMountUptime: inout [String: TimeInterval]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "sessionId": sessionId,
            "presentation": presentation,
        ]
        if let previous = lastMountUptime[sessionId] {
            let deltaMs = max(0, Int(((now - previous) * 1_000).rounded()))
            metadata["sincePreviousMountMs"] = String(deltaMs)
        }
        lastMountUptime[sessionId] = now
        return metadata
    }

    static func disappearMetadata(
        sessionId: String,
        presentation: String
    ) -> [String: String] {
        [
            "sessionId": sessionId,
            "presentation": presentation,
        ]
    }
}

/// Phase durations of one session or thread link, from the tap to the route.
/// `AppOpener` times each phase it runs before navigating and logs one
/// `Link opened` breadcrumb when the route is set. A phase that did not run
/// is absent; `lockAuthorizeMs` adds every lock check, including the time a
/// person spends on a Face ID prompt.
@MainActor
final class LinkOpenTimer {
    /// How the open reached the route: `blocking` waited on the network for
    /// the session's record and dialogs; `cached` pushed from the loaded record.
    enum Path: String { case blocking, cached }

    static let message = "Link opened"

    private let kind: String
    private let origin: MainPaneOrigin
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var durations: [String: Int] = [:]
    var path: Path = .blocking

    init(kind: String, origin: MainPaneOrigin) {
        self.kind = kind
        self.origin = origin
        start = clock.now
    }

    func time<T>(_ phase: String, _ body: () async -> T) async -> T {
        let phaseStart = clock.now
        let result = await body()
        durations[phase, default: 0] += Self.milliseconds(phaseStart.duration(to: clock.now))
        return result
    }

    func time<T>(_ phase: String, _ body: () -> T) -> T {
        let phaseStart = clock.now
        let result = body()
        durations[phase, default: 0] += Self.milliseconds(phaseStart.duration(to: clock.now))
        return result
    }

    func metadata() -> [String: String] {
        var metadata: [String: String] = [
            "kind": kind,
            "origin": origin == .external ? "external" : "in_app",
            "path": path.rawValue,
            "totalMs": String(Self.milliseconds(start.duration(to: clock.now))),
        ]
        for (phase, ms) in durations { metadata[phase] = String(ms) }
        return metadata
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return max(0, Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000))
    }
}
