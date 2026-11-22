import Foundation
import Testing
import UIKit
@testable import Oppi

/// An Agent's icon where it is its own: the circle at the top of its page, which
/// opens the icon picker, and its row in the Agents list. Both play an animated
/// image, through the one motion policy `IconChoiceUIView.motionAllowed`; an icon
/// elsewhere (a chat session's avatar, a workspace's row) keeps its first frame
/// unless a row bursts it.
///
/// The fixture answers one URL protocol, so the suite's tests run one at a time.
@MainActor
@Suite("An Agent's icon", .serialized)
struct AgentIconPlaybackTests {
    private static let agentId = "nanny"

    @Test func theAgentsPageShowsItsIconAsAPlayingCircle() async throws {
        let (screen, window) = try await Self.showDetail()
        defer { hideTestWindow(window) }

        let hero = try #require(await Self.waitForHero(in: window))
        #expect(hero.shape == .circle, "the page's icon is a circle")
        #expect(hero.animates, "the page's icon plays")
        #expect(Self.isInsideListCell(hero), "the circle is the page's own row")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            return Self.hero(in: window)?.bounds.width == 96
        }, "the circle is the page's portrait at 96 pt: \(hero.bounds)")
        #expect(screen.title == "Nanny", "the name stays in the navigation title")
        #expect(await Self.waitForAFrameChange(when: { Self.hero(in: window) }),
                "the page's circle plays the Agent's animated icon")
    }

    @Test func tappingTheCircleOpensTheIconPicker() async throws {
        let (screen, window) = try await Self.showDetail()
        defer { hideTestWindow(window) }

        _ = try #require(await Self.waitForHero(in: window))
        let icons = Self.buttons(in: screen.view).filter { $0.accessibilityLabel == "Icon" }
        #expect(icons.count == 1, "the icon is in one place: the circle, not a Definition row")
        let hero = try #require(icons.first)

        hero.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            let presented = screen.presentedViewController ?? screen.navigationController?.presentedViewController
            return (presented as? UINavigationController)?.topViewController is IconPickerViewController
                || presented is IconPickerViewController
        }, "the circle opens the Agent icon picker")
    }

    @Test func theAgentsListPlaysItsIconsWhileASessionAvatarStaysStill() async throws {
        let root = try await Self.appRoot()
        let screen = AgentListViewController(root: root)
        let window = try Self.show(screen)
        defer { hideTestWindow(window) }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.agentRowIcon(in: screen.view) != nil
        })
        #expect(await Self.waitForAFrameChange(when: { Self.agentRowIcon(in: screen.view) }),
                "an Agent's row plays its icon")

        // An icon outside the Agents page draws its first frame unless a row
        // bursts it. The chat title's session avatar is this view at 22 pt with no
        // `animates`; the image is the fixture's own, so nothing loads and nothing
        // redraws.
        let avatar = IconChoiceUIView(frameSize: 22)
        avatar.apply(.importedImage(try AgentIconFixtureURLProtocol.iconData()))
        avatar.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            avatar.topAnchor.constraint(equalTo: window.topAnchor, constant: 4),
        ])
        window.layoutIfNeeded()
        let still = await Self.framesShown(for: .milliseconds(900)) { avatar }
        #expect(still == 1, "a session avatar draws the first frame only: \(still) frames")
    }

    // MARK: - Fixture

    private static func appRoot() async throws -> AppRootEnvironment {
        let client = AgentIconFixtureURLProtocol.makeClient()
        return try await makeTestAppRoot(readyServerId: "agent-icon-tests", apiClient: client)
    }

    private static func showDetail() async throws -> (AgentDetailViewController, UIWindow) {
        let root = try await appRoot()
        let screen = AgentDetailViewController(root: root, agentId: agentId) { _ in }
        return (screen, try show(screen))
    }

    private static func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        return window
    }

    // MARK: - Reading the screen

    private static func hero(in window: UIWindow) -> IconChoiceUIView? {
        views(in: window).first { $0.accessibilityIdentifier == "agents.detail.iconImage" }
    }

    private static func waitForHero(in window: UIWindow) async -> IconChoiceUIView? {
        var found: IconChoiceUIView?
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            found = hero(in: window)
            return found != nil
        }
        return found
    }

    /// The saved Agent's icon in the list: the row's playing tile, not Pi's mark.
    private static func agentRowIcon(in root: UIView) -> IconChoiceUIView? {
        views(in: root).first { view in
            guard view.animates else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                if let cell = current as? SidebarListCell {
                    return cell.element.accessibilityIdentifier == "agents.row.\(agentId)"
                }
                ancestor = current.superview
            }
            return false
        }
    }

    private static func isInsideListCell(_ view: UIView) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current is SidebarListCell { return true }
            ancestor = current.superview
        }
        return false
    }

    private static func views(in root: UIView) -> [IconChoiceUIView] {
        var found = (root as? IconChoiceUIView).map { [$0] } ?? []
        for subview in root.subviews { found += views(in: subview) }
        return found
    }

    private static func buttons(in root: UIView) -> [UIButton] {
        var found = (root as? UIButton).map { [$0] } ?? []
        for subview in root.subviews { found += buttons(in: subview) }
        return found
    }

    /// One rendering of `view`'s pixels, so a changed frame is a changed value.
    private static func snapshot(of view: UIView) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        return image.pngData()
    }

    /// Whether `view` has drawn a second, different image within `timeout`.
    private static func waitForAFrameChange(
        timeout: Duration = .seconds(5),
        when view: () -> UIView?
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        var first: Data?
        while ContinuousClock.now < deadline {
            if let view = view(), let data = snapshot(of: view) {
                if let first, first != data { return true }
                if first == nil { first = data }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// How many different images `view` drew while sampling `duration`.
    private static func framesShown(for duration: Duration, when view: () -> UIView?) async -> Int {
        var seen: Set<Data> = []
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {
            if let view = view(), let data = snapshot(of: view) {
                seen.insert(data)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return seen.count
    }
}

/// Answers the saved Agent, its animated icon asset, and the Agents list; every
/// other request is a 404, so the page's resource catalogs stay empty.
private final class AgentIconFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "agent-icon.test"
    private static let agentId = "nanny"
    /// An id `IconChoice` accepts (`ia_` and 43 URL-safe characters); any other
    /// string decodes as the default icon.
    private static let assetId = "ia_" + String(repeating: "a", count: 43)

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentIconFixtureURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path == "/agents/\(Self.agentId)" {
            respond(with: Self.json(["agent": Self.agent]))
        } else if path == "/agents" {
            respond(with: Self.json(["agents": [Self.summary]]))
        } else if path == "/icon-assets/\(Self.assetId)" {
            respond(with: (try? Self.iconData()) ?? Data())
        } else {
            respond(status: 404, with: Data(#"{"error":"not found"}"#.utf8))
        }
    }

    override func stopLoading() {}

    private func respond(status: Int = 200, with body: Data) {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func json(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static let agent = StoredAgentDefinition(
        id: agentId,
        name: "Nanny",
        icon: .image(assetId: assetId),
        description: "Chores and life admin.",
        status: .active,
        version: 3,
        definition: AgentDefinition(
            name: "Nanny",
            icon: .image(assetId: assetId),
            instructions: AgentInstructions(text: "You are Nanny.")
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        archivedAt: nil
    )

    private static let summary = AgentDefinitionSummary(
        id: agent.id,
        name: agent.name,
        icon: agent.icon,
        description: agent.description,
        status: agent.status,
        version: agent.version,
        createdAt: agent.createdAt,
        updatedAt: agent.updatedAt,
        archivedAt: nil
    )

    /// The three-colour animated WebP every playing icon here draws: each frame is
    /// a different image, so a playing icon and a still one are told apart by what
    /// they show.
    static func iconData() throws -> Data {
        IconWebPFixtures.threeColour
    }
}
