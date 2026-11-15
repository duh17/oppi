import Testing
import UIKit
@testable import Oppi

/// The hand-off from a game to the agent beside it (`GodotChatHandoff`):
/// the draft names the game and carries the error with its file and line,
/// backtrace and the log's other recent errors; the frame goes in as an
/// image; the draft waits in the composer of the chat that opened the game,
/// unsent; and with no chat to take it, nothing is offered or changed.
@MainActor
@Suite("GodotChatHandoff")
struct GodotChatHandoffTests {
    private let scriptError = GodotEngineLog(
        kind: .script, message: "Invalid call. Nonexistent function 'explode'.", file: "core/variant.cpp", line: 3,
        function: "call", scriptFile: "res://probe.gd", scriptLine: 41,
        backtrace: "[0] _runtime_error (res://probe.gd:41)\n[1] run (res://probe.gd:9)\n"
    )

    private func entry(_ kind: GodotEngineLog.Kind, _ message: String, scriptLine: Int = 0) -> GodotEngineLog {
        GodotEngineLog(
            kind: kind, message: message, file: "core/x.cpp", line: 1, function: "f",
            scriptFile: scriptLine > 0 ? "res://main.gd" : "", scriptLine: scriptLine, backtrace: ""
        )
    }

    @Test func anErrorDraftNamesTheGameAndCarriesItsFileLineBacktraceAndRecentErrors() {
        let log = [
            entry(.print, "probe print: hello"),
            entry(.error, "push_error from the game", scriptLine: 12),
            entry(.warning, "probe warning"),
            GodotEngineLog(
                kind: .script, message: "Parse Error: Invalid operands \"String\" and \"int\" for \"+\" operator.",
                file: "res://hud.gd", line: 12, function: "GDScript::reload", scriptFile: "res://main.gd", scriptLine: 32,
                backtrace: "[0] _ready (res://main.gd:32)"
            ),
            entry(.error, "Mouse is not supported by this display server."),
            scriptError,
        ]
        let text = GodotChatHandoff.text(
            .init(game: "Star Courier", release: 3, error: scriptError, log: log), hasFrame: true
        )
        #expect(text.hasPrefix("The Godot game “Star Courier” (release 3) shows this error:"))
        #expect(text.contains("Invalid call. Nonexistent function 'explode'.\nres://probe.gd:41\n[0] _runtime_error (res://probe.gd:41)\n[1] run (res://probe.gd:9)\n```"))
        #expect(text.contains("- push_error from the game (res://main.gd:12)"), "Recent errors keep their file and line")
        #expect(
            text.contains("operator. (res://hud.gd:12, res://main.gd:32)"),
            "A script that failed to parse names its own line, then where it was loaded"
        )
        #expect(text.contains("- Mouse is not supported by this display server."), "The engine's own errors are error-level too")
        #expect(!text.contains("probe print") && !text.contains("probe warning"), "Prints and warnings stay out")
        #expect(text.components(separatedBy: "Nonexistent function").count == 2, "The shown error is not repeated as a recent one")
        #expect(text.hasSuffix("The current frame is attached."))
    }

    @Test func onlyTheLastFewRecentErrorsGo() {
        let log = (1...9).map { entry(.error, "error \($0)", scriptLine: $0) }
        let text = GodotChatHandoff.text(.init(game: "Tide", release: nil, error: scriptError, log: log), hasFrame: false)
        #expect(text.hasPrefix("The Godot game “Tide” shows this error:"))
        #expect(!text.contains("error 4 "), "Older errors are left out")
        #expect((5...9).allSatisfy { text.contains("- error \($0) (res://main.gd:\($0))") })
        #expect(!text.contains("frame"), "No frame, no mention of one")
    }

    @Test func askAgentLeavesTheDraftWithTheFrameInTheChatThatOpenedTheGame() async throws {
        let fixture = try await Fixture.make()
        let pane = UIViewController()
        fixture.navigation.pushViewController(pane, animated: false)
        fixture.navigation.view.layoutIfNeeded()
        #expect(GodotChatHandoff.chat(beside: pane) === fixture.chat)

        fixture.chat.composerDraftController.text = "Look:"
        let handed = GodotChatHandoff.handOff(
            .init(game: "Star Courier", release: 3, error: scriptError, log: [scriptError]), frame: Self.png, from: pane
        )
        #expect(handed)
        let draft = fixture.chat.composerDraftController
        #expect(draft.text.hasPrefix("Look:\n\nThe Godot game “Star Courier” (release 3) shows this error:"), "It follows the draft's own words")
        #expect(draft.text.contains("res://probe.gd:41"))
        let image = try #require(draft.pendingAttachments.first?.imageAttachment, "The frame is attached")
        #expect(draft.pendingAttachments.count == 1 && draft.pendingAttachments.first?.source == .image)
        #expect(image.mimeType == "image/png" && Data(base64Encoded: image.data) == Self.png)
        #expect(!draft.isSubmissionInFlight, "Nothing is sent")
        #expect(fixture.navigation.topViewController === fixture.route, "The chat comes back into view")
        await fixture.tearDown()
    }

    @Test func sendFrameLeavesTheFrameAloneAndNeedsOne() async throws {
        let fixture = try await Fixture.make()
        let pane = UIViewController()
        fixture.navigation.pushViewController(pane, animated: false)
        let subject = GodotChatHandoff.Subject(game: "Tide", release: 1)

        #expect(!GodotChatHandoff.handOff(subject, frame: nil, from: pane), "No frame, nothing to send")
        #expect(fixture.chat.composerDraftController.text.isEmpty)
        #expect(fixture.navigation.topViewController === pane, "The game stays")

        #expect(GodotChatHandoff.handOff(subject, frame: Self.png, from: pane))
        #expect(fixture.chat.composerDraftController.text == "Here is the current frame of the Godot game “Tide” (release 1).")
        #expect(fixture.chat.composerDraftController.pendingAttachments.count == 1)
        await fixture.tearDown()
    }

    @Test func withNoChatNothingIsOfferedOrChanged() throws {
        let pane = UIViewController()
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(pane, animated: false)
        let host = PaneHostController(primary: navigation)
        host.loadViewIfNeeded()
        #expect(GodotChatHandoff.chat(beside: pane) == nil)
        #expect(!GodotChatHandoff.handOff(.init(game: "Tide", release: 1, error: scriptError), frame: Self.png, from: pane))
        #expect(navigation.topViewController === pane)

        let overlay = GodotErrorOverlayView()
        let askAgent = try #require(overlay.firstSubview(identifiedAs: "godot.error.askAgent"))
        overlay.show(scriptError, canAskAgent: false)
        #expect(askAgent.isHidden, "No chat, no Ask Agent")
        overlay.show(scriptError, canAskAgent: true)
        #expect(!askAgent.isHidden)
    }

    private static let png: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
    }()

    /// A chat route with its chat in a navigation stack, in a window.
    @MainActor
    private struct Fixture {
        let window: UIWindow
        let navigation: UINavigationController
        let route: ChatRouteViewController
        let chat: ChatViewController
        let routes: TestURLProtocol.RouteScope

        static func make() async throws -> Self {
            let serverId = "sha256:godot-handoff-\(UUID().uuidString)"
            // The chat's own refreshes answer as an unreachable server does.
            let routes = TestURLProtocol.routeScope(mockPageRoutes { _ in nil })
            let client = makeTestURLProtocolClient(host: "ready-server.test")
            let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: client)
            let connection = try #require(root.coordinator.connection(for: serverId))
            connection.sessionStore.upsert(makeTestSession(id: "game-chat", workspaceId: "w1", status: .ready))
            let window = makeSceneWindow()
            let route = ChatRouteViewController(
                target: WorkspaceSessionNavTarget(serverId: serverId, sessionId: "game-chat", workspaceId: "w1", routeScope: nil),
                placement: .compactRoot,
                root: root
            )
            let navigation = UINavigationController(rootViewController: route)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            navigation.view.layoutIfNeeded()
            route.updatePropertiesIfNeeded()
            let chat = try #require(route.chat, "The session's chat is up")
            return Self(window: window, navigation: navigation, route: route, chat: chat, routes: routes)
        }

        /// Releases the chat first, so the loads it still had running end
        /// with this test, not after the handler that answers them.
        func tearDown() async {
            hideTestWindow(window)
            navigation.setViewControllers([], animated: false)
            window.rootViewController = UIViewController()
            #expect(await routes.settle(), "a request outlived the test that answered it")
            routes.end()
        }
    }
}

private extension UIView {
    func firstSubview(identifiedAs identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        return subviews.lazy.compactMap { $0.firstSubview(identifiedAs: identifier) }.first
    }
}
